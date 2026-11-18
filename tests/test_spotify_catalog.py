import base64
import json
from types import SimpleNamespace

import pytest

from spotified.spotify_catalog import CatalogError, SpotifyCatalog, catalog_item, page

TRACK_URI = 'spotify:track:' + 'a' * 22


def test_library_track_wrappers_and_unavailable_rows():
    item = catalog_item({'track': {'_uri': TRACK_URI, 'data': {
        '__typename': 'Track', 'name': 'Song', 'artists': {'items': [{'profile': {'name': 'Artist'}}]},
        'albumOfTrack': {'coverArt': {'sources': [{'url': 'https://i.scdn.co/image/cover'}]}},
    }}})
    assert item == dict(uri=TRACK_URI, kind='track', name='Song', subtitle='Artist',
                        artwork='https://i.scdn.co/image/cover', available=True)
    missing = catalog_item({'item': {'_uri': 'spotify:playlist:' + 'b' * 22, 'data': {'__typename': 'NotFound'}}})
    assert missing['name'] == 'Unavailable playlist'
    assert missing['available'] is False
    assert catalog_item({'track': {'data': None}}) is None
    assert catalog_item({'uri': 'https://untrusted.test/song', 'name': 'unsafe'}) is None


def test_pagination_uses_source_count_even_when_rows_are_unavailable():
    value = page([None, dict(uri=TRACK_URI)], 45, 20)
    assert value['next_offset'] == 22
    assert len(value['items']) == 1
    assert page([], 45, 22)['next_offset'] is None


def test_login5_and_catalog_share_client_token_without_writing_credentials(tmp_path, monkeypatch):
    from librespot.core import ClientToken, Login5
    creds = tmp_path / 'credentials.json'
    original = json.dumps(dict(username='test-user', credentials=base64.b64encode(b'fixture-credential').decode(), type='AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS'))
    creds.write_text(original)
    catalog = SpotifyCatalog(tmp_path)
    calls = []
    def request(method, url, **kwargs):
        calls.append(url)
        if 'clienttoken.spotify.com' in url:
            token = ClientToken.ClientTokenResponse()
            token.granted_token.token = 'fixture-client-token'
            token.granted_token.expires_after_seconds = 3600
            return SimpleNamespace(content=token.SerializeToString())
        assert kwargs['headers']['client-token'] == 'fixture-client-token'
        if 'login5.spotify.com' in url:
            body = Login5.LoginRequest(); body.ParseFromString(kwargs['data'])
            assert body.stored_credential.username == 'test-user'
            assert body.stored_credential.data == b'fixture-credential'
            reply = Login5.LoginResponse(); reply.ok.access_token = 'fixture-access-token'; reply.ok.access_token_expires_in = 3600
            return SimpleNamespace(content=reply.SerializeToString())
        assert kwargs['headers']['Authorization'] == 'Bearer fixture-access-token'
        return SimpleNamespace(json=lambda: {'data': {'me': {'library': {'tracks': {'items': [], 'totalCount': 0}}}}})
    monkeypatch.setattr(catalog, '_request', request)
    result = catalog.browse({'view': 'liked'})
    assert result['items'] == []
    result['items'].append('client mutation')
    assert catalog.browse({'view': 'liked'})['items'] == []
    assert len(calls) == 3  # Repeated browsing uses cached login and result.
    assert creds.read_text() == original
    assert 'fixture-access-token' not in json.dumps(catalog.browse({'view': 'liked'}))
    creds.write_text(original.replace('test-user', 'new-user'))
    def new_login(*args, **kwargs):
        raise CatalogError('new account needs login')
    monkeypatch.setattr(catalog, '_request', new_login)
    with pytest.raises(CatalogError, match='new account'):
        catalog.browse({'view': 'liked'})
    assert not catalog.cache


def test_rate_limit_stops_requests_until_retry_after(tmp_path, monkeypatch):
    catalog = SpotifyCatalog(tmp_path)
    calls = []
    def request(*args, **kwargs):
        calls.append(kwargs)
        return SimpleNamespace(status_code=429, headers={'Retry-After': '120'})
    monkeypatch.setattr(catalog.http, 'request', request)
    for _ in range(2):
        with pytest.raises(CatalogError, match='slow down'):
            catalog._request('GET', 'https://example.test')
    assert len(calls) == 1
    assert calls[0]['timeout'] == (5, 12)
    assert calls[0]['allow_redirects'] is False


@pytest.mark.parametrize('params', [
    {'view': 'contents', 'uri': 'https://other.test/private'},
    {'view': 'search', 'q': 'x' * 201}, {'offset': '-1'}, {'view': 'delete'},
])
def test_invalid_catalog_input_never_connects(tmp_path, monkeypatch, params):
    catalog = SpotifyCatalog(tmp_path)
    monkeypatch.setattr(catalog, '_login', lambda: pytest.fail('Invalid input started login'))
    with pytest.raises(ValueError): catalog.browse(params)


def test_expired_spotify_token_does_not_expire_server_login(tmp_path, monkeypatch):
    catalog = SpotifyCatalog(tmp_path)
    monkeypatch.setattr(catalog.http, 'request', lambda *a, **k: SimpleNamespace(status_code=401))
    catalog.expires = 9999999999
    with pytest.raises(CatalogError, match='Spotify sign-in expired'):
        catalog._request('GET', 'https://example.test')
    assert catalog.expires == 0
