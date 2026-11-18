import base64
from io import BytesIO
import json
from pathlib import Path
import threading
import wave

from PIL import Image
import pytest
import requests

from spotified.web import JobManager, WebServer, spotify_urls
from spotified.web_auth import set_credentials, verify
from spotified.web_settings import Settings, LAYOUTS

TRACK = 'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC'


def test_spotify_browsing_and_import_require_server_session_and_csrf(server, monkeypatch):
    from spotified.spotify_catalog import CatalogError
    instance, base = server
    calls = []
    monkeypatch.setattr(instance.manager.catalog, 'browse', lambda params: calls.append(params) or {'items': [], 'total': 0})
    assert requests.get(base + '/api/spotify?view=liked').status_code == 401
    assert not calls
    session = login(base)
    assert session.get(base + '/api/spotify?view=search&q=R%26B').status_code == 200
    assert calls == [{'view': 'search', 'q': 'R&B'}]
    payload = {'uris': ['spotify:track:4uLU6hMCjMI75M1A2tKUQC']}
    assert requests.post(base + '/api/spotify/import', json=payload).status_code == 401
    assert session.post(base + '/api/spotify/import', json=payload, headers={'X-Spotified-Token': 'wrong'}).status_code == 403
    response = session.post(base + '/api/spotify/import', json=payload)
    assert response.status_code == 201
    assert response.json()['jobs'][0]['urls'] == [TRACK]
    def unavailable(_): raise CatalogError('Spotify unavailable')
    monkeypatch.setattr(instance.manager.catalog, 'browse', unavailable)
    assert session.get(base + '/api/spotify').status_code == 503
    assert session.get(base + '/api/state').status_code == 200


def test_spotify_selection_batches_and_validates_before_queueing(manager):
    uris = ['spotify:track:' + str(index).zfill(22) for index in range(43)]
    assert len(manager.import_selection({'uris': uris + [uris[0]], 'format': 'mp3'})) == 3
    assert sum(len(job['urls']) for job in manager.jobs) == 43
    assert all(job['format'] == 'mp3' for job in manager.jobs)
    before = len(manager.jobs)
    for payload in [{'uris': uris, 'format': 'bad'}, {'uris': [*uris, 'https://other.test']},
                    {'uris': []}, {'uris': ['spotify:artist:' + 'a' * 22]}, {'uris': uris * 5}]:
        with pytest.raises(ValueError): manager.import_selection(payload)
        assert len(manager.jobs) == before
    while len(manager.jobs) < 29: manager.add({'urls': TRACK})
    with pytest.raises(ValueError, match='enough room'):
        manager.import_selection({'uris': uris})
    assert len(manager.jobs) == 29


def test_native_login_callback_requires_session_csrf_state_and_pending_job(server):
    from io import StringIO
    from types import SimpleNamespace
    from urllib.parse import urlencode
    instance, base = server
    manager = instance.manager
    session = login(base)
    response = session.post(base + '/api/login', json={'mode': 'client', 'callback_port': 4381})
    assert response.status_code == 201
    job_id = response.json()['job']['id']
    assert session.post(base + '/api/login', json={'mode': 'client'}).json()['job']['id'] == job_id
    assert session.post(base + '/api/login', json={'mode': 'check'}).status_code == 400
    job = manager.jobs[0]
    job.update(status='running', login_url='https://accounts.spotify.com/authorize?' + urlencode({
        'state': 'fixture-state', 'redirect_uri': 'http://127.0.0.1:4381/login'}))
    manager.active_id = job_id
    stream = StringIO()
    manager.process = SimpleNamespace(stdin=stream, poll=lambda: 0)
    manager._save()
    assert 'login_url' not in manager.history_path.read_text()
    endpoint = base + '/api/jobs/' + job_id + '/spotify-callback'
    payload = {'url': 'http://127.0.0.1:4381/login?state=fixture-state&code=private-code'}
    assert requests.post(endpoint, json=payload).status_code == 401
    assert session.post(endpoint, json=payload, headers={'X-Spotified-Token': 'wrong'}).status_code == 403
    assert session.post(endpoint, json={'url': payload['url'].replace('fixture-state', 'wrong')}).status_code == 400
    assert stream.getvalue() == ''
    assert session.post(endpoint, json=payload).status_code == 200
    assert json.loads(stream.getvalue()) == {'state': 'fixture-state', 'code': 'private-code'}
    assert session.post(endpoint, json=payload).status_code == 400
    assert 'private-code' not in json.dumps(manager.state())
    assert 'private-code' not in manager.history_path.read_text()
    manager.cancel(job_id)
    assert session.post(endpoint, json=payload).status_code == 400


def test_spotify_login_input_validation(manager):
    for payload in [{'mode': 'unknown'}, {'mode': 'client', 'callback_port': 80},
                    {'mode': 'client', 'callback_port': True}, {'mode': 'client', 'callback_port': '4381'}]:
        with pytest.raises(ValueError): manager.add(payload, login=True)


def test_playback_requires_authentication_and_csrf_and_rejects_escaping_paths(server):
    instance, base = server
    root = instance.manager.roots['music']
    wav(root / 'Artist' / 'Album' / 'Song.wav')
    payload = {'root': 'music', 'path': 'Artist/Album/Song.wav'}
    assert requests.post(base + '/api/playback', json=payload).status_code == 401
    assert requests.get(base + '/stream/' + 'a' * 32 + '/index.m3u8').status_code == 401
    session = login(base)
    assert session.post(base + '/api/playback', json=payload, headers={'X-Spotified-Token': 'bad'}).status_code == 403
    result = session.post(base + '/api/playback', json=payload)
    assert result.status_code == 200
    response = session.get(base + result.json()['url'], headers={'Range': 'bytes=0-9'})
    assert response.status_code == 206 and len(response.content) == 10
    assert session.post(base + '/api/playback', json={'root': 'music', 'path': '../credentials.json'}).status_code == 400


@pytest.fixture
def manager(tmp_path):
    music = tmp_path / 'music'
    music.mkdir()
    config = dict(ROOT_PATH=str(music), ROOT_PODCAST_PATH=str(tmp_path / 'podcasts'),
                  OUTPUT_ALBUM=LAYOUTS['albums'], OUTPUT_SINGLE=LAYOUTS['albums'], FETCH_DELAY=1)
    (tmp_path / 'config.json').write_text(json.dumps(config))
    return JobManager(tmp_path, start=False)


@pytest.fixture
def server(manager):
    set_credentials(manager.config_dir, 'test-user', 'test-password-123')
    server = WebServer(('127.0.0.1', 0), manager)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server, f'http://127.0.0.1:{server.server_port}'
    server.shutdown()
    server.server_close()
    manager.close()
    thread.join()


def login(base):
    session = requests.Session()
    response = session.post(base + '/api/session', auth=('test-user', 'test-password-123'), timeout=5)
    assert response.status_code == 200
    assert 'HttpOnly' in response.headers['Set-Cookie']
    state = session.get(base + '/api/state', timeout=5).json()
    session.headers['X-Spotified-Token'] = state['csrf_token']
    return session


def wav(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(8000)
        file.writeframes(b'\0\0' * 8000)


def test_password_hash_and_wrong_credentials(tmp_path):
    set_credentials(tmp_path, 'corey', 'a-test-password')
    raw = (tmp_path / 'server-auth.json').read_text()
    credentials = json.loads(raw)
    assert 'a-test-password' not in raw
    assert (tmp_path / 'server-auth.json').stat().st_mode & 0o777 == 0o600
    basic = lambda value: 'Basic ' + base64.b64encode(value.encode()).decode()
    assert verify(credentials, basic('corey:a-test-password'))
    assert not verify(credentials, basic('corey:wrong-password'))
    assert not verify(credentials, basic('someone:a-test-password'))
    assert not verify(credentials, 'Basic invalid')


def test_auth_host_origin_csrf_and_hidden_settings(server):
    _, base = server
    assert requests.get(base + '/api/health').json()['service'] == 'spotified'
    assert requests.get(base + '/api/state').status_code == 401
    assert requests.get(base + '/api/files').status_code == 401
    assert requests.get(base + '/media?root=music&path=file.wav').status_code == 401
    assert requests.get(base + '/api/health', headers={'Host': 'evil.test'}).status_code == 403
    session = login(base)
    assert session.post(base + '/api/jobs', json={'urls': TRACK}, headers={'Origin': 'https://evil.test'}).status_code == 403
    assert session.post(base + '/api/jobs', json={'urls': TRACK}, headers={'X-Spotified-Token': 'wrong'}).status_code == 403
    response = session.post(base + '/api/jobs', json={'urls': TRACK, 'preview': True})
    assert response.status_code == 201
    job = response.json()['job']
    assert 'settings' not in job
    assert session.post(base + f"/api/jobs/{job['id']}/cancel", json={}).status_code == 200
    assert session.get(base + '/api/state').json()['jobs'][0]['status'] == 'cancelled'


def test_auth_rate_limit(server):
    _, base = server
    for _ in range(10):
        assert requests.post(base + '/api/session', auth=('wrong','wrong')).status_code == 401
    assert requests.post(base + '/api/session', auth=('test-user','test-password-123')).status_code == 429


@pytest.mark.parametrize('value', ['http://open.spotify.com/track/123', 'https://evil.test/track/4uLU6hMCjMI75M1A2tKUQC', TRACK + '/oops', '', None])
def test_invalid_spotify_links(value):
    with pytest.raises(ValueError):
        spotify_urls(value)


def test_url_normalization():
    assert spotify_urls(TRACK + '?si=tracking\nspotify:track:4uLU6hMCjMI75M1A2tKUQC') == [TRACK]


def test_settings_are_validated_and_queued_jobs_keep_snapshot(manager):
    job = manager.add({'urls': TRACK})
    saved = manager.settings.save({'FETCH_DELAY': 2, 'layout': 'artists', 'playlist_layout': 'library', 'ALBUM_ART_TO_FILE': False})
    assert saved['FETCH_DELAY'] == 2
    assert manager.jobs[0]['settings']['FETCH_DELAY'] == 1
    assert manager.settings.raw()['OUTPUT_PLAYLIST_EXT'] == LAYOUTS['artists']
    assert 'settings' not in manager.state()['jobs'][0]
    for invalid in [{'ROOT_PATH': '/'}, {'FETCH_DELAY': -1}, {'RETRY_ATTEMPTS': 1.5}, {'FETCH_DELAY': float('nan')}, {'ALBUM_ART_TO_FILE': 'false'}]:
        with pytest.raises(ValueError):
            manager.settings.save(invalid)
    reopened = JobManager(manager.config_dir, start=False)
    assert reopened.jobs[0]['id'] == job['id']
    assert reopened.jobs[0]['status'] == 'interrupted'


def test_quality_defaults_overrides_and_queue_snapshot(manager):
    assert manager.settings.public()['quality'] == 'auto'
    assert manager.settings.public()['bitrate'] == 'best'
    for format in ['copy', 'mp3', 'aac', 'opus']:
        manager.settings.save({'format': format})
        assert manager.add({'urls': TRACK})['bitrate'] == 'best'
    manager.settings.save({'quality': 'very_high', 'bitrate': 'best'})
    default_job = manager.add({'urls': TRACK})
    assert default_job['quality'] == 'very_high'
    override_job = manager.add({'urls': TRACK, 'format': 'mp3', 'quality': 'normal', 'bitrate': '192k'})
    manager.settings.save({'quality': 'high'})
    queued = next(j for j in manager.jobs if j['id'] == override_job['id'])
    assert queued['settings']['DOWNLOAD_QUALITY'] == 'normal'
    assert queued['settings']['TRANSCODE_BITRATE'] == '192k'
    assert queued['settings']['DOWNLOAD_FORMAT'] == 'mp3'
    assert manager.settings.public()['quality'] == 'high'
    for payload in [{'quality': 'ultra'}, {'quality': None}, {'bitrate': '10000k'}, {'bitrate': []}]:
        before = manager.settings.raw()
        with pytest.raises(ValueError):
            manager.settings.save(payload)
        assert manager.settings.raw() == before
        with pytest.raises(ValueError):
            manager.add({'urls': TRACK, **payload})


def test_restart_preserves_sources_and_audio_but_uses_current_library(manager):
    album = 'https://open.spotify.com/album/4uLU6hMCjMI75M1A2tKUQC'
    original = manager.add({'urls': TRACK + '?si=example\n' + album, 'format': 'mp3',
                            'quality': 'high', 'bitrate': 'best'})
    manager.cancel(original['id'])
    manager.settings.save({'layout': 'artists', 'FETCH_DELAY': 2, 'format': 'aac', 'quality': 'normal'})
    reopened = JobManager(manager.config_dir, start=False)
    retry = reopened.restart(original['id'])
    assert retry['id'] != original['id']
    assert retry['restart_of'] == original['id']
    assert retry['urls'] == [TRACK, album]
    assert (retry['format'], retry['quality'], retry['bitrate']) == ('mp3', 'high', 'best')
    assert retry['status'] == 'queued'
    assert 'settings' not in retry
    saved = next(j for j in reopened.jobs if j['id'] == retry['id'])
    assert saved['settings']['OUTPUT_ALBUM'] == LAYOUTS['artists']
    assert saved['settings']['FETCH_DELAY'] == 2
    assert saved['settings']['SKIP_EXISTING'] is True
    assert next(j for j in reopened.jobs if j['id'] == original['id'])['status'] == 'cancelled'
    assert reopened.restart(original['id'])['id'] == retry['id']
    assert len(reopened.jobs) == 2
    assert json.loads(reopened.history_path.read_text())[0]['urls'] == [TRACK, album]


def test_restart_validation_and_preview_safety(server):
    instance, base = server
    session = login(base)
    job = instance.manager.add({'urls': TRACK, 'preview': True})
    endpoint = base + f"/api/jobs/{job['id']}/restart"
    assert requests.post(endpoint, json={}).status_code == 401
    assert session.post(endpoint, json={}, headers={'X-Spotified-Token': 'wrong'}).status_code == 403
    assert session.post(endpoint, json={}).status_code == 400
    instance.manager.cancel(job['id'])
    response = session.post(endpoint, json={})
    assert response.status_code == 201
    assert response.json()['job']['preview'] is True
    assert response.json()['job']['urls'] == [TRACK]
    assert session.post(base + '/api/jobs/' + '0' * 32 + '/restart', json={}).status_code == 404
    login_job = instance.manager.add({}, login=True)
    instance.manager.cancel(login_job['id'])
    with pytest.raises(ValueError):
        instance.manager.restart(login_job['id'])


@pytest.mark.parametrize('status', ['failed', 'partial', 'interrupted'])
def test_failed_and_interrupted_jobs_can_restart(manager, status):
    job = manager.add({'urls': TRACK})
    manager.jobs[0]['status'] = status
    assert manager.restart(job['id'])['status'] == 'queued'


def test_library_playlists_artwork_and_range(server):
    instance, base = server
    root = instance.manager.roots['music']
    path = root / 'Artist' / 'Album' / '01 - Track.wav'
    wav(path)
    Image.new('RGB', (500, 500), 'red').save(path.parent / 'cover.jpg')
    (root / 'Favorites.m3u8').write_text('#EXTM3U\nArtist/Album/01 - Track.wav\nmissing.mp3\n')
    outside = root.parent / 'outside.wav'
    wav(outside)
    (root / 'escape.wav').symlink_to(outside)
    session = login(base)
    data = session.get(base + '/api/files').json()
    assert len(data['tracks']) == 1
    assert data['playlists'][0]['tracks'] == [data['tracks'][0]['id']]
    assert data['playlists'][0]['unavailable'] == 1
    track = data['tracks'][0]
    response = session.get(base + track['href'], headers={'Range':'bytes=0-19'})
    assert response.status_code == 206
    assert response.content == path.read_bytes()[:20]
    assert session.get(base + track['href'], headers={'Range':'bytes=-10'}).content == path.read_bytes()[-10:]
    assert session.get(base + track['href'], headers={'Range':'bytes=999999-'}).status_code == 416
    image = session.get(base + track['artwork'])
    assert Image.open(BytesIO(image.content)).size == (360, 360)
    assert session.get(base + '/media?root=music&path=../outside.wav').status_code == 404
    assert session.get(base + '/media?root=music&path=escape.wav').status_code == 404
    assert session.get(base + '/api/files').json()['tracks'][0]['duration'] == 1


def test_failed_worker_exit_cannot_be_marked_completed(manager):
    class Process:
        pid = 987654321
        returncode = 1
        stdout = iter(['SPOTIFIED_WEB_EVENT {"kind":"result","status":"completed","completed":1,"total":1}\n'])
        def poll(self): return 1
        def wait(self): return 1
    manager.popen = lambda *args, **kwargs: Process()
    job = manager.add({'urls': TRACK})
    manager._run(job['id'])
    assert manager.jobs[0]['status'] == 'failed'
    assert not list(manager.config_dir.glob('job-*.json'))


def test_saved_missing_track_names_do_not_break_client_state(manager):
    job = manager.add({'urls': TRACK})
    manager.jobs[0].update(status='failed', total=2, names=[None, 'Known track'])
    manager._save()

    reopened = JobManager(manager.config_dir, start=False)
    restored = reopened.state()['jobs'][0]
    assert restored['names'] == ['Unknown track', 'Known track']
    assert restored['id'] == job['id']
    assert restored['urls'] == [TRACK]
    assert restored['status'] == 'failed'
    assert restored['total'] == 2
    assert json.loads(reopened.history_path.read_text())[0]['names'] == restored['names']


def test_missing_worker_track_names_are_safe_in_authenticated_state(server):
    instance, base = server
    manager = instance.manager

    class Process:
        pid = 987654321
        returncode = 1
        stdout = iter(['SPOTIFIED_WEB_EVENT ' + json.dumps({
            'kind': 'metadata', 'total': 5,
            'names': [None, 'Known track', '', '   ', 17],
        }) + '\n'])
        def poll(self): return 1
        def wait(self): return 1

    manager.popen = lambda *args, **kwargs: Process()
    job = manager.add({'urls': TRACK})
    manager._run(job['id'])
    session = login(base)
    response = session.get(base + '/api/state', timeout=5)
    assert response.status_code == 200
    result = response.json()['jobs'][0]
    assert result['names'] == ['Unknown track', 'Known track', 'Unknown track', 'Unknown track', 'Unknown track']
    assert result['total'] == 5
    assert result['status'] == 'failed'
    assert json.loads(manager.history_path.read_text())[0]['names'] == result['names']
