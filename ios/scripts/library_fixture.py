#!/usr/bin/env python3
"""Real authenticated playback API with disposable, silent test albums."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import parse_qs, urlsplit

import music_tag

from spotified.web import Handler, JobManager, WebServer
from spotified.web_auth import set_credentials
from spotified.web_settings import LAYOUTS

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=18770)
parser.add_argument('--vorbis-sample', type=Path, help='Use a copy of a real Ogg track as the opening song.')
args = parser.parse_args()
counts = {'playback': 0, 'segments': 0, 'original_ranges': 0}


class FixtureHandler(Handler):
    def do_GET(self):
        if self.path == '/test/receipt': return self._json(counts)
        url = urlsplit(self.path)
        if (url.path == '/media' and self.headers.get('Range') and self._authorized()
                and parse_qs(url.query).get('path', [''])[0].lower().endswith('.ogg')):
            counts['original_ranges'] += 1
        if self.path.startswith('/stream/') and '.ts' in self.path and self._authorized(): counts['segments'] += 1
        return super().do_GET()

    def do_POST(self):
        if self.path == '/api/playback' and self._authorized(): counts['playback'] += 1
        return super().do_POST()


with tempfile.TemporaryDirectory(prefix='spotified-library-qa-') as directory:
    root = Path(directory); music = root / 'music'
    rows = [('Alpha Artist', 'First Album', 'Opening Song', 1, 1, 2001),
            ('Alpha Artist', 'First Album', 'Second Song', 1, 2, 2001),
            ('Alpha Artist', 'First Album', 'Disc Two Song', 2, 1, 2001),
            ('Alpha Artist', 'Second Album', 'New Song', 1, 1, 2020),
            ('Beta Artist', 'First Album', 'Other Song', 1, 1, 2005)]
    for artist, album, title, disc, track, year in rows:
        lossless = title == 'Second Song'
        path = music / artist / album / (title + ('.flac' if lossless else '.ogg'))
        path.parent.mkdir(parents=True, exist_ok=True)
        if args.vorbis_sample and title == 'Opening Song':
            shutil.copyfile(args.vorbis_sample, path)
        else:
            subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo', '-t', '20', '-c:a', 'flac' if lossless else 'vorbis', '-strict', '-2', str(path)], check=True)
        tags = music_tag.load_file(str(path))
        for key, value in [('artist', artist), ('albumartist', artist), ('album', album), ('tracktitle', title), ('discnumber', disc), ('tracknumber', track), ('year', year)]: tags[key] = value
        tags.save()
    (music / 'QA deletion playlist.m3u8').write_text(
        '#EXTM3U\nAlpha Artist/First Album/Opening Song.ogg\nAlpha Artist/First Album/Second Song.flac\n')
    (root / 'config.json').write_text(json.dumps(dict(ROOT_PATH=str(music), ROOT_PODCAST_PATH=str(root / 'podcasts'), OUTPUT_ALBUM=LAYOUTS['albums'], OUTPUT_SINGLE=LAYOUTS['albums'])))
    set_credentials(root, 'fixture-user', 'fixture-password')
    manager = JobManager(root, start=False); manager.account = dict(status='connected', message='Offline fixture')
    server = WebServer(('127.0.0.1', args.port), manager)
    server.RequestHandlerClass = FixtureHandler
    print(f'Library playback fixture ready on port {server.server_port}', flush=True)
    try: server.serve_forever()
    finally: server.server_close(); manager.close()
