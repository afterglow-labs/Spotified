"""Read Spotify search and the signed-in library using the saved desktop login.

The downloader owns credentials.json. This reader never writes it or changes the
Spotify library. Login5 must receive the same client token used by Pathfinder.
Protocol references and verified operations are recorded in docs/SPOTIFY-CATALOG.md.
"""
import base64
from collections import OrderedDict
import copy
import json
from pathlib import Path
import re
import threading
import time
from uuid import uuid4

import requests
from google.protobuf.message import DecodeError

CLIENT_ID = '65b708073fc0480ea92a077233ca87bd'
VERSION = '1.2.52.442'
USER_AGENT = 'Spotify/124200290 Linux/0 (librespot)'
PATHFINDER = 'https://api-partner.spotify.com/pathfinder/v2/query'
URI = re.compile(r'spotify:(track|album|playlist|artist|episode):[A-Za-z0-9]{22}')
SEARCH = {
    'track': ('searchTracks', 'b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751', 'tracksV2'),
    'album': ('searchAlbums', '202cb3305e31e5a0767ba7925f28bd728cf8f8b0217e6da43909056071cd70e9', 'albumsV2'),
    'playlist': ('searchPlaylists', 'd520014e748f9ea44f7707d8df1819867ac1205e8b7f3e28f22fe5fc858921b1', 'playlists'),
    'artist': ('searchArtists', '7bf95d754fdbe32c8b161fbbe54d1ae50974900df4dce4c8f1afcbcad153224d', 'artists'),
}
LIBRARY_HASH = '9f4da031f81274d572cfedaf6fc57a737c84b43d572952200b2c36aaa8fec1c6'
LIKED_HASH = '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240'
PAGE_SIZE = 20


class CatalogError(Exception):
    """A safe, actionable message without credentials or upstream response bodies."""


def image_url(value):
    """Only expose Spotify's public HTTPS image hosts, never arbitrary URLs."""
    if isinstance(value, str) and re.match(r'^https://(?:i|mosaic)\.scdn\.co/', value):
        return value
    return ''


def artwork(data):
    for source in (data.get('coverArt'), (data.get('albumOfTrack') or {}).get('coverArt'),
                   (data.get('visuals') or {}).get('avatarImage')):
        if isinstance(source, dict):
            for item in source.get('sources', []):
                if url := image_url(item.get('url')):
                    return url
    for item in (data.get('images') or {}).get('items', []):
        for source in item.get('sources', []):
            if url := image_url(source.get('url')):
                return url
    return ''


def catalog_item(wrapper):
    """Normalize different GraphQL wrappers, including unavailable library rows."""
    if not isinstance(wrapper, dict):
        return None
    wrapper = wrapper.get('item') or wrapper.get('track') or wrapper
    data = wrapper.get('data', wrapper)
    if not isinstance(data, dict):
        return None
    uri = data.get('uri') or wrapper.get('_uri') or ''
    match = URI.fullmatch(uri)
    if not match:
        return None
    kind = match[1]
    available = data.get('__typename') not in {'NotFound', 'RestrictedContent'} and (data.get('playability') or {}).get('playable', True)
    artists = ', '.join(x.get('profile', {}).get('name', '') for x in (data.get('artists') or {}).get('items', []) if isinstance(x, dict))
    owner = (data.get('ownerV2') or {}).get('data') or {}
    subtitle = artists or owner.get('name') or owner.get('username') or kind.capitalize()
    return dict(uri=uri, kind=kind, name=data.get('name') or (data.get('profile') or {}).get('name') or f'Unavailable {kind}',
                subtitle=subtitle, artwork=artwork(data), available=bool(available))


def page(items, total, offset, *, title='', raw_count=None):
    normalized = [item for item in items if item is not None]
    count = len(items) if raw_count is None else raw_count
    total = max(int(total or 0), offset + count)
    return dict(items=normalized, total=total, offset=offset, title=title,
                next_offset=offset + count if count and offset + count < total else None)


def spotify_id(gid):
    alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    value, result = int.from_bytes(gid, 'big'), ''
    while value:
        value, remainder = divmod(value, 62)
        result = alphabet[remainder] + result
    return result.rjust(22, '0')


class SpotifyCatalog:
    def __init__(self, config_dir):
        self.credentials = Path(config_dir) / 'credentials.json'
        self.lock = threading.Lock()
        self.http = requests.Session()
        self.http.headers['User-Agent'] = USER_AGENT
        self.device_id = uuid4().hex
        self.signature = None
        self.auth = {}
        self.expires = 0
        self.client_expires = 0
        self.client_token = ''
        self.spclient = ''
        self.cache = OrderedDict()
        self.next_request = 0
        self.retry_after = 0

    def _request(self, method, url, **kwargs):
        now = time.monotonic()
        if now < self.retry_after:
            raise CatalogError('Spotify asked us to slow down. Wait a little before trying again.')
        time.sleep(max(0, self.next_request - now))
        self.next_request = time.monotonic() + 0.5
        try:
            response = self.http.request(method, url, timeout=(5, 12), allow_redirects=False, **kwargs)
        except requests.RequestException as exc:
            raise CatalogError('Spotify could not be reached. Try again in a moment.') from exc
        if response.status_code == 429:
            try:
                delay = max(1, min(86400, int(response.headers.get('Retry-After', 60))))
            except (ValueError, TypeError):
                delay = 60
            self.retry_after = time.monotonic() + delay
            raise CatalogError('Spotify asked us to slow down. Wait a little before trying again.')
        if response.status_code == 401:
            self.expires = 0
            raise CatalogError('Spotify sign-in expired. Try again, or reconnect Spotify in Settings.')
        if response.status_code in (403, 412):
            raise CatalogError('Spotify did not accept this catalog request. Refresh, or check for a Spotified server update.')
        if response.status_code != 200:
            raise CatalogError(f'Spotify could not load this page (HTTP {response.status_code}). Try again.')
        return response

    def _login(self):
        from librespot.core import ClientToken, Connectivity, Login5
        try:
            stat = self.credentials.stat()
            signature = (stat.st_ino, stat.st_mtime_ns, stat.st_size)
            if self.signature != signature:
                self.signature = signature
                self.auth = {}
                self.expires = 0
                self.cache.clear()
            if self.expires > time.monotonic():
                return
            saved = json.loads(self.credentials.read_text())
            credential = base64.b64decode(saved['credentials'], validate=True)
            username = saved['username']
            if not isinstance(username, str) or not credential:
                raise ValueError()
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise CatalogError('Connect your Spotify account in Settings to browse your music.') from exc
        if self.client_expires <= time.monotonic():
            request = ClientToken.ClientTokenRequest(
                request_type=ClientToken.REQUEST_CLIENT_DATA_REQUEST,
                client_data=ClientToken.ClientDataRequest(client_id=CLIENT_ID, client_version=VERSION,
                    connectivity_sdk_data=Connectivity.ConnectivitySdkData(device_id=self.device_id,
                        platform_specific_data=Connectivity.PlatformSpecificData(windows=Connectivity.NativeWindowsData(
                            something1=10, something3=21370, something4=2, something6=9,
                            something7=332, something8=33404, something10=True)))))
            response = self._request('POST', 'https://clienttoken.spotify.com/v1/clienttoken',
                                     data=request.SerializeToString(), headers={'Accept': 'application/x-protobuf'})
            token = ClientToken.ClientTokenResponse()
            token.ParseFromString(response.content)
            self.client_token = token.granted_token.token
            if not self.client_token:
                raise CatalogError('Spotify could not validate this client. Try again later.')
            self.client_expires = time.monotonic() + max(30, token.granted_token.expires_after_seconds - 60)
        login = Login5.LoginRequest()
        login.client_info.client_id = CLIENT_ID
        login.client_info.device_id = self.device_id
        login.stored_credential.username = username
        login.stored_credential.data = credential
        response = self._request('POST', 'https://login5.spotify.com/v3/login', data=login.SerializeToString(),
                                 headers={'Accept': 'application/x-protobuf', 'Content-Type': 'application/x-protobuf',
                                          'client-token': self.client_token})
        result = Login5.LoginResponse()
        result.ParseFromString(response.content)
        if not result.HasField('ok'):
            raise CatalogError('Spotify sign-in needs attention. Reconnect Spotify in Settings.')
        self.auth = {'Authorization': 'Bearer ' + result.ok.access_token, 'client-token': self.client_token,
                     'app-platform': 'Win32_x86_64', 'spotify-app-version': VERSION}
        self.expires = time.monotonic() + max(30, result.ok.access_token_expires_in - 60)

    def _graphql(self, operation, digest, variables):
        data = self._request('POST', PATHFINDER, headers=self.auth, json={
            'operationName': operation, 'variables': variables,
            'extensions': {'persistedQuery': {'version': 1, 'sha256Hash': digest}},
        }).json()
        if data.get('errors') or not isinstance(data.get('data'), dict):
            raise CatalogError('Spotify could not read this part of your library. Refresh or check for a server update.')
        return data['data']

    def _protobuf(self, method, path, message, response_type):
        if not self.spclient:
            endpoints = self._request('GET', 'https://apresolve.spotify.com/', params={'type': 'spclient'}).json().get('spclient', [])
            valid = [host for host in endpoints if re.fullmatch(r'[a-zA-Z0-9.-]+\.spotify\.com(?::\d+)?', host)]
            if not valid:
                raise CatalogError('Spotify did not provide a catalog server. Try again.')
            self.spclient = 'https://' + valid[0]
        response = self._request(method, self.spclient + path,
                                 headers=self.auth | {'Content-Type': 'application/x-protobuf'},
                                 data=message.SerializeToString() if message is not None else None)
        result = response_type()
        result.ParseFromString(response.content)
        return result

    def _metadata(self, uris, kind):
        from librespot.core import BatchedEntityRequest, EntityRequest, ExtensionQuery, ExtensionKind, BatchedExtensionResponse, Metadata
        extension = {'track': ExtensionKind.TRACK_V4, 'album': ExtensionKind.ALBUM_V4, 'artist': ExtensionKind.ARTIST_V4}[kind]
        request = BatchedEntityRequest(entity_request=[EntityRequest(entity_uri=uri,
                    query=[ExtensionQuery(extension_kind=extension)]) for uri in dict.fromkeys(uris)])
        if not uris:
            return {}
        response = self._protobuf('POST', '/extended-metadata/v0/extended-metadata', request, BatchedExtensionResponse)
        found = {}
        for group in response.extended_metadata:
            for entry in group.extension_data:
                if entry.header.status_code == 200:
                    metadata = {'track': Metadata.Track, 'album': Metadata.Album, 'artist': Metadata.Artist}[kind]()
                    metadata.ParseFromString(entry.extension_data.value)
                    found[entry.entity_uri] = metadata
        return found

    @staticmethod
    def _metadata_item(uri, metadata, kind='track'):
        images = metadata.album.cover_group.image if kind == 'track' else metadata.cover_group.image
        return dict(uri=uri, kind=kind, name=metadata.name or 'Unknown ' + kind,
                    subtitle=', '.join(artist.name for artist in metadata.artist) or kind.capitalize(),
                    artwork='https://i.scdn.co/image/' + images[0].file_id.hex() if images else '', available=True)

    def _contents(self, uri, offset):
        from librespot.proto.Playlist4External_pb2 import SelectedListContent
        kind, identifier = URI.fullmatch(uri).groups()[0], uri.rsplit(':', 1)[1]
        if kind == 'playlist':
            playlist = self._protobuf('GET', f'/playlist/v2/playlist/{identifier}?from={offset}&length={PAGE_SIZE}', None, SelectedListContent)
            uris = [item.uri for item in playlist.contents.items]
            total, title = playlist.length, playlist.attributes.name
        elif kind == 'album':
            album = self._metadata([uri], 'album').get(uri)
            if album is None:
                raise CatalogError('This album is unavailable from Spotify.')
            all_uris = ['spotify:track:' + spotify_id(track.gid) for disc in album.disc for track in disc.track if track.gid]
            total, title = len(all_uris), album.name
            uris = all_uris[offset:offset + PAGE_SIZE]
        else:
            artist = self._metadata([uri], 'artist').get(uri)
            if artist is None:
                raise CatalogError('This artist is unavailable from Spotify.')
            all_uris = list(dict.fromkeys('spotify:album:' + spotify_id(album.gid)
                for group in [*artist.album_group, *artist.single_group, *artist.compilation_group]
                for album in group.album if album.gid))
            uris = all_uris[offset:offset + PAGE_SIZE]
            found = self._metadata(uris, 'album')
            return page([self._metadata_item(item, found[item], 'album') if item in found else None for item in uris],
                        len(all_uris), offset, title=artist.name)
        tracks = [item for item in uris if re.fullmatch(r'spotify:track:[A-Za-z0-9]{22}', item)]
        found = self._metadata(tracks, 'track')
        return page([self._metadata_item(item, found[item]) if item in found else None for item in uris], total, offset, title=title)

    def browse(self, params):
        action = params.get('view', 'playlists')
        if action not in {'playlists', 'albums', 'artists', 'liked', 'search', 'contents'}:
            raise ValueError('Choose playlists, liked songs, saved albums, artists, or search.')
        try:
            offset = int(params.get('offset', '0'))
            if not 0 <= offset <= 100000:
                raise ValueError()
        except (ValueError, TypeError) as exc:
            raise ValueError('Invalid Spotify page.') from exc
        query = str(params.get('q', '')).strip()
        kind = params.get('kind', 'track')
        uri = params.get('uri', '')
        if action == 'search' and (not 1 <= len(query) <= 200 or kind not in SEARCH):
            raise ValueError('Enter a search of up to 200 characters and choose a supported type.')
        if action == 'contents' and (not URI.fullmatch(uri) or uri.split(':')[1] not in {'playlist', 'album', 'artist'}):
            raise ValueError('Choose a Spotify playlist, album, or artist.')
        if not self.lock.acquire(timeout=1):
            raise CatalogError('Spotify is loading another page. Try again in a moment.')
        try:
            self._login()
            key = (action, offset, query, kind, uri)
            cached = self.cache.get(key)
            if params.get('refresh') != '1' and cached and time.monotonic() - cached[0] < 60:
                return copy.deepcopy(cached[1])
            if action == 'contents':
                result = self._contents(uri, offset)
            elif action == 'search':
                operation, digest, section = SEARCH[kind]
                data = self._graphql(operation, digest, dict(searchTerm=query, offset=offset, limit=PAGE_SIZE,
                    numberOfTopResults=5, includeAudiobooks=False, includeArtistHasConcertsField=False,
                    includePreReleases=False, includeLocalConcertsField=False, includeAuthors=False))['searchV2'][section]
                result = page([catalog_item(item) for item in data['items']], data.get('totalCount'), offset, title=query)
            elif action == 'liked':
                data = self._graphql('fetchLibraryTracks', LIKED_HASH, dict(limit=PAGE_SIZE, offset=offset))['me']['library']['tracks']
                result = page([catalog_item(item) for item in data['items']], data.get('totalCount'), offset, title='Liked songs')
            else:
                title = {'playlists': 'Playlists', 'albums': 'Albums', 'artists': 'Artists'}[action]
                data = self._graphql('libraryV3', LIBRARY_HASH, dict(filters=[title], order=None, textFilter='', features=[],
                    limit=PAGE_SIZE, offset=offset, flatten=True, expandedFolders=[], folderUri=None,
                    includeFoldersWhenFlattening=False))['me']['libraryV3']
                result = page([catalog_item(item) for item in data['items']], data.get('totalCount'), offset, title='Your ' + title.lower())
            self.cache[key] = (time.monotonic(), result)
            self.cache.move_to_end(key)
            while len(self.cache) > 64:
                self.cache.popitem(last=False)
            return copy.deepcopy(result)
        except (KeyError, TypeError, ValueError, AttributeError, DecodeError) as exc:
            raise CatalogError('Spotify returned an unexpected catalog response. Refresh or check for a server update.') from exc
        finally:
            self.lock.release()
