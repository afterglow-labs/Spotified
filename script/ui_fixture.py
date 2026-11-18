"""Temporary, offline server for UI tests. Never reads real credentials or music."""
import json
from pathlib import Path
import tempfile
import wave

import music_tag
from PIL import Image

from spotified.web import JobManager, WebServer
from spotified.web_auth import set_credentials
from spotified.web_settings import LAYOUTS

with tempfile.TemporaryDirectory(prefix='spotified-ui-') as directory:
    root = Path(directory)
    music = root / 'music'
    album = music / 'Fixture Artist' / 'Fixture Album'
    album.mkdir(parents=True)
    path = album / '01 - Test Tone.wav'
    with wave.open(str(path), 'wb') as file:
        file.setnchannels(1); file.setsampwidth(2); file.setframerate(8000)
        file.writeframes(b'\0\0' * 8000 * 4)
    tags = music_tag.load_file(str(path))
    for key, value in [('tracktitle','Test Tone'),('artist','Fixture Artist'),('album','Fixture Album'),('albumartist','Fixture Artist')]:
        tags[key] = value
    tags.save()
    Image.new('RGB', (500,500), '#e06c75').save(album / 'cover.jpg')
    (music / 'Test Playlist.m3u8').write_text('#EXTM3U\nFixture Artist/Fixture Album/01 - Test Tone.wav\n')
    (root / 'config.json').write_text(json.dumps(dict(ROOT_PATH=str(music), ROOT_PODCAST_PATH=str(root / 'podcasts'), OUTPUT_ALBUM=LAYOUTS['albums'], OUTPUT_SINGLE=LAYOUTS['albums'])))
    set_credentials(root, 'test-user', 'test-password-123')
    manager = JobManager(root, start=False)
    manager.account = dict(status='connected', message='Offline test account')
    server = WebServer(('127.0.0.1', 0), manager)
    print(server.server_port, flush=True)
    try: server.serve_forever()
    finally: server.server_close()
