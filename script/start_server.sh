#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if curl --fail --silent --max-time 2 http://127.0.0.1:8088/api/health | /usr/bin/grep -q '"service": "spotified"'; then
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  colima start --cpus 4 --memory 4 --disk 12 --root-disk 8 --vm-type vz --runtime docker
fi
if ! docker image inspect spotified:local >/dev/null 2>&1; then
  echo 'Build the server first with docker compose build.' >&2
  exit 1
fi
docker compose up -d --no-build
