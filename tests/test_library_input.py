from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from spotified.api import Track, Album, Artist, Query, ParentStack
from spotified.app import filter_search_query
from spotified.config import Config
from spotified.metadata import SongArchive, regularize_libre_md
from spotified.termoutput import Printer
from spotified.utils import select, get_common_dir, pathlike_move_safe


@pytest.mark.parametrize('bad', ['999', '-1', '1-', '1-2-3', '1,', '3-1', 'a1', '1-999999999', ''])
def test_selection_reprompts_without_crashing(monkeypatch, bad):
    monkeypatch.setattr(Printer, 'get_input', Mock(side_effect=[bad, '1,2-3,2']))
    assert select(['a', 'b', 'c']) == ['a', 'b', 'c']


def test_single_selection_and_zero_index(monkeypatch):
    monkeypatch.setattr(Printer, 'get_input', Mock(side_effect=['0,1', '0']))
    assert select([None, 'mode'], first_ID=0, only_one=True) == [None]


def test_search_combined_filters_and_last_value_wins():
    params = filter_search_query('AC/DC /s 20 /t album,track /o 3 /s 5 /ie true', ('track', 'album', 'artist', 'playlist'))
    assert params == {'q': 'AC/DC', 'SEARCH_QUERY_SIZE': 5, 'type': 'album,track', 'offset': 3, 'include_external': 'audio'}


@pytest.mark.parametrize('query', ['music /t bad', 'music /s lots', 'music /o', 'music /ie flase'])
def test_invalid_search_filter_has_useful_error(query):
    with pytest.raises(ValueError):
        filter_search_query(query, ('track', 'album'))


def test_plain_search_omits_external_false():
    assert 'include_external' not in filter_search_query('music', ('track', 'album'))


def test_common_dir_uses_parents_without_mutating_input(tmp_path):
    paths = {tmp_path / 'one/song.ogg', tmp_path / 'two/song.ogg'}
    assert get_common_dir(paths) == tmp_path
    assert len(paths) == 2


def test_pathlike_copy_accepts_bytes_and_streams(tmp_path):
    from io import BytesIO
    path = tmp_path / 'bytes'
    pathlike_move_safe(b'audio', path)
    assert path.read_bytes() == b'audio'
    pathlike_move_safe(BytesIO(b'stream'), path)
    assert path.read_bytes() == b'stream'


def test_archive_ignores_stale_entries_and_keeps_multiple_writes(tmp_path):
    archive = SongArchive()
    track = Track('track:test')
    track.name = 'Title\nwith\ttabs'
    missing = tmp_path / 'missing.ogg'
    empty = tmp_path / 'empty.ogg'
    empty.touch()
    live = tmp_path / 'live.ogg'
    live.write_bytes(b'audio')
    archive.add_obj(track, missing)
    archive.add_obj(track, live)
    archive.add_obj(track, empty)
    assert len(archive.ids()) == 3
    assert archive.obj_in_archive(track) == live
    live.unlink()
    assert archive.obj_in_archive(track) is None


def test_empty_album_and_missing_metadata():
    album = Album('album:empty')
    album._update_child_based_metadata()
    assert album.total_discs == 0
    assert album.duration_ms == 0
    Track('track:missing').parse_metadata(None, None)


def test_album_regularization_retains_type():
    resp = {'type': 'COMPILATION', 'name': 'Collection'}
    regularize_libre_md(Album, resp, 'album:id')
    assert resp['type'] == 'album'
    assert resp['album_type'] == 'compilation'


def test_personal_album_template_sanitizes_metadata():
    artist = Artist('artist:test')
    artist.name = 'A/B'
    album = Album('album:test')
    album.name = 'Album: One'
    album.artists = [artist]
    track = Track('track:test')
    track.name = 'Song?'
    track.track_number, track.disc_number, track.album = 3, 2, album
    path = track.fill_output_template(ParentStack([Query('test'), album, track]),
        '{album_artist}/{album}/{disc_number}-{track_number} - {song_name}')
    assert str(path).endswith('A_B/Album_ One/02-03 - Song_.ogg')


def test_finishing_only_progress_bar_does_not_underflow():
    bar = Mock(n=1, total=1, disable=False)
    stack = [bar]
    Printer.ACTIVE_PBARS = [bar]
    Printer.refresh_all_pbars(stack)
    assert stack == Printer.ACTIVE_PBARS == []


def test_album_with_unavailable_children():
    album = Album('album:partial')
    album._main_items.extend([None])
    assert not album.needs_recursion()
    album.mark_downloaded()
    assert album._downloaded


def test_parent_album_destinations_stay_with_their_own_tracks(monkeypatch):
    Config.Values['DOWNLOAD_PARENT_ALBUM'] = True
    Config.Values['TEST_MODE'] = True
    monkeypatch.setattr(ParentStack, 'check_skippable', lambda self: False)
    query = Query('test')
    tracks = [Track('track:first'), Track('track:second')]
    for index, track in enumerate(tracks):
        track.album = Album(f'album:{index}')
        track.duration_ms = 1000 + index
    query.requested_objs = [tracks]
    query.download()
    for track in tracks:
        assert all(stack[-1] is track for stack in track._clone_to)
    assert {stack[-1] for stack in query._main_items} == set(tracks)
