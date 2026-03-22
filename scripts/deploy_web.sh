#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp/garphoenix-web}"
REMOTE_WEB_ROOT="${REMOTE_WEB_ROOT:-/var/www/garphoenix.com}"
BUILD_ARGS="${BUILD_ARGS:---release --no-wasm-dry-run}"

echo "[deploy_web] project: $PROJECT_ROOT"
echo "[deploy_web] server:  $SERVER"
echo "[deploy_web] web root: $REMOTE_WEB_ROOT"

cd "$PROJECT_ROOT"

if [[ "${1:-}" != "--skip-build" ]]; then
  echo "[deploy_web] building flutter web..."
  flutter build web $BUILD_ARGS
else
  echo "[deploy_web] skip build requested"
fi

echo "[deploy_web] uploading build/web to server tmp..."
rsync -avz --delete "$PROJECT_ROOT/build/web/" "$SERVER:$REMOTE_TMP_DIR/"

echo "[deploy_web] applying build on server..."
ssh "$SERVER" "
  set -euo pipefail
  mkdir -p '$REMOTE_WEB_ROOT'
  rsync -av --delete '$REMOTE_TMP_DIR/' '$REMOTE_WEB_ROOT/'
  chown -R www-data:www-data '$REMOTE_WEB_ROOT'
  nginx -t
  systemctl reload nginx
"

echo "[deploy_web] done"
echo "[deploy_web] verify:"
echo "  curl -s https://garphoenix.com/health"
echo "  curl -sI https://garphoenix.com | tr -d '\r' | grep -i '^content-security-policy:'"
