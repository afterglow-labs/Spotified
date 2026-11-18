"""Keep offline tests isolated from real credentials and music libraries."""
from argparse import Namespace
from tempfile import TemporaryDirectory
from pathlib import Path

import pytest

from spotified.config import Config, Spotified

_BOOTSTRAP = TemporaryDirectory(prefix='spotified-tests-')
_ARGS = dict(config_location=str(Path(_BOOTSTRAP.name) / 'config.json'),
             debug=False, test_mode=False, update_config=False,
             update_archive=False, verify_library=False)
Config.load(Namespace(**_ARGS, root_path=_BOOTSTRAP.name,
                      root_podcast_path=_BOOTSTRAP.name), create=False)

from spotified.api import Content, Episode, HierarchicalNode
from spotified.metadata import SongArchive
from spotified.termoutput import Printer


@pytest.fixture(autouse=True)
def isolated_config(tmp_path, monkeypatch):
    args = Namespace(**(_ARGS | {'config_location': str(tmp_path / 'config.json')}),
                     root_path=str(tmp_path / 'music'), root_podcast_path=str(tmp_path / 'podcasts'),
                     song_archive_location=str(tmp_path / '.song_archive'),
                     standard_interface=False, print_progress_info=False, print_download_progress=False)
    Config.load(args, create=False)
    monkeypatch.setattr(Content, '_path_root', Path(Config.get('ROOT_PATH')))
    monkeypatch.setattr(Episode, '_path_root', Path(Config.get('ROOT_PODCAST_PATH')))
    monkeypatch.setattr(HierarchicalNode, 'ALL_NODES', {})
    monkeypatch.setattr(Spotified, 'TEMP_FILES', set())
    monkeypatch.setattr(Spotified, 'TOTAL_API_CALLS', 0)
    monkeypatch.setattr(Printer, 'ACTIVE_PBARS', [])
    monkeypatch.setattr(SongArchive, 'UPDATE_GLOBAL', False)
    return args
