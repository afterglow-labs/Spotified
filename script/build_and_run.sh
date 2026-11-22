#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---verify}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Spotified.app"
export PATH="/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
cd "$ROOT_DIR/frontend"
node /opt/homebrew/opt/node@22/lib/node_modules/npm/bin/npm-cli.js run build
cd "$ROOT_DIR"
swift build --package-path macos -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp macos/.build/release/Spotified "$APP/Contents/MacOS/Spotified"
if [ -f macos/Spotified.icns ]; then cp macos/Spotified.icns "$APP/Contents/Resources/Spotified.icns"; fi
SPOTIFIED_ROOT="$ROOT_DIR" .venv/bin/python - <<'PY'
import os, plistlib
from pathlib import Path
root = Path(os.environ['SPOTIFIED_ROOT'])
values = dict(CFBundleName='Spotified', CFBundleDisplayName='Spotified',
              CFBundleIdentifier='com.afterglowlabs.spotified', CFBundleVersion='9',
              CFBundleShortVersionString='0.6.0', CFBundleExecutable='Spotified',
              CFBundlePackageType='APPL', NSPrincipalClass='NSApplication',
              LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True,
              CFBundleIconFile='Spotified', NSHumanReadableCopyright='Afterglow Labs',
              NSAppTransportSecurity={'NSAllowsLocalNetworking': True},
              SpotifiedStartScript=str(root / 'script/start_server.sh'))
(root / 'dist/Spotified.app/Contents/Info.plist').write_bytes(plistlib.dumps(values))
PY
codesign --force --deep --sign - --identifier com.afterglowlabs.spotified "$APP"
if [ "$MODE" = '--build-only' ]; then exit 0; fi
if ! docker info >/dev/null 2>&1; then
  colima start --cpus 4 --memory 4 --disk 12 --root-disk 8 --vm-type vz --runtime docker
fi
docker compose build
docker compose up -d --no-build
if [ -e /Applications/Spotified.app ]; then
  INSTALLED_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Spotified.app/Contents/Info.plist)
  [ "$INSTALLED_ID" = com.afterglowlabs.spotified ] || { echo 'An unrelated Spotified.app is already installed.' >&2; exit 1; }
fi
pkill -x Spotified >/dev/null 2>&1 || true
ditto "$APP" /Applications/Spotified.app
if [ "$MODE" = '--install-only' ]; then exit 0; fi
/usr/bin/open /Applications/Spotified.app
case "$MODE" in
  --verify) sleep 2; pgrep -x Spotified >/dev/null; echo 'Spotified launched.' ;;
  --logs|--telemetry) /usr/bin/log stream --level info --predicate 'process == "Spotified"' ;;
  --debug) lldb -n Spotified ;;
  run) ;;
  *) echo 'Usage: script/build_and_run.sh [run|--verify|--build-only|--install-only|--logs|--debug|--telemetry]' >&2; exit 2 ;;
esac
