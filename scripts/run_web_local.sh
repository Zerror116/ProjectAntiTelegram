#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE_URL="${FENIX_API_BASE_URL:-http://127.0.0.1:3001}"
WEB_PORT="${WEB_PORT:-7357}"
DEVICE="${FLUTTER_WEB_DEVICE:-chrome}"

cd "$ROOT_DIR"

echo "[run_web_local] device=$DEVICE web_port=$WEB_PORT api=$API_BASE_URL"
exec flutter run \
  -d "$DEVICE" \
  --web-port "$WEB_PORT" \
  --debug \
  --dart-define=FENIX_API_BASE_URL="$API_BASE_URL" \
  "$@"
