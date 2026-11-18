import hashlib
import shutil
import subprocess
import time

import pytest

from spotified.web_library import Library
from spotified.web_streaming import StreamCache


def test_stream_transcodes_preserves_source_and_cleans_cache(tmp_path):
    if not shutil.which('ffmpeg'):
        pytest.skip('FFmpeg required')
    source = tmp_path / 'Artist' / 'Album' / 'Song.ogg'
    source.parent.mkdir(parents=True)
    subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
                    '-t', '6', '-ac', '2', '-c:a', 'vorbis', '-strict', '-2', str(source)], check=True)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    cache = StreamCache(Library({'music': tmp_path}))
    directory = cache.directory
    try:
        url = cache.prepare('music', 'Artist/Album/Song.ogg')
        assert url == cache.prepare('music', 'Artist/Album/Song.ogg')
        assert len(cache.entries) == 1
        _, _, key, _ = url.split('/')
        data, kind = cache.resource(key, 'index.m3u8')
        assert kind == 'application/vnd.apple.mpegurl'
        assert b'#EXTINF:' in data
        for _ in range(100):
            if cache.entries[key]['process'].poll() is not None: break
            time.sleep(0.05)
        data, _ = cache.resource(key, 'index.m3u8')
        assert b'#EXT-X-ENDLIST' in data
        segment = next(line for line in data.decode().splitlines() if line.endswith('.ts'))
        audio, kind = cache.resource(key, segment)
        assert kind == 'video/mp2t' and len(audio) > 100
        assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
        for key, name in [('x' * 32, 'index.m3u8'), (key, '../credentials.json'), (key, 'seg99999.ts')]:
            with pytest.raises(ValueError): cache.resource(key, name)
    finally:
        cache.close()
    assert not directory.exists()


def test_supported_media_is_served_without_transcoding_and_paths_stay_in_library(tmp_path):
    (tmp_path / 'file.mp3').write_bytes(b'fixture')
    outside = tmp_path.parent / 'outside.mp3'
    outside.write_bytes(b'private')
    (tmp_path / 'escape.mp3').symlink_to(outside)
    cache = StreamCache(Library({'music': tmp_path}))
    try:
        assert cache.prepare('music', 'file.mp3') == '/media?root=music&path=file.mp3'
        assert not cache.entries
        for path in ['../outside.mp3', 'escape.mp3']:
            with pytest.raises(ValueError): cache.prepare('music', path)
    finally:
        cache.close()


def test_flac_playback_keeps_lossless_samples(tmp_path):
    if not shutil.which('ffmpeg'):
        pytest.skip('FFmpeg required')
    source = tmp_path / 'song.flac'
    subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                    '-t', '2', '-c:a', 'flac', '-sample_fmt', 's32', str(source)], check=True)
    cache = StreamCache(Library({'music': tmp_path}))
    try:
        url = cache.prepare('music', 'song.flac')
        _, _, key, filename = url.split('/')
        assert filename == 'audio.m4a'
        destination = cache.media_path(key, filename)
        def samples(path):
            return subprocess.check_output(['ffmpeg', '-nostdin', '-loglevel', 'error', '-i', str(path), '-f', 's32le', '-c:a', 'pcm_s32le', '-'])
        assert samples(source) == samples(destination)
    finally:
        cache.close()
