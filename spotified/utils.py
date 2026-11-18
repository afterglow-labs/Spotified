import re
from datetime import datetime, timezone
from fractions import Fraction
from os.path import commonpath, relpath
from pathlib import Path, PurePath
from shutil import move, copyfile, copyfileobj

from spotified.termoutput import *


# Path Utils
def ensure_real_file(dir_or_file: PurePath, def_filename: str) -> PurePath:
    dir_or_file = Path(dir_or_file)
    if   dir_or_file.is_file(): file = dir_or_file
    elif dir_or_file.is_dir():  file = dir_or_file / def_filename
    elif dir_or_file.suffix:    file = dir_or_file
    else:                       file = dir_or_file / def_filename
    file.parent.mkdir(parents=True, exist_ok=True)
    file.touch()
    return PurePath(file)


def file_has_content(path: str | PurePath) -> None | bool:
    "returns None if file does not exist, False if file is empty, and True if file has content"
    path = Path(path)
    if not path.is_file():          return None
    elif not path.stat().st_size:   return False
    else:                           return True


def pathlike_move_safe(src, dst: PurePath, copy: bool = False) -> PurePath:
    Path(dst.parent).mkdir(parents=True, exist_ok=True)
    if isinstance(src, bytes):
        Path(dst).write_bytes(src)
    elif hasattr(src, "read"):
        with Path(dst).open("wb") as file:
            copyfileobj(src, file)
    elif copy:  copyfile(src, dst)
    else:       move(src, dst)
    return dst


def try_rel_path(path: PurePath | None, start: PurePath) -> PurePath | None:
    if not path: return None
    try: return PurePath(relpath(path, start))
    except ValueError: return path


def check_path_dupes(path: PurePath) -> PurePath:
    if not file_has_content(path): return path
    index = 1
    while file_has_content(path.with_stem(f"{path.stem}_{index}")): index += 1
    return path.with_stem(f"{path.stem}_{index}") # guaranteed to be unique


def get_common_dir(allpaths: set[PurePath]) -> PurePath:
    return PurePath(commonpath([p.parent for p in allpaths]))


def walk_directory_for_tracks(root_path: PurePath):
    Path(root_path).mkdir(parents=True, exist_ok=True)
    for filepath in Path(root_path).rglob("*"):
        if filepath.is_file() and filepath.suffix and filepath.suffix[1:] in EXT_MAP.values():
            yield PurePath(filepath)


# Input Processing Utils
def safe_typecast(d: dict, k: str, to_cast: type, default = None, except_channel: PrintChannel = PrintChannel.WARNING):
    raw_val = d.get(k, default)
    if raw_val is None:
        return None
    elif to_cast is bool:
        if str(raw_val).strip().lower() in {"0", "no", "false", "off"}:
            return False
        if str(raw_val).strip().lower() in {"1", "yes", "true", "on"}:
            return True
        raise ValueError(f'{k} must be a boolean (true/false, yes/no, on/off, or 1/0)')
    elif isinstance(raw_val, to_cast):
        return raw_val
    elif to_cast is float and isinstance(raw_val, str) and "/" in raw_val:
        return float(Fraction(''.join(raw_val.split())))
    try:
        return to_cast(raw_val)
    except Exception:
        Printer.hashtaged(except_channel, f'COULD NOT CAST VALUE OF KEY "{k}" TO TYPE {str(to_cast).upper()}')
        raise


def strlist_compressor(strs: list[str]) -> str:
    res = []
    for s in strs:
        res.extend(s.split())
    return " ".join(res)


def edge_zip(sorted_list: list) -> list:
    """ Performs sort in place: [1,2,3,4,5] -> [1,5,2,4,3] (Assumes list is ascending) """
    n = len(sorted_list)
    sorted_list[::2], sorted_list[1::2] = sorted_list[:(n+1)//2], sorted_list[:(n+1)//2-1:-1]
    return sorted_list


def arg_comb(*args: str):
    return "&" + "&".join(args) if args else ""


def clamp(low: int, i: int, high: int) -> int:
    return max(low, min(i, high))


def pct_error(act: float | int, expct: float | int) -> float:
    act = float(act); expct = float(expct)
    return abs(act - expct) / expct


def select(items: list, inline_prompt: str = 'ID(s): ', first_ID: int = 1, only_one: bool = False) -> list:
    if not items:
        return []
    Printer.user_make_select_prompt(only_one)
    while True:
        selection = Printer.get_input(inline_prompt).strip()
        indices = set()
        try:
            for part in selection.split(','):
                match = re.fullmatch(r"\s*([0-9]+)(?:\s*-\s*([0-9]+))?\s*", part)
                if not match:
                    raise ValueError
                start = int(match[1])
                end = int(match[2]) if match[2] is not None else start
                if not first_ID <= start <= end < first_ID + len(items):
                    raise ValueError
                indices.update(range(start, end + 1))
            if only_one and len(indices) != 1:
                raise ValueError
        except ValueError:
            Printer.hashtaged(PrintChannel.MANDATORY, 'INVALID SELECTION')
            continue
        return [items[i-first_ID] for i in sorted(indices)]


# Time Utils
def fmt_duration(duration: float | int, unit_conv: tuple[int, int] = (60, 60), connectors: tuple[str, str] = (":", ":"), smallest_unit: str = "s", ALWAYS_ALL_UNITS: bool = False) -> str:
    """ Formats a duration to a time string, defaulting to seconds -> hh:mm:ss format """
    duration_secs = int(duration // 1)
    duration_mins = duration_secs // unit_conv[1]
    s = duration_secs % unit_conv[1]
    m = duration_mins % unit_conv[0]
    h = duration_mins // unit_conv[0]
    
    if ALWAYS_ALL_UNITS:
        return f'{h}'.zfill(2) + connectors[0] + f'{m}'.zfill(2) + connectors[1] + f'{s}'.zfill(2)
    
    if not any((h, m, s)):
        return "0" + smallest_unit
    
    if h == 0 and m == 0:
        return f'{s}' + smallest_unit
    elif h == 0:
        return f'{m}'.zfill(2) + connectors[1] + f'{s}'.zfill(2)
    else:
        return f'{h}'.zfill(2) + connectors[0] + f'{m}'.zfill(2) + connectors[1] + f'{s}'.zfill(2)


def dt_to_str(dt: datetime) -> str:
    return dt.strftime(r'%Y-%m-%d %H:%M:%S')


def now() -> str:
    return dt_to_str(datetime.now())


def timestamp_utc(timestamp_ms: str | None) -> str | None:
    if not timestamp_ms: return None
    dt = datetime.fromtimestamp(int(timestamp_ms) / 1000, tz=timezone.utc)
    return dt_to_str(dt)


def strptime_utc(dtstr: str) -> datetime:
    return datetime.strptime(dtstr[:-1], r'%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
