import json
import subprocess
import sys
from pathlib import Path

import pytest

from spotified.config import Config, Spotified
from spotified.utils import safe_typecast


@pytest.mark.parametrize('value,expected', [('False', False), (' off ', False), (True, True),
                                            ('yes', True), ('1', True), (0, False)])
def test_boolean_values(value, expected):
    assert safe_typecast({'flag': value}, 'flag', bool) is expected


def test_invalid_boolean():
    with pytest.raises(ValueError, match='flag'):
        safe_typecast({'flag': 'flase'}, 'flag', bool)


@pytest.mark.parametrize('key,value', [('CHUNK_SIZE', 0), ('RETRY_ATTEMPTS', -1),
    ('FETCH_TIMEOUT', 'nan'), ('BULK_WAIT_TIME', 'inf'), ('REDIRECT_PORT', 65536),
    ('DOWNLOAD_FORMAT', 'nonsense'), ('SKIP_EXISTING', 'flase'), ('ROOT_PATH', None)])
def test_bad_config_rejected_before_writes(isolated_config, key, value):
    path = Path(isolated_config.config_location)
    original = json.dumps({key: value})
    path.write_text(original)
    isolated_config.update_config = True
    with pytest.raises((ValueError, TypeError)):
        Config.load(isolated_config)
    assert path.read_text() == original


def test_temporary_config_restored_after_error():
    before = Config.get_download_parent_album()
    with pytest.raises(RuntimeError):
        with Config.temporary_config('DOWNLOAD_PARENT_ALBUM', not before):
            assert Config.get_download_parent_album() is not before
            raise RuntimeError
    assert Config.get_download_parent_album() is before


def test_load_drops_previous_state(isolated_config):
    Config.Values['UPDATE_ARCHIVE'] = True
    Config.Values['stale'] = True
    Config.load(isolated_config, create=False)
    assert Config.get('UPDATE_ARCHIVE') is None
    assert Config.get('stale') is None


def test_ffmpeg_quotes_preserved():
    Config.Values['CUSTOM_FFMEPG_ARGS'] = '-af "volume=0.5:enable=between(t,0,30)" -metadata "title=A song"'
    assert Config.get_custom_ffmpeg_args() == ['-af', 'volume=0.5:enable=between(t,0,30)', '-metadata', 'title=A song']


def test_custom_api_enabled_only_when_configured():
    assert not Config.permit_client_api()
    Config.Values['API_CLIENT_ID'] = 'example-client'
    assert Config.permit_client_api()


def cli(*args):
    return subprocess.run([sys.executable, '-m', 'spotified', *args], capture_output=True, text=True, timeout=20)


def test_update_config_is_offline_and_preserves_settings(tmp_path):
    path = tmp_path / 'settings.json'
    path.write_text('{"BULK_WAIT_TIME": 7}')
    result = cli('-c', str(path), '--update-config')
    assert result.returncode == 0, result.stderr
    assert json.loads(path.read_text())['BULK_WAIT_TIME'] == 7
    assert 'Logging in' not in result.stdout
    assert list(tmp_path.iterdir()) == [path]


def test_doctor_does_not_create_files_or_login(tmp_path, monkeypatch):
    monkeypatch.setenv('PATH', '')
    path = tmp_path / 'new' / 'config.json'
    result = cli('--doctor', '-c', str(path))
    assert result.returncode == 1
    assert 'MISSING: ffmpeg' in result.stdout
    assert 'MISSING: ffprobe' in result.stdout
    assert 'Logging in' not in result.stdout
    assert not path.parent.exists()


def test_cli_bad_config_is_concise(tmp_path):
    result = cli('--doctor', '-c', str(tmp_path / 'config.json'), '--chunk-size', '0')
    assert result.returncode == 2
    assert 'CHUNK_SIZE' in result.stderr
    assert 'Traceback' not in result.stderr


def test_personal_preset_loads(isolated_config):
    isolated_config.config_location = str(Path(__file__).parents[1] / 'profiles/corey.json')
    Config.load(isolated_config, create=False)
    assert Config.get_export_m3u8()
    assert Config.get_download_format() == 'copy'
    assert Config.get_retry_attempts() == 3


def test_invalid_regex_does_not_overwrite_config(isolated_config):
    path = Path(isolated_config.config_location)
    original = '{"REGEX_ENABLED": true, "REGEX_TRACK_SKIP": "["}'
    path.write_text(original)
    isolated_config.update_config = True
    with pytest.raises(ValueError, match='REGEX_TRACK_SKIP'):
        Config.load(isolated_config)
    assert path.read_text() == original
