"""Regression coverage for requests hidden inside the downloader library."""
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
import requests
from librespot.audio import AudioKeyManager

from spotified.api import Track
from spotified.config import Config, Spotified
from spotified.pacing import RequestPacer
from test_http import response


@pytest.mark.parametrize('outcome', [response(200, {}), response(404, {}), requests.Timeout('offline')])
def test_application_http_always_waits_after_request(monkeypatch, outcome):
    events = []
    def request(*args, **kwargs):
        events.append('request')
        if isinstance(outcome, Exception):
            raise outcome
        return outcome
    monkeypatch.setattr('spotified.config.r_get', request)
    monkeypatch.setattr('spotified.config.sleep', lambda seconds: events.append(seconds))
    Spotified.get_request('https://example.test')
    assert events == ['request', 2]


@pytest.mark.parametrize('retry_after,expected', [('17', 30), ('123', 123)])
def test_rate_limit_waits_even_with_no_retries(monkeypatch, retry_after, expected):
    Config.Values['RETRY_ATTEMPTS'] = 0
    monkeypatch.setattr('spotified.config.LoginHandler.choose_token', lambda _: 'test')
    get = Mock(return_value=response(429, {}, {'Retry-After': retry_after}))
    wait = Mock()
    monkeypatch.setattr('spotified.config.r_get', get)
    monkeypatch.setattr('spotified.config.sleep', wait)
    assert Spotified.invoke_url('https://example.test', expectFail=True) == {}
    get.assert_called_once()
    wait.assert_called_once_with(expected)


def session_fixture():
    session = Mock()
    client = requests.Session()
    session.client.return_value = client
    manager = AudioKeyManager(session)
    session.audio_key.return_value = manager
    return session, client, manager


def test_librespot_http_and_redirects_wait_before_following(monkeypatch):
    events = []
    session, client, _ = session_fixture()
    redirect = response(302, {}, {'Location': 'https://example.test/next'})
    redirect.url = 'https://example.test/start'
    replies = iter([redirect, response(200, {})])
    def send(request, **kwargs):
        events.append(request.url)
        result = next(replies)
        result.request = request
        return result
    monkeypatch.setattr(client.get_adapter('https://'), 'send', send)
    Spotified.pace_session(session)
    Spotified.pace_session(session)  # Reinstalling must not double the delay.
    monkeypatch.setattr('spotified.config.sleep', lambda seconds: events.append(seconds))
    assert client.get('https://example.test/start').status_code == 200
    assert events == ['https://example.test/start', 2, 'https://example.test/next', 2]


@pytest.mark.parametrize('succeeds', [True, False])
def test_real_librespot_key_retries_are_bounded_and_delayed(monkeypatch, succeeds):
    events = []
    session, _, manager = session_fixture()
    session.send.side_effect = lambda *_: events.append('key')
    # The real library would issue an immediate second key request on None.
    monkeypatch.setattr(AudioKeyManager.SyncCallback, 'wait_response',
                        Mock(side_effect=[None, None, b'key' if succeeds else None]))
    monkeypatch.setattr('spotified.config.sleep', lambda seconds: events.append(seconds))
    monkeypatch.setattr('spotified.api.sleep', lambda seconds: events.append(seconds))
    monkeypatch.setattr(Spotified, 'SESSION', session)
    monkeypatch.setattr(Spotified, 'FORCE_STREAM_API_CALLS', False)
    monkeypatch.setattr(Spotified, 'to_libre_content', lambda *_: 'test-id')
    monkeypatch.setattr(Spotified, 'DOWNLOAD_QUALITY',
                        SimpleNamespace(preferred=SimpleNamespace(name='TEST'), get_file=lambda files: files[0]))
    monkeypatch.setattr('spotified.config.CdnFeedHelper.get_url', lambda _: 'https://example.test/audio')
    stream = session.cdn.return_value.stream_file.return_value
    stream.stream.return_value.skip.return_value = 0xA7
    Config.Values['RETRY_ATTEMPTS'] = 2
    Spotified.pace_session(session)
    Spotified.pace_session(session)
    track = Track('track:test')
    track.name = 'Test'
    track.gid = b'test-gid'
    track.file_ids = [{'file_id': 'ZmlsZQ=='}]
    assert track.fetch_stream() is (stream if succeeds else None)
    assert events == ['key', 2, 30, 'key', 2, 60, 'key', 2] + ([] if succeeds else [30])
    assert session.send.call_count == 3


def test_concurrent_requests_cannot_run_during_post_request_wait():
    sleeping, release, second_started, second_requested = Event(), Event(), Event(), Event()
    waits = []
    def wait(_):
        waits.append(True)
        if len(waits) == 1:
            sleeping.set()
            assert release.wait(2)
    pacer = RequestPacer(wait)
    def second():
        second_started.set()
        pacer.call(second_requested.set)
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(pacer.call, lambda: None)
        assert sleeping.wait(2)
        other = pool.submit(second)
        try:
            assert second_started.wait(2)
            assert not second_requested.wait(0.05)
        finally:
            release.set()
        first.result(timeout=2)
        other.result(timeout=2)
    assert second_requested.is_set()


def test_cancel_does_not_enter_another_wait():
    wait = Mock()
    with pytest.raises(KeyboardInterrupt):
        RequestPacer(wait).call(Mock(side_effect=KeyboardInterrupt))
    wait.assert_not_called()
