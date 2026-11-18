"""Local setup checks. Never authenticate or read credential contents."""

import shutil
import subprocess
import sys
from pathlib import Path

from spotified.config import Config, Spotified


def doctor(args) -> int:
    """Print actionable diagnostics and return nonzero for missing prerequisites."""
    print(f'Spotified {Spotified.VERSION} | Python {sys.version.split()[0]}')
    path = Config.config_path(args.config_location)
    print(f'Config: {path} ({"present" if path.is_file() else "using defaults; file not created"})')
    print(f'Music: {Path(Config.get("ROOT_PATH")).expanduser()}')
    print(f'Podcasts: {Config.get("ROOT_PODCAST_PATH")}')
    print(f'Format: {Config.get_download_format()} | Quality: {Config.get_download_qual_pref()}')
    missing = False
    for name in ('ffmpeg', 'ffprobe'):
        executable = shutil.which(name)
        if not executable:
            print(f'MISSING: {name}. Install FFmpeg and add it to PATH.')
            missing = True
            continue
        try:
            result = subprocess.run([executable, '-version'], capture_output=True, text=True,
                                    timeout=10, check=True)
            print(f'OK: {result.stdout.splitlines()[0]} ({executable})')
        except (OSError, subprocess.SubprocessError, IndexError) as exc:
            print(f'FAILED: {name}: {exc}')
            missing = True
    print('Client API: configured (access not tested)' if Config.permit_client_api() else
          'Client API: not configured. Search, liked songs and saved libraries need --client-id.')
    print('Offline checks only; login and service availability were not tested.')
    return 1 if missing else 0
