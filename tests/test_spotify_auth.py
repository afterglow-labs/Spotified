import base64
import hashlib
import json
import os
from urllib.parse import parse_qs, urlencode, urlsplit

import pytest

from spotified.spotify_auth import callback_values, client_login

AUTH = 'https://accounts.spotify.com/authorize?' + urlencode({
    'state': 'expected-state', 'redirect_uri': 'http://127.0.0.1:4381/login'})


def test_callback_checks_exact_destination_state_and_single_result():
    assert callback_values('http://127.0.0.1:4381/login?state=expected-state&code=ok', AUTH)['code'] == 'ok'
    assert callback_values('http://127.0.0.1:4381/login?state=expected-state&error=access_denied', AUTH)['error'] == 'access_denied'
    for url in [None, 'http://evil.test/login?state=expected-state&code=ok',
                'http://127.0.0.1:4382/login?state=expected-state&code=ok',
                'http://127.0.0.1:4381/login?state=other&code=ok',
                'http://127.0.0.1:4381/login?state=expected-state&state=other&code=ok',
                'http://127.0.0.1:4381/login?state=expected-state&code=one&code=two',
                'http://127.0.0.1:4381/login?state=expected-state&code=ok&error=denied',
                'http://127.0.0.1:4381/login?state=expected-state',
                'http://127.0.0.1:4381/login?state=expected-state&code=ok#fragment']:
        with pytest.raises(ValueError):
            callback_values(url, AUTH)


def test_client_pkce_exchange_keeps_verifier_on_server_and_is_paced():
    read_fd, write_fd = os.pipe()
    captured, calls = {}, []
    def emit(kind, url):
        assert kind == 'login_url'
        captured.update(parse_qs(urlsplit(url).query))
        assert 'code_verifier' not in captured
        os.write(write_fd, (json.dumps({'state': captured['state'][0], 'code': 'authorization-code'}) + '\n').encode())
    def paced(operation, url, **kwargs):
        calls.append(url)
        data = kwargs['data']
        assert kwargs['timeout'] == 30
        assert data['code'] == 'authorization-code'
        challenge = base64.urlsafe_b64encode(hashlib.sha256(data['code_verifier'].encode()).digest()).decode().rstrip('=')
        assert challenge == captured['code_challenge'][0]
        assert data['redirect_uri'] == captured['redirect_uri'][0]
        class Response:
            status_code = 200
            def json(self): return {'access_token': 'fixture-token', 'expires_in': 3600}
        return Response()
    try:
        with os.fdopen(read_fd) as stream:
            credentials = client_login('fixture-client', ['streaming'], 4381, emit, paced, input_stream=stream)
        assert credentials.auth_data == b'fixture-token'
        assert calls == ['https://accounts.spotify.com/api/token']
        assert captured['show_dialog'] == ['true']
    finally:
        os.close(write_fd)


@pytest.mark.parametrize('result', ['denied', 'wrong-state', 'timeout'])
def test_client_login_failure_never_exchanges_a_token(result):
    read_fd, write_fd = os.pipe()
    def emit(kind, url):
        if result == 'timeout': return
        state = parse_qs(urlsplit(url).query)['state'][0]
        value = {'state': state, 'error': 'access_denied'} if result == 'denied' else {'state': 'wrong', 'code': 'code'}
        os.write(write_fd, (json.dumps(value) + '\n').encode())
    def never(*args, **kwargs): pytest.fail('Failed authorization must not exchange tokens')
    try:
        with os.fdopen(read_fd) as stream, pytest.raises(RuntimeError):
            client_login('fixture', [], 4381, emit, never, input_stream=stream, timeout=0.01)
    finally:
        os.close(write_fd)
