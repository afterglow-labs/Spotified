"""PKCE authorization whose loopback callback is received by a native client."""
import base64
import hashlib
import json
import secrets
import select
import sys
from urllib.parse import parse_qs, urlencode, urlsplit

import requests


def callback_values(url, authorization_url):
    """Accept only the callback and state belonging to this pending login."""
    if not isinstance(url, str) or len(url) > 12000:
        raise ValueError('Invalid Spotify callback.')
    expected = parse_qs(urlsplit(authorization_url).query)
    actual = urlsplit(url)
    redirect = urlsplit(expected['redirect_uri'][0])
    if (actual.scheme, actual.netloc, actual.path) != (redirect.scheme, redirect.netloc, redirect.path) or actual.fragment:
        raise ValueError('This callback does not belong to the pending Spotify sign-in.')
    query = parse_qs(actual.query)
    state = query.get('state', [])
    if len(state) != 1 or not secrets.compare_digest(state[0], expected['state'][0]):
        raise ValueError('Spotify sign-in state did not match. Start sign-in again.')
    codes, errors = query.get('code', []), query.get('error', [])
    if (len(codes), len(errors)) not in {(1, 0), (0, 1)}:
        raise ValueError('Spotify did not return an authorization code.')
    return {'state': state[0], 'code': codes[0]} if codes else {'state': state[0], 'error': 'access_denied'}


def client_login(client_id, scopes, port, emit, paced_call, *, input_stream=None, timeout=600):
    """Keep the verifier/token exchange on the server; receive the code via stdin."""
    from librespot.oauth import OAuth
    input_stream = input_stream or sys.stdin
    verifier, state = secrets.token_urlsafe(64), secrets.token_urlsafe(32)
    redirect = f'http://127.0.0.1:{port}/login'
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    url = 'https://accounts.spotify.com/authorize?' + urlencode(dict(
        response_type='code', client_id=client_id, redirect_uri=redirect,
        code_challenge=challenge, code_challenge_method='S256', scope=' '.join(scopes),
        state=state, show_dialog='true'))
    emit('login_url', url=url)
    if not select.select([input_stream], [], [], timeout)[0]:
        raise RuntimeError('Spotify sign-in expired. Start sign-in again.')
    line = input_stream.readline(16001)
    if not line or len(line) > 16000:
        raise RuntimeError('Spotify sign-in was closed. Start sign-in again.')
    callback = json.loads(line)
    if not isinstance(callback, dict) or not secrets.compare_digest(str(callback.get('state', '')), state):
        raise RuntimeError('Spotify sign-in state did not match.')
    if callback.get('error'):
        raise RuntimeError('Spotify sign-in was declined. Your previous credentials have been kept.')
    code = callback.get('code')
    if not isinstance(code, str) or not code:
        raise RuntimeError('Spotify did not return an authorization code.')
    response = paced_call(requests.post, 'https://accounts.spotify.com/api/token', data=dict(
        grant_type='authorization_code', client_id=client_id, redirect_uri=redirect,
        code=code, code_verifier=verifier), timeout=30)
    if response.status_code != 200:
        raise RuntimeError(f'Spotify rejected sign-in (HTTP {response.status_code}). Start sign-in again.')
    # Reuse the pinned library's public credential conversion, without storing tokens on the phone.
    return OAuth(client_id, redirect, None).ingest_token_response(response.json()).get_credentials()
