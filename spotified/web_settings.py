"""A small, validated subset of downloader settings exposed by the app."""
import json
import math
from pathlib import Path

LAYOUTS = {
    'albums': '{album_artist}/{album}/{disc_number}-{track_number} - {song_name}',
    'artists': '{artist}/{song_name}',
    'flat': '{artist} - {song_name}',
}
PLAYLIST = 'Playlists/{playlist}/{playlist_num} - {artist} - {song_name}'
BOOLEANS = {'ALBUM_ART_TO_FILE', 'EXPORT_M3U8', 'M3U8_REL_PATHS', 'LYRICS_TO_METADATA',
            'LYRICS_TO_FILE', 'SKIP_EXISTING', 'ESCALATING_DELAY'}
DELAYS = {'FETCH_DELAY': (2, 0, 60), 'BULK_WAIT_TIME': (30, 0, 600),
          'RETRY_DELAY': (30, 1, 600), 'RETRY_ATTEMPTS': (3, 0, 10)}
FORMATS = {'copy', 'mp3', 'aac', 'opus'}
QUALITIES = {'auto', 'normal', 'high', 'very_high'}
BITRATES = {'best', 'auto', '96k', '128k', '160k', '192k', '256k', '320k'}


def validate_audio_options(format, quality, bitrate):
    for value, choices, label in [(format, FORMATS, 'audio format'),
                                   (quality, QUALITIES, 'source quality'),
                                   (bitrate, BITRATES, 'conversion bitrate')]:
        if not isinstance(value, str) or value not in choices:
            raise ValueError(f'Unsupported {label}')


class Settings:
    def __init__(self, config_dir):
        self.path = Path(config_dir) / 'config.json'

    def raw(self):
        return json.loads(self.path.read_text()) if self.path.is_file() else {}

    def public(self):
        values = self.raw()
        layout = next((k for k, v in LAYOUTS.items() if v == values.get('OUTPUT_ALBUM')), 'custom')
        return {'layout': layout, 'playlist_layout': 'separate' if '{playlist}' in values.get('OUTPUT_PLAYLIST_EXT', PLAYLIST) else 'library',
                'format': values.get('DOWNLOAD_FORMAT', 'copy'),
                'quality': values.get('DOWNLOAD_QUALITY', 'auto'),
                'bitrate': values.get('TRANSCODE_BITRATE', 'best'),
                'music_path': values.get('ROOT_PATH') or '~/Music/Spotified Music',
                'podcast_path': values.get('ROOT_PODCAST_PATH') or '~/Music/Spotified Podcasts',
                'templates': {key: values.get(key, LAYOUTS['albums']) for key in ('OUTPUT_SINGLE', 'OUTPUT_ALBUM', 'OUTPUT_PLAYLIST_EXT')},
                **{key: values.get(key, default) for key, (default, _, _) in DELAYS.items()},
                **{key: str(values.get(key, True)).lower() == 'true' for key in BOOLEANS}}

    def save(self, payload):
        allowed = {'layout', 'playlist_layout', 'format', 'quality', 'bitrate'} | BOOLEANS | DELAYS.keys()
        if not payload or set(payload) - allowed:
            raise ValueError('Unknown setting')
        values = self.raw()
        audio_keys = {'format': 'DOWNLOAD_FORMAT', 'quality': 'DOWNLOAD_QUALITY', 'bitrate': 'TRANSCODE_BITRATE'}
        if audio_keys.keys() & payload.keys():
            validate_audio_options(*(payload.get(key, values.get(config_key, {'format': 'copy', 'quality': 'auto', 'bitrate': 'best'}[key]))
                                     for key, config_key in audio_keys.items()))
        for key, value in payload.items():
            if key in BOOLEANS:
                if not isinstance(value, bool):
                    raise ValueError(f'{key} must be on or off')
                values[key] = value
            elif key in DELAYS:
                _, minimum, maximum = DELAYS[key]
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not minimum <= value <= maximum:
                    raise ValueError(f'{key} must be between {minimum} and {maximum}')
                if key == 'RETRY_ATTEMPTS' and int(value) != value:
                    raise ValueError('Retry attempts must be a whole number')
                values[key] = int(value) if key == 'RETRY_ATTEMPTS' else value
            elif key in audio_keys:
                values[audio_keys[key]] = value
            elif key == 'layout':
                if value not in {*LAYOUTS, 'custom'}:
                    raise ValueError('Unknown folder layout')
                if value != 'custom':
                    values['OUTPUT_SINGLE'] = values['OUTPUT_ALBUM'] = LAYOUTS[value]
            elif value not in {'separate', 'library'}:
                raise ValueError('Unknown playlist layout')
        if 'playlist_layout' in payload or ('layout' in payload and '{playlist}' not in values.get('OUTPUT_PLAYLIST_EXT', PLAYLIST)):
            mode = payload.get('playlist_layout', 'library')
            values['OUTPUT_PLAYLIST_EXT'] = PLAYLIST if mode == 'separate' else values.get('OUTPUT_ALBUM', LAYOUTS['albums'])
        temporary = self.path.with_suffix('.tmp')
        temporary.write_text(json.dumps(values, indent=2), encoding='utf-8')
        temporary.chmod(0o600)
        temporary.replace(self.path)
        return self.public()
