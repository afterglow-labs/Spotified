from io import BytesIO
from pathlib import Path
from shutil import which
from types import SimpleNamespace
from unittest.mock import Mock
import subprocess
import wave

import pytest

from spotified.api import DLContent, Track, Episode
from spotified.config import Config, Spotified, LogHandler


class InputStream(BytesIO):
    def pos(self):
        return self.tell()


class Stream:
    def __init__(self, payload, advertised_size=None, skip=0):
        self.input = InputStream(payload)
        self.input.seek(skip)
        self.size = len(payload) if advertised_size is None else advertised_size

    def stream(self):
        return self.input


@pytest.fixture
def track(monkeypatch):
    monkeypatch.setattr('spotified.api.sleep', Mock())
    track = Track('track:test')
    track.name = 'Example'
    track.duration_ms = 1000
    return track


def test_incomplete_stream_restarts_from_fresh_source(track, tmp_path, monkeypatch):
    original = Stream(b'partial', advertised_size=20)
    replacement = Stream(b'header-complete', skip=7)
    reconnect = Mock()
    fetch = Mock(return_value=replacement)
    monkeypatch.setattr(Spotified, 'reconnect', reconnect)
    monkeypatch.setattr(track, 'fetch_stream', fetch)
    path = tmp_path / 'audio.tmp'
    assert track.fetch_stream_content(original, path, SimpleNamespace(PBARS=[])) is not None
    assert path.read_bytes() == b'complete'
    reconnect.assert_called_once()
    fetch.assert_called_once()
    assert original.input.closed and replacement.input.closed


def test_truncated_stream_is_removed(track, tmp_path):
    Config.Values['RETRY_ATTEMPTS'] = 0
    path = tmp_path / 'audio.tmp'
    stream = Stream(b'partial', advertised_size=20)
    assert track.fetch_stream_content(stream, path, SimpleNamespace(PBARS=[])) is None
    assert not path.exists()
    assert stream.input.closed


def test_interrupt_does_not_retry_and_removes_partial(track, tmp_path, monkeypatch):
    stream = Stream(b'audio')
    stream.input.read = Mock(side_effect=KeyboardInterrupt)
    fetch = Mock()
    monkeypatch.setattr(track, 'fetch_stream', fetch)
    path = tmp_path / 'audio.tmp'
    with pytest.raises(KeyboardInterrupt):
        track.fetch_stream_content(stream, path, SimpleNamespace(PBARS=[]))
    assert not path.exists()
    assert stream.input.closed
    fetch.assert_not_called()


@pytest.mark.parametrize('delay', [0.5, 1, 2, 5, 6, 30])
def test_wait_respects_small_delays(track, delay):
    from spotified.api import sleep
    Config.Values['BULK_WAIT_TIME'] = delay
    track.wait_between_downloads()
    sleep.assert_called_once_with(delay)


class StreamingResponse:
    status_code = 200
    headers = {'Content-Length': '10'}
    closed = False

    @property
    def content(self):
        raise AssertionError('Stream response must not be buffered with .content')

    def iter_content(self, chunk_size):
        yield b'first'
        yield b'last!'

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.closed = True


def test_direct_episode_streams_and_closes_response(tmp_path, monkeypatch):
    episode = Episode('episode:test')
    monkeypatch.setattr(episode, 'set_dl_status', Mock())
    response = StreamingResponse()
    monkeypatch.setattr(Spotified, 'get_request', Mock(return_value=response))
    path = tmp_path / 'podcasts' / 'episode.tmp'
    assert episode.download_directly(path) is not None
    assert path.read_bytes() == b'firstlast!'
    assert response.closed


def test_direct_episode_truncation_is_removed(tmp_path, monkeypatch):
    episode = Episode('episode:test')
    monkeypatch.setattr(episode, 'set_dl_status', Mock())
    response = StreamingResponse()
    response.headers = {'Content-Length': '100'}
    monkeypatch.setattr(Spotified, 'get_request', Mock(return_value=response))
    path = tmp_path / 'episode.tmp'
    with pytest.raises(IOError, match='Incomplete'):
        episode.download_directly(path)
    assert not path.exists()
    assert response.closed


def test_cleanup_only_removes_owned_temporaries(tmp_path, monkeypatch):
    source = tmp_path / 'music' / 'song.ogg'
    source.parent.mkdir()
    unrelated = source.with_suffix('.tmp')
    unrelated.write_bytes(b'keep me')
    own = DLContent.temporary_download_path(source)
    own.write_bytes(b'partial')
    assert own != unrelated
    monkeypatch.setattr(LogHandler, 'kill_logger', Mock())
    Spotified.end()
    assert not own.exists()
    assert unrelated.read_bytes() == b'keep me'


@pytest.mark.skipif(not which('ffmpeg') or not which('ffprobe'), reason='FFmpeg is not installed')
def test_real_ffmpeg_conversion_is_atomic_and_handles_spaces(tmp_path):
    source = tmp_path / 'input file.wav'
    destination = tmp_path / 'output file.mp3'
    with wave.open(str(source), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(b'\x00\x00' * 800)
    destination.write_bytes(b'previous output')
    with pytest.raises(Exception):
        DLContent.run_ffm(source, None, destination, ['-c:a', 'invalid-test-codec'])
    assert source.is_file()
    assert destination.read_bytes() == b'previous output'
    assert not list(tmp_path.glob('.spotified_*'))
    DLContent.run_ffm(source, None, destination, ['-c:a', 'libmp3lame'])
    assert not source.exists()
    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'stream=codec_name',
                            '-of', 'csv=p=0', str(destination)], text=True, capture_output=True, check=True)
    assert probe.stdout.strip() == 'mp3'
    assert not list(tmp_path.glob('.spotified_*'))
