import json
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from requests import Response
from requests.exceptions import ConnectionError, Timeout

from spotified.config import Config, Spotified, LoginHandler


def response(status, body=None, headers=None):
    result = Response()
    result.status_code = status
    result._content = body if isinstance(body, bytes) else json.dumps(body).encode()
    result.headers.update(headers or {})
    return result


@pytest.fixture
def api(monkeypatch):
    monkeypatch.setattr(LoginHandler, 'choose_token', lambda _: 'test-token')
    sleeper = Mock()
    monkeypatch.setattr('spotified.config.sleep', sleeper)
    return sleeper


@pytest.mark.parametrize('exception', [Timeout, ConnectionError])
def test_transport_errors_can_retry(monkeypatch, api, exception):
    get = Mock(side_effect=[exception('offline'), response(200, {'ok': True})])
    monkeypatch.setattr('spotified.config.r_get', get)
    assert Spotified.invoke_url('https://example.test') == {'ok': True}
    assert get.call_count == 2


@pytest.mark.parametrize('bad', [b'', b'<html>error</html>', b'[]', b'null'])
def test_invalid_success_json_is_not_returned(monkeypatch, api, bad):
    get = Mock(return_value=response(200, bad))
    monkeypatch.setattr(Spotified, 'get_request', get)
    assert Spotified.invoke_url('https://example.test', expectFail=True) == {}
    assert get.call_count == 2


def test_expected_failure_still_respects_rate_limit(monkeypatch, api):
    get = Mock(side_effect=[response(429, {}, {'Retry-After': '123'}), response(200, {'ok': True})])
    monkeypatch.setattr(Spotified, 'get_request', get)
    assert Spotified.invoke_url('https://example.test', expectFail=True) == {'ok': True}
    assert api.call_args_list[0].args == (123,)


@pytest.mark.parametrize('header', ['bad', '-1', 'nan', 'inf', ''])
def test_invalid_retry_header_is_safe(header):
    assert Spotified.retry_after(response(429, {}, {'Retry-After': header})) == 0


def test_retry_header_accepts_http_date():
    date = format_datetime(datetime.now(timezone.utc) + timedelta(seconds=60), usegmt=True)
    assert 58 <= Spotified.retry_after(response(429, {}, {'Retry-After': date})) <= 60


@pytest.mark.parametrize('status', [400, 401, 403, 404, 204])
def test_permanent_errors_and_no_content_do_not_retry(monkeypatch, api, status):
    get = Mock(return_value=response(status, b''))
    monkeypatch.setattr(Spotified, 'get_request', get)
    assert Spotified.invoke_url('https://example.test') == {}
    assert get.call_count == 1


def test_large_pagination_is_iterative(monkeypatch):
    def get(url, params=None):
        index = int(url.rsplit('/', 1)[-1])
        return {'items': [index], 'next': f'https://example.test/{index+1}' if index < 1100 else None}
    monkeypatch.setattr(Spotified, 'invoke_url', get)
    assert Spotified.invoke_url_nextable('https://example.test/0') == list(range(1101))


def test_pagination_limit_and_cycle(monkeypatch):
    get = Mock(return_value={'items': [1, 2, 3], 'next': 'https://example.test/0'})
    monkeypatch.setattr(Spotified, 'invoke_url', get)
    assert Spotified.invoke_url_nextable('https://example.test/0', max=2) == [1, 2]
    assert Spotified.invoke_url_nextable('https://example.test/0') == [1, 2, 3]
    assert get.call_count == 2


def test_bulk_metadata_preserves_missing_item_positions(monkeypatch, api):
    proto = SimpleNamespace(gid=b'gid')
    session = Mock()
    session.api.return_value.get_metadata_4_multiple.return_value = [proto, None]
    monkeypatch.setattr(Spotified, 'SESSION', session)
    monkeypatch.setattr(Spotified, 'to_libre_content', lambda *_: object())
    monkeypatch.setattr('spotified.config.MessageToDict', lambda *a, **kw: {'gid': 'encoded'})
    result = Spotified.invoke_libre_bulk_md(SimpleNamespace(uppers='TRACKS'), ['track:a', 'track:b'])
    assert result == [{'gid': b'gid'}, None]
