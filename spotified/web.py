"""Authenticated Spotified server and serial job runner."""
import argparse
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import queue
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.cookies import SimpleCookie
from urllib.parse import parse_qs, quote, urlsplit
from uuid import uuid4

from spotified.web_worker import EVENT_PREFIX, normalize_names
from spotified.web_library import Library
from spotified.web_settings import Settings, validate_audio_options
from spotified.web_auth import verify, set_credentials
from spotified.spotify_auth import callback_values
from spotified.web_streaming import StreamCache
from spotified.spotify_catalog import SpotifyCatalog, CatalogError, URI as CATALOG_URI

FORMATS = {'copy', 'mp3', 'aac', 'opus'}
MEDIA_EXTENSIONS = {'.ogg', '.mp3', '.m4a', '.opus', '.flac', '.wav'}
TYPES = 'track|album|playlist|artist|episode|show|audiobook|chapter'
TERMINAL = {'completed', 'previewed', 'partial', 'failed', 'cancelled', 'interrupted'}
RESTARTABLE = {'partial', 'failed', 'cancelled', 'interrupted'}
STATIC = Path(__file__).with_name('web_static')


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def spotify_urls(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 12000:
        raise ValueError('Paste a Spotify track, album, or playlist link.')
    result = []
    for item in value.split():
        uri = re.fullmatch(rf'spotify:({TYPES}):([A-Za-z0-9]{{22}})', item)
        if uri:
            kind, identifier = uri.groups()
        else:
            parsed = urlsplit(item)
            if parsed.scheme != 'https' or parsed.netloc != 'open.spotify.com':
                raise ValueError('Use a full https://open.spotify.com link or spotify: URI.')
            match = re.fullmatch(rf'/(?:intl-[A-Za-z-]+/)?({TYPES})/([A-Za-z0-9]{{22}})/?', parsed.path)
            if not match:
                raise ValueError('This Spotify link is not a supported track, album, playlist, artist, or podcast.')
            kind, identifier = match.groups()
        normalized = f'https://open.spotify.com/{kind}/{identifier}'
        if normalized not in result:
            result.append(normalized)
    if len(result) > 20:
        raise ValueError('Add up to 20 links at a time.')
    return result


def kill_process(process):
    if process and process.poll() is None:
        try:
            if os.name == 'posix':
                os.killpg(process.pid, signal.SIGTERM)
            else:
                process.terminate()
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if os.name == 'posix':
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait(timeout=5)
        except ProcessLookupError:
            pass


class JobManager:
    def __init__(self, config_dir, *, start=True, popen=subprocess.Popen):
        self.config_dir = Path(config_dir).resolve()
        self.config_dir.mkdir(parents=True, exist_ok=True)
        self.history_path = self.config_dir / 'web-jobs.json'
        self.settings = Settings(self.config_dir)
        self.catalog = SpotifyCatalog(self.config_dir)
        self.lock = threading.RLock()
        self.pending = queue.Queue()
        self.stopping = threading.Event()
        self.process = None
        self.active_id = None
        self.popen = popen
        self.account = {'status': 'checking', 'message': 'Checking Spotify login…'}
        self.jobs = []
        if self.history_path.is_file():
            self.jobs = json.loads(self.history_path.read_text(encoding='utf-8'))
            if not isinstance(self.jobs, list):
                raise ValueError('Invalid browser job history')
            for job in self.jobs:
                job['names'] = normalize_names(job.get('names'))
                if job['status'] not in TERMINAL:
                    job.update(status='interrupted', message='Interrupted by a server restart. Choose Restart to try again.')
            self._save()
        config_path = self.config_dir / 'config.json'
        values = json.loads(config_path.read_text(encoding='utf-8')) if config_path.is_file() else {}
        self.roots = {
            'music': Path(values.get('ROOT_PATH') or '~/Music/Spotified Music').expanduser().resolve(),
            'podcasts': Path(values.get('ROOT_PODCAST_PATH') or '~/Music/Spotified Podcasts').expanduser(),
        }
        podcast_setting = values.get('ROOT_PODCAST_PATH', '')
        if podcast_setting.startswith('.'):
            self.roots['podcasts'] = self.roots['music'] / podcast_setting
        self.roots['podcasts'] = self.roots['podcasts'].resolve()
        self.library = Library(self.roots)
        self.streams = StreamCache(self.library)
        if start:
            threading.Thread(target=self._work, daemon=True, name='spotified-queue').start()

    def _save(self):
        temporary = self.history_path.with_suffix('.tmp')
        history = [{k: v for k, v in job.items() if k != 'login_url'} for job in self.jobs]
        temporary.write_text(json.dumps(history, ensure_ascii=False, indent=2), encoding='utf-8')
        temporary.chmod(0o600)
        temporary.replace(self.history_path)

    def state(self):
        with self.lock:
            jobs = [{k: v for k, v in job.items() if k != 'settings'} for job in self.jobs]
            return json.loads(json.dumps({'account': self.account, 'jobs': jobs,
                                          'server': os.environ.get('SPOTIFIED_SERVER_NAME', 'Spotified server'),
                                          'destination': self.settings.public()['music_path']}))

    def add(self, payload, *, login=False, restart_of=None):
        urls = [] if login else spotify_urls(payload.get('urls'))
        preview = payload.get('preview', False)
        if not isinstance(preview, bool):
            raise ValueError('Invalid preview setting.')
        with self.lock:
            if login:
                mode = payload.get('mode', 'browser')
                port = payload.get('callback_port', 4381)
                if mode not in {'browser', 'client', 'check'} or type(port) is not int or not 1024 <= port <= 65535:
                    raise ValueError('Invalid Spotify sign-in mode or callback port.')
                existing = next((j for j in self.jobs if j.get('kind') == 'login' and j['status'] not in TERMINAL), None)
                if existing:
                    if existing.get('login_mode', 'browser') != mode or existing.get('callback_port', 4381) != port:
                        raise ValueError('Cancel the pending Spotify connection before starting another.')
                    return {k: v for k, v in existing.items() if k != 'settings'}
            settings = self.settings.raw()
            codec = payload.get('format', settings.get('DOWNLOAD_FORMAT', 'copy'))
            quality = payload.get('quality', settings.get('DOWNLOAD_QUALITY', 'auto'))
            bitrate = payload.get('bitrate', settings.get('TRANSCODE_BITRATE', 'best'))
            validate_audio_options(codec, quality, bitrate)
            settings.update(DOWNLOAD_FORMAT=codec, DOWNLOAD_QUALITY=quality, TRANSCODE_BITRATE=bitrate)
            if restart_of:
                settings.update(SKIP_EXISTING=True)
            if sum(job['status'] not in TERMINAL for job in self.jobs) >= 30:
                raise ValueError('The queue is full. Wait for a download to finish.')
            job = {'id': uuid4().hex, 'urls': urls, 'format': codec, 'preview': preview,
                   'quality': quality, 'bitrate': bitrate,
                   'kind': 'login' if login else 'download',
                   'status': 'queued', 'created_at': timestamp(), 'logs': [], 'message': 'Waiting in queue',
                   'names': [], 'total': 0, 'completed': 0,
                   'settings': settings}
            if restart_of:
                job.update(restart_of=restart_of, message='Restart queued; already saved tracks will be skipped.')
            if login:
                job.update(login_mode=mode, callback_port=port, message='Waiting to connect to Spotify. Finish or cancel earlier downloads first.')
            self.jobs = [j for j in self.jobs if j['status'] not in TERMINAL] + [j for j in self.jobs if j['status'] in TERMINAL][-99:]
            self.jobs.insert(0, job)
            self._save()
            self.pending.put(job['id'])
            return {k: v for k, v in job.items() if k != 'settings'}

    def import_selection(self, payload):
        uris = payload.get('uris')
        if not isinstance(uris, list) or not 1 <= len(uris) <= 200:
            raise ValueError('Select between 1 and 200 Spotify items.')
        if any(not isinstance(uri, str) or not CATALOG_URI.fullmatch(uri) or uri.split(':')[1] == 'artist' for uri in uris):
            raise ValueError('Select songs, albums, or playlists to save locally.')
        uris = list(dict.fromkeys(uris))
        batches = [uris[index:index + 20] for index in range(0, len(uris), 20)]
        with self.lock:
            if sum(job['status'] not in TERMINAL for job in self.jobs) + len(batches) > 30:
                raise ValueError('There is not enough room in the queue for this selection. Wait for downloads to finish.')
            # Validate every audio option before creating any of the batches.
            options = self.settings.public()
            options.update({key: payload[key] for key in ('format', 'quality', 'bitrate') if key in payload})
            validate_audio_options(options['format'], options['quality'], options['bitrate'])
            return [self.add({key: options[key] for key in ('format', 'quality', 'bitrate')} |
                             {'urls': '\n'.join(batch), 'preview': False}) for batch in batches]

    def spotify_callback(self, identifier, callback_url):
        with self.lock:
            job = next((j for j in self.jobs if j['id'] == identifier), None)
            if job is None:
                raise KeyError(identifier)
            if (job.get('kind') != 'login' or job.get('login_mode') != 'client'
                    or job['status'] != 'running' or not job.get('login_url')
                    or self.active_id != identifier or not self.process or not self.process.stdin):
                raise ValueError('This sign-in is no longer waiting for Spotify. Start sign-in again.')
            values = callback_values(callback_url, job['login_url'])
            try:
                self.process.stdin.write(json.dumps(values) + '\n')
                self.process.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                raise ValueError('Spotify sign-in expired. Start sign-in again.') from exc
            job.pop('login_url', None)
            job['message'] = 'Verifying Spotify sign-in on the server…'

    def restart(self, identifier):
        """Retry source links with saved audio choices and current server settings."""
        with self.lock:
            original = next((j for j in self.jobs if j['id'] == identifier), None)
            if original is None:
                raise KeyError(identifier)
            if original.get('kind') == 'login' or not original.get('urls'):
                raise ValueError('Use Reconnect Spotify in Settings to retry sign-in.')
            if original['status'] not in RESTARTABLE:
                raise ValueError('Only cancelled, interrupted, failed, or partial downloads can restart.')
            # Repeated clicks must not start duplicate downloads.
            active_retry = next((j for j in self.jobs if j.get('restart_of') == identifier
                                 and j['status'] not in TERMINAL), None)
            if active_retry:
                return {k: v for k, v in active_retry.items() if k != 'settings'}
            payload = {'urls': '\n'.join(original['urls']), 'preview': original.get('preview', False)}
            payload.update({k: original[k] for k in ('format', 'quality', 'bitrate') if original.get(k)})
            return self.add(payload, restart_of=identifier)

    def cancel(self, identifier):
        with self.lock:
            job = next((j for j in self.jobs if j['id'] == identifier), None)
            if job is None:
                raise KeyError(identifier)
            if job['status'] in TERMINAL:
                return
            job.update(status='cancelled', message='Cancelled', finished_at=timestamp())
            job.pop('login_url', None)
            process = self.process if self.active_id == identifier else None
            self._save()
        kill_process(process)

    def _command(self):
        return [sys.executable, '-u', '-m', 'spotified.web_worker', '--config-dir', str(self.config_dir)]

    def _check_login(self):
        process = self.popen(self._command() + ['--check-login'], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, start_new_session=True)
        with self.lock:
            self.process = process
        try:
            output, _ = process.communicate(timeout=45)
            connected = False
            error = 'Spotify could not connect. Reconnect from Settings.'
            for line in output.splitlines():
                if line.startswith(EVENT_PREFIX):
                    event = json.loads(line[len(EVENT_PREFIX):])
                    connected |= event.get('kind') == 'account'
                    if event.get('kind') == 'error':
                        error = event.get('message', error)
            with self.lock:
                self.account = {'status': 'connected' if connected and process.returncode == 0 else 'error',
                                'message': 'Spotify connected' if connected and process.returncode == 0 else error}
        except subprocess.TimeoutExpired:
            kill_process(process)
            with self.lock:
                self.account = {'status': 'error', 'message': 'Spotify connection timed out. A queued job will retry.'}
        finally:
            with self.lock:
                self.process = None

    def _work(self):
        try:
            self._check_login()
        except Exception as exc:
            with self.lock:
                self.account = {'status': 'error', 'message': str(exc)}
        while not self.stopping.is_set():
            try:
                identifier = self.pending.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self._run(identifier)
            finally:
                self.pending.task_done()

    def _run(self, identifier):
        process = None
        with self.lock:
            job = next(j for j in self.jobs if j['id'] == identifier)
            if job['status'] == 'cancelled' or self.stopping.is_set():
                return
            job.update(status='running', message='Connecting to Spotify…', started_at=timestamp())
            self.active_id = identifier
            self._save()
        command = self._command() + ['--format', job['format']]
        if job.get('kind') == 'login':
            mode = job.get('login_mode', 'browser')
            command += (['--client-login', str(job['callback_port'])] if mode == 'client'
                        else ['--check-login'] if mode == 'check' else ['--login'])
        if job['preview']:
            command.append('--preview')
        command += job['urls']
        outcome = None
        authenticated = False
        snapshot = self.config_dir / f"job-{identifier}.json"
        try:
            snapshot.write_text(json.dumps(job.get('settings', self.settings.raw())), encoding='utf-8')
            snapshot.chmod(0o600)
            command[command.index('--config-dir'):command.index('--config-dir')] = ['--settings', str(snapshot)]
            process = self.popen(command, stdin=subprocess.PIPE if job.get('login_mode') == 'client' else None,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 errors='replace', bufsize=1, start_new_session=True)
            with self.lock:
                self.process = process
                cancelled = job['status'] == 'cancelled' or self.stopping.is_set()
            if cancelled:
                kill_process(process)
            for raw in process.stdout:
                line = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', raw).strip()
                if not line:
                    continue
                with self.lock:
                    if line.startswith(EVENT_PREFIX):
                        event = json.loads(line[len(EVENT_PREFIX):])
                        kind = event.get('kind')
                        if kind == 'account':
                            authenticated = True
                            self.account = {'status': 'connected', 'message': 'Spotify connected'}
                            job['message'] = 'Fetching metadata…'
                        elif kind == 'metadata':
                            job.update(total=event['total'], names=normalize_names(event.get('names')),
                                       message='Checking your selection…' if job['preview'] else 'Downloading audio…')
                        elif kind == 'login_url' and job['status'] != 'cancelled':
                            job.update(login_url=event['url'], message='Continue to Spotify to finish signing in.')
                        elif kind == 'result':
                            outcome = event
                        elif kind == 'error':
                            job['message'] = event['message']
                            job['logs'].append(event['message'])
                            if job.get('kind') == 'login' or not authenticated:
                                self.account = {'status': 'error', 'message': event['message']}
                    else:
                        # Never persist authorization URLs if an upstream error
                        # accidentally sends an interactive login prompt here.
                        line = re.sub(r'https://accounts\.spotify\.com/\S+', '[Spotify login URL hidden]', line)
                        job['logs'] = list(deque([*job['logs'], line[:2000]], maxlen=200))
            code = process.wait()
            with self.lock:
                if job['status'] != 'cancelled':
                    if outcome and code == 0:
                        job.update(status=outcome['status'], completed=outcome['completed'], total=outcome['total'])
                        job['message'] = (f"Preview ready · {job['total']} tracks found" if job['preview'] else
                                          f"{job['completed']} of {job['total']} tracks saved or already in your library")
                        if job.get('kind') == 'login':
                            job['message'] = 'Spotify connected. Your credentials are saved on this server.'
                    else:
                        job['status'] = 'failed'
                        if not job['message'] or job['message'].endswith('…'):
                            job['message'] = 'Download failed. Open activity details for the reason.'
        except Exception as exc:
            with self.lock:
                if job['status'] != 'cancelled':
                    job.update(status='failed', message=str(exc))
        finally:
            kill_process(process)
            snapshot.unlink(missing_ok=True)
            with self.lock:
                job['finished_at'] = timestamp()
                job.pop('login_url', None)
                self.active_id = None
                self.process = None
                self._save()

    def files(self):
        return self.library.scan()

    def media_path(self, kind, relative):
        if kind not in self.roots:
            raise ValueError('Unknown library')
        path = (self.roots[kind] / relative).resolve()
        if not path.is_relative_to(self.roots[kind]) or path.suffix.lower() not in MEDIA_EXTENSIONS or not path.is_file():
            raise ValueError('File is outside the library or unavailable')
        return path

    def close(self):
        self.stopping.set()
        self.streams.close()
        with self.lock:
            process = self.process
        kill_process(process)


class WebServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, manager, public_origin=None):
        self.manager = manager
        self.csrf_token = secrets.token_urlsafe(32)
        auth_path = manager.config_dir / 'server-auth.json'
        if not auth_path.is_file():
            raise ValueError('Set the server login first: spotified-server --config-dir <folder> --set-password --username corey')
        auth_path.chmod(0o600)
        self.credentials = json.loads(auth_path.read_text())
        self.public_origin = public_origin
        self.sessions = {}
        self.attempts = {}
        self.auth_lock = threading.Lock()
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _trusted_host(self):
        port = self.server.server_port
        allowed = {f'localhost:{port}', f'127.0.0.1:{port}'}
        if self.server.public_origin:
            allowed.add(urlsplit(self.server.public_origin).netloc)
        return self.headers.get('Host') in allowed

    def _authorized(self):
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get('Cookie', ''))
        except Exception:
            return False
        session = cookie.get('spotified_session')
        with self.server.auth_lock:
            return bool(session and self.server.sessions.get(session.value, 0) > time.time())

    def _headers(self, code, content_type, size):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(size))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: https://i.scdn.co https://mosaic.scdn.co; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

    def _json(self, payload, code=200, cookie=None):
        data = json.dumps(payload).encode()
        self._headers(code, 'application/json; charset=utf-8', len(data))
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._trusted_host():
            return self._json({'error': 'This server address is not configured.'}, 403)
        parsed = urlsplit(self.path)
        if parsed.path == '/api/health':
            return self._json({'service': 'spotified', 'status': 'ok'})
        if parsed.path.startswith(('/api/', '/media', '/playlist', '/artwork', '/stream/')) and not self._authorized():
            return self._json({'error': 'Sign in to your Spotified server.'}, 401)
        if parsed.path == '/api/state':
            return self._json(self.server.manager.state() | {'csrf_token': self.server.csrf_token})
        if parsed.path == '/api/files':
            return self._json(self.server.manager.files())
        if parsed.path == '/api/spotify':
            try:
                params = {key: values[-1] for key, values in parse_qs(parsed.query).items()}
                return self._json(self.server.manager.catalog.browse(params))
            except ValueError as exc:
                return self._json({'error': str(exc)}, 400)
            except CatalogError as exc:
                return self._json({'error': str(exc)}, 503)
        if parsed.path == '/api/settings':
            with self.server.manager.lock:
                return self._json(self.server.manager.settings.public())
        if parsed.path.startswith('/stream/') and not parsed.path.endswith('/audio.m4a'):
            try:
                _, _, key, filename = parsed.path.split('/')
                data, content_type = self.server.manager.streams.resource(key, filename)
                self._headers(200, content_type, len(data))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except (ValueError, OSError):
                self._json({'error': 'Stream unavailable. Play the song again.'}, 404)
            return
        if parsed.path in {'/media', '/playlist', '/artwork'} or parsed.path.startswith('/stream/'):
            try:
                params = parse_qs(parsed.query)
                kind, relative = params.get('root', [''])[0], params.get('path', [''])[0]
                if parsed.path == '/artwork':
                    data = self.server.manager.library.artwork(kind, relative)
                    self._headers(200, 'image/jpeg', len(data))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if parsed.path.startswith('/stream/'):
                    _, _, key, filename = parsed.path.split('/')
                    path = self.server.manager.streams.media_path(key, filename)
                else:
                    path = (self.server.manager.library.path(kind, relative, {'.m3u8', '.m3u'})
                            if parsed.path == '/playlist' else self.server.manager.media_path(kind, relative))
                with path.open('rb') as file:
                    size = os.fstat(file.fileno()).st_size
                    start, end, code = 0, size - 1, 200
                    byte_range = self.headers.get('Range')
                    if byte_range:
                        match = re.fullmatch(r'bytes=(\d*)-(\d*)', byte_range)
                        if not match or not any(match.groups()):
                            return self._json({'error': 'Invalid range'}, 416)
                        first, last = match.groups()
                        start = int(first) if first else max(0, size - int(last))
                        end = min(int(last), size - 1) if first and last else size - 1
                        if start > end or start >= size:
                            self._headers(416, 'text/plain', 0)
                            self.send_header('Content-Range', f'bytes */{size}')
                            self.end_headers()
                            return
                        code = 206
                    length = end - start + 1
                    self._headers(code, mimetypes.guess_type(path.name)[0] or 'application/octet-stream', length)
                    self.send_header('Accept-Ranges', 'bytes')
                    if code == 206:
                        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                    if parsed.path == '/playlist' or params.get('download') == ['1']:
                        self.send_header('Content-Disposition', f"attachment; filename*=UTF-8''{quote(path.name, safe='')}")
                    self.end_headers()
                    file.seek(start)
                    while length:
                        chunk = file.read(min(length, 65536))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        length -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except (ValueError, OSError):
                self._json({'error': 'File not found'}, 404)
            return
        path = (STATIC / ('index.html' if parsed.path == '/' else parsed.path.lstrip('/'))).resolve()
        if not path.is_relative_to(STATIC.resolve()) or not path.is_file():
            return self._json({'error': 'Not found'}, 404)
        data = path.read_bytes()
        self._headers(200, mimetypes.guess_type(path.name)[0] or 'application/octet-stream', len(data))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        origin = self.headers.get('Origin')
        if not self._trusted_host() or origin not in {None, f'http://{self.headers.get("Host")}', self.server.public_origin}:
            return self._json({'error': 'Reload this page before trying again.'}, 403)
        if self.path == '/api/session':
            with self.server.auth_lock:
                now = time.time()
                self.server.attempts = {k: v for k, v in self.server.attempts.items() if now - v[0] < 60}
                attempt = self.server.attempts.setdefault(self.client_address[0], [now, 0])
                if attempt[1] >= 10:
                    return self._json({'error': 'Too many attempts. Try again in a minute.'}, 429)
                supplied = self.headers.get('Authorization', '')
                if not verify(self.server.credentials, supplied):
                    attempt[1] += 1
                    return self._json({'error': 'The username or password is incorrect.'}, 401)
                session = secrets.token_urlsafe(32)
                self.server.sessions = {k: v for k, v in self.server.sessions.items() if v > now}
                if len(self.server.sessions) >= 128:
                    self.server.sessions.pop(next(iter(self.server.sessions)))
                self.server.sessions[session] = now + 2592000
            cookie = f'spotified_session={session}; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000'
            if self.server.public_origin and self.headers.get('Host') == urlsplit(self.server.public_origin).netloc and self.server.public_origin.startswith('https:'):
                cookie += '; Secure'
            return self._json({'ok': True}, cookie=cookie)
        if not self._authorized():
            return self._json({'error': 'Sign in to your Spotified server.'}, 401)
        if not secrets.compare_digest(self.headers.get('X-Spotified-Token', ''), self.server.csrf_token):
            return self._json({'error': 'Reload this page before trying again.'}, 403)
        try:
            length = int(self.headers.get('Content-Length', 0))
            if not 0 < length <= 16000 or self.headers.get_content_type() != 'application/json':
                raise ValueError('Expected a small JSON request')
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError('Expected an object')
            if self.path == '/api/jobs':
                return self._json({'job': self.server.manager.add(payload)}, 201)
            if self.path == '/api/spotify/import':
                return self._json({'jobs': self.server.manager.import_selection(payload)}, 201)
            if self.path == '/api/playback':
                kind, relative = payload.get('root'), payload.get('path')
                if not isinstance(kind, str) or not isinstance(relative, str):
                    raise ValueError('Choose a song from your server library.')
                return self._json({'url': self.server.manager.streams.prepare(kind, relative)})
            if self.path == '/api/login':
                return self._json({'job': self.server.manager.add(payload, login=True)}, 201)
            match = re.fullmatch(r'/api/jobs/([a-f0-9]{32})/spotify-callback', self.path)
            if match:
                self.server.manager.spotify_callback(match[1], payload.get('url'))
                return self._json({'ok': True})
            if self.path == '/api/settings':
                with self.server.manager.lock:
                    return self._json(self.server.manager.settings.save(payload))
            match = re.fullmatch(r'/api/jobs/([a-f0-9]{32})/cancel', self.path)
            if match:
                self.server.manager.cancel(match[1])
                return self._json({'ok': True})
            match = re.fullmatch(r'/api/jobs/([a-f0-9]{32})/restart', self.path)
            if match:
                return self._json({'job': self.server.manager.restart(match[1])}, 201)
            return self._json({'error': 'Not found'}, 404)
        except (ValueError, TypeError) as exc:
            return self._json({'error': str(exc)}, 400)
        except KeyError:
            return self._json({'error': 'Job not found'}, 404)


def main():
    parser = argparse.ArgumentParser(description='Run the Spotified application server.')
    parser.add_argument('--host', choices=('127.0.0.1', '0.0.0.0'), default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8088)
    parser.add_argument('--config-dir', type=Path, default=Path.home() / '.config/spotified')
    parser.add_argument('--public-origin', help='HTTPS origin of a configured reverse proxy, e.g. https://music.example.com')
    parser.add_argument('--set-password', action='store_true', help='Set server credentials interactively and exit')
    parser.add_argument('--username', default='corey')
    args = parser.parse_args()
    if args.set_password:
        from getpass import getpass
        password = getpass('Server password: ')
        if password != getpass('Confirm password: '):
            parser.error('Passwords do not match')
        set_credentials(args.config_dir, args.username, password)
        print('Server login saved.')
        return
    manager = JobManager(args.config_dir)
    if args.public_origin:
        origin = urlsplit(args.public_origin)
        if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password or origin.path or origin.query or origin.fragment:
            parser.error('--public-origin must be an HTTPS origin without credentials, path, query, or fragment')
    server = WebServer((args.host, args.port), manager, args.public_origin)
    def shutdown(*_):
        manager.close()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    print(f'Spotified server ready on port {server.server_port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        manager.close()
        server.server_close()


if __name__ == '__main__':
    main()
