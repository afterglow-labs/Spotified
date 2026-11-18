#!/usr/bin/env python3
"""Loopback-only native UI fixture. It never contacts Spotify or writes music."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

settings = dict(layout='albums', playlist_layout='library', format='copy', quality='auto', bitrate='best',
                music_path='/fixture/music', podcast_path='/fixture/podcasts', FETCH_DELAY=2,
                BULK_WAIT_TIME=30, RETRY_DELAY=30, RETRY_ATTEMPTS=3, ESCALATING_DELAY=True,
                ALBUM_ART_TO_FILE=True, EXPORT_M3U8=True, M3U8_REL_PATHS=True,
                LYRICS_TO_METADATA=True, LYRICS_TO_FILE=True, SKIP_EXISTING=True)
jobs, writes = [], []
lock = threading.RLock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, status=200, cookie=False):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if cookie:
            self.send_header('Set-Cookie', 'spotified_session=fixture-cookie; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with lock:
            if self.path == '/api/health':
                self.reply(dict(service='spotified', status='ok'))
            elif self.path == '/api/state':
                self.reply(dict(account=dict(status='connected', message='Fixture Spotify connected'), jobs=jobs,
                                server='Fixture server', destination='/fixture/music', csrf_token='fixture-csrf'))
            elif self.path == '/api/files':
                self.reply(dict(tracks=[], playlists=[], truncated=False))
            elif self.path == '/api/settings':
                self.reply(settings)
            elif self.path == '/test/receipt':
                self.reply(dict(writes=writes, jobs=jobs, settings=settings))
            else:
                self.reply(dict(error='Missing fixture endpoint'), 404)

    def do_POST(self):
        with lock:
            if self.path == '/api/session':
                self.reply(dict(ok=True), cookie=True)
                return
            payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            if self.path == '/test/reset':
                jobs.clear(); writes.clear(); settings['FETCH_DELAY'] = 2
                self.reply(dict(ok=True))
                return
            if self.headers.get('Cookie') != 'spotified_session=fixture-cookie' or self.headers.get('X-Spotified-Token') != 'fixture-csrf':
                self.reply(dict(error='Expected authenticated command'), 403)
                return
            writes.append(dict(path=self.path, body=payload))
            if self.path == '/api/jobs':
                job = dict(id=uuid4().hex, urls=payload['urls'].splitlines(), format=payload['format'],
                           preview=payload['preview'], kind='download', status='queued', names=['Fixture track'],
                           message='Queued on fixture server', logs=['Command received on server'], total=1, completed=0)
                jobs.insert(0, job)
                self.reply(dict(job=job), 201)
            elif self.path == '/api/login':
                check = payload.get('mode') == 'check'
                job = dict(id=uuid4().hex, urls=[], kind='login', login_mode=payload.get('mode'),
                           status='completed' if check else 'queued', logs=[], total=0, completed=0,
                           message='Spotify connection checked on server' if check else 'Waiting for Spotify sign-in on fixture server')
                jobs.insert(0, job)
                self.reply(dict(job=job), 201)
            elif self.path == '/api/settings':
                settings.update(payload); self.reply(settings)
            elif self.path.endswith('/cancel'):
                job = next(j for j in jobs if j['id'] == self.path.split('/')[3])
                job.update(status='cancelled', message='Cancelled on fixture server')
                self.reply(dict(ok=True))
            elif self.path.endswith('/restart'):
                old = next(j for j in jobs if j['id'] == self.path.split('/')[3])
                job = dict(old, id=uuid4().hex, status='queued', restart_of=old['id'], message='Restart queued on server')
                jobs.insert(0, job); self.reply(dict(job=job), 201)
            else:
                self.reply(dict(error='Missing fixture endpoint'), 404)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18769)
    args = parser.parse_args()
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
