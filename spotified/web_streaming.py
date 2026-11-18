"""Temporary, authenticated HLS playback for library formats iOS cannot decode."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time


def disk_size(directory):
    total = 0
    for path in directory.glob('**/*'):
        try:
            if path.is_file(): total += path.stat().st_size
        except FileNotFoundError:
            pass
    return total


class StreamCache:
    def __init__(self, library, *, max_bytes=512 * 1024 * 1024):
        self.library = library
        self.directory = Path(tempfile.mkdtemp(prefix='spotified-streams-'))
        self.max_bytes = max_bytes
        self.entries = {}
        self.lock = threading.RLock()
        self.closed = False

    def _prune(self):
        now = time.monotonic()
        completed = sorted(((key, entry) for key, entry in self.entries.items()
                            if entry['process'].poll() is not None), key=lambda pair: pair[1]['touched'])
        total = disk_size(self.directory)
        for key, entry in completed:
            if now - entry['touched'] < 300:
                continue
            if now - entry['touched'] < 3600 and total < self.max_bytes:
                continue
            size = disk_size(entry['directory'])
            shutil.rmtree(entry['directory'], ignore_errors=True)
            self.entries.pop(key, None)
            total -= size

    def prepare(self, kind, relative):
        source = self.library.path(kind, relative)
        # Serve supported files without changing their encoded audio.
        if source.suffix.lower() in {'.mp3', '.m4a', '.wav'}:
            from urllib.parse import urlencode
            return '/media?' + urlencode({'root': kind, 'path': relative})
        stat = source.stat()
        key = hashlib.sha256(f'{source}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()[:32]
        with self.lock:
            if self.closed:
                raise ValueError('The server is shutting down.')
            self._prune()
            entry = self.entries.get(key)
            if entry and entry['error'] and entry['process'].poll() is not None:
                shutil.rmtree(entry['directory'], ignore_errors=True)
                self.entries.pop(key)
                entry = None
            if entry is None:
                if sum(e['process'].poll() is None for e in self.entries.values()) >= 2:
                    raise ValueError('The server is preparing other songs. Try again shortly.')
                if disk_size(self.directory) >= self.max_bytes:
                    raise ValueError('The temporary playback cache is full. Try again shortly.')
                directory = self.directory / key
                directory.mkdir(mode=0o700, exist_ok=True)
                command = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                           '-i', str(source), '-map', '0:a:0', '-vn']
                lossless = source.suffix.lower() == '.flac'
                command += (['-c:a', 'alac', '-threads', '2', '-movflags', '+faststart', str(directory / 'audio.m4a')]
                            if lossless else ['-c:a', 'aac', '-b:a', '320k',
                           '-threads', '2', '-f', 'hls', '-hls_time', '4', '-hls_list_size', '0',
                           '-hls_playlist_type', 'event', '-hls_flags', 'temp_file',
                           '-hls_segment_filename', str(directory / 'seg%05d.ts'), str(directory / 'index.m3u8')])
                try:
                    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except OSError as exc:
                    shutil.rmtree(directory, ignore_errors=True)
                    raise ValueError('The server could not start FFmpeg for playback.') from exc
                entry = {'directory': directory, 'process': process, 'touched': time.monotonic(), 'error': None, 'lossless': lossless}
                self.entries[key] = entry
                threading.Thread(target=self._watch, args=(entry,), daemon=True).start()
            entry['touched'] = time.monotonic()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            playlist = entry['directory'] / 'index.m3u8'
            if entry['error']:
                raise ValueError(entry['error'])
            if entry['lossless'] and entry['process'].poll() == 0 and (entry['directory'] / 'audio.m4a').is_file():
                return f'/stream/{key}/audio.m4a'
            if playlist.is_file() and '#EXTINF:' in playlist.read_text():
                return f'/stream/{key}/index.m3u8'
            if entry['process'].poll() is not None:
                raise ValueError('This file could not be prepared for playback.')
            time.sleep(0.05)
        raise ValueError('This song is taking longer to prepare. Try Play again shortly.')

    def _watch(self, entry):
        process = entry['process']
        deadline = time.monotonic() + 180
        while process.poll() is None:
            size = disk_size(entry['directory'])
            if size > self.max_bytes // 2 or disk_size(self.directory) > self.max_bytes or time.monotonic() > deadline:
                entry['error'] = 'This file exceeds the temporary playback limit.'
                process.terminate()
                break
            time.sleep(0.2)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
        if process.returncode != 0 and not entry['error']:
            entry['error'] = 'This file could not be prepared for playback.'

    def media_path(self, key, filename):
        if not re.fullmatch(r'[a-f0-9]{32}', key) or not re.fullmatch(r'index\.m3u8|seg\d{5}\.ts|audio\.m4a', filename):
            raise ValueError('Stream not found')
        with self.lock:
            entry = self.entries.get(key)
            if entry is None or entry['error']:
                raise ValueError('Stream expired. Play the song again.')
            entry['touched'] = time.monotonic()
            path = entry['directory'] / filename
            if not path.is_file():
                raise ValueError('Stream not found')
            return path

    def resource(self, key, filename):
        with self.lock:
            path = self.media_path(key, filename)
            return path.read_bytes(), 'application/vnd.apple.mpegurl' if filename.endswith('.m3u8') else 'video/mp2t'

    def close(self):
        with self.lock:
            self.closed = True
            for entry in self.entries.values():
                process = entry['process']
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
            shutil.rmtree(self.directory, ignore_errors=True)
