"""Read the server's music library without moving or modifying media files."""
from io import BytesIO
from pathlib import Path
import threading
from urllib.parse import quote

import music_tag
from PIL import Image, UnidentifiedImageError

MEDIA_EXTENSIONS = {'.ogg', '.mp3', '.m4a', '.opus', '.flac', '.wav'}


class Library:
    def __init__(self, roots):
        self.roots = roots
        self.cache = {}
        self.lock = threading.RLock()

    def path(self, kind, relative, extensions=MEDIA_EXTENSIONS):
        if kind not in self.roots:
            raise ValueError('Unknown library')
        root = self.roots[kind].resolve()
        path = (root / relative).resolve()
        if not path.is_relative_to(root) or path.suffix.lower() not in extensions or not path.is_file():
            raise ValueError('File is outside the library or unavailable')
        return path

    def _track(self, kind, path):
        stat = path.stat()
        key = str(path)
        signature = (stat.st_mtime_ns, stat.st_size)
        cached = self.cache.get(key)
        if cached and cached[0] == signature:
            return cached[1]
        relative = path.relative_to(self.roots[kind]).as_posix()
        query = f'root={kind}&path={quote(relative, safe="")}'
        track = dict(id=f'{kind}/{relative}', name=path.name, title=path.stem,
                     artist='Unknown artist', album='Unknown album', album_artist='', genre='',
                     duration=0, track_number=0, disc_number=1, year='', folder=str(Path(relative).parent),
                     size=stat.st_size, modified=stat.st_mtime, kind=kind,
                     href=f'/media?{query}', artwork=f'/artwork?{query}')
        try:
            tags = music_tag.load_file(str(path))
            for target, tag in [('title', 'tracktitle'), ('artist', 'artist'), ('album', 'album'),
                                ('album_artist', 'albumartist'), ('genre', 'genre')]:
                track[target] = str(tags[tag]) or track[target]
            track['duration'] = float(tags['#length'].value or 0)
            track['track_number'] = int(tags['tracknumber'].value or 0)
            track['disc_number'] = int(tags['discnumber'].value or 1)
            track['year'] = str(tags['year'])[:4]
        except Exception:  # A damaged tag must not hide the rest of the library.
            pass
        self.cache[key] = (signature, track)
        return track

    def scan(self):
        with self.lock:
            tracks, lists, seen = [], [], set()
            truncated = False
            for kind, root in self.roots.items():
                if not root.is_dir():
                    continue
                for path in root.rglob('*'):
                    try:
                        if path.suffix.lower() not in MEDIA_EXTENSIONS | {'.m3u8', '.m3u'}:
                            continue
                        path = self.path(kind, path.relative_to(root), MEDIA_EXTENSIONS | {'.m3u8', '.m3u'})
                        if str(path) in seen:
                            continue
                        seen.add(str(path))
                        if path.suffix.lower() in {'.m3u8', '.m3u'}:
                            lists.append((kind, path))
                        elif path.stat().st_size:
                            tracks.append(self._track(kind, path))
                        if len(tracks) >= 20000:
                            truncated = True
                            break
                    except (ValueError, OSError):
                        continue
            self.cache = {k: v for k, v in self.cache.items() if k in seen}
            by_path = {str(self.roots[t['kind']] / t['id'].split('/', 1)[1]): t['id'] for t in tracks}
            playlists = []
            for kind, path in lists:
                try:
                    if path.stat().st_size > 5_000_000:
                        continue
                    ids, unavailable = [], 0
                    for line in path.read_text(encoding='utf-8-sig', errors='replace').splitlines():
                        if not line.strip() or line.startswith('#'):
                            continue
                        identifier = by_path.get(str((path.parent / line).resolve()))
                        if identifier:
                            ids.append(identifier)
                        else:
                            unavailable += 1
                    relative = path.relative_to(self.roots[kind]).as_posix()
                    playlists.append(dict(id=f'{kind}/{relative}', name=path.stem, tracks=ids,
                                          unavailable=unavailable, href=f'/playlist?root={kind}&path={quote(relative, safe="")}'))
                except OSError:
                    continue
            return dict(tracks=sorted(tracks, key=lambda t: t['modified'], reverse=True),
                        playlists=playlists, truncated=truncated)

    def artwork(self, kind, relative):
        path = self.path(kind, relative)
        root = self.roots[kind]
        data = None
        for candidate in [path.with_suffix('.jpg'), path.with_suffix('.png'),
                          path.parent / 'cover.jpg', path.parent / 'cover.png']:
            if candidate.resolve().is_relative_to(root) and candidate.is_file() and candidate.stat().st_size < 20_000_000:
                data = candidate.read_bytes()
                break
        if data is None:
            try:
                art = music_tag.load_file(str(path))['artwork'].values
                if art:
                    data = art[0].raw
            except Exception:
                pass
        if not data or len(data) > 20_000_000:
            raise ValueError('No cover art')
        try:
            with Image.open(BytesIO(data)) as source:
                source.thumbnail((360, 360))
                output = BytesIO()
                source.convert('RGB').save(output, format='JPEG', quality=85)
                return output.getvalue()
        except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
            raise ValueError('Invalid cover art') from exc
