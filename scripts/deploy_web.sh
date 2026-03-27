#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp/garphoenix-web}"
REMOTE_WEB_ROOT="${REMOTE_WEB_ROOT:-/var/www/garphoenix.com}"
BUILD_ARGS="${BUILD_ARGS:---release --no-wasm-dry-run}"
RUN_HEALTH_CHECK="${RUN_HEALTH_CHECK:-1}"
HEALTH_DOMAIN="${HEALTH_DOMAIN:-garphoenix.com}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
USE_SSHPASS="0"
if [[ -n "${SSH_PASSWORD:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "[deploy_web] SSH_PASSWORD is set, but sshpass is not installed."
    echo "[deploy_web] Install on macOS: brew install hudochenkov/sshpass/sshpass"
    exit 1
  fi
  USE_SSHPASS="1"
  SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
fi

run_ssh() {
  if [[ "$USE_SSHPASS" == "1" ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

run_rsync() {
  if [[ "$USE_SSHPASS" == "1" ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e rsync -e "ssh ${SSH_OPTS[*]}" "$@"
  else
    rsync -e "ssh ${SSH_OPTS[*]}" "$@"
  fi
}

echo "[deploy_web] project: $PROJECT_ROOT"
echo "[deploy_web] server:  $SERVER"
echo "[deploy_web] web root: $REMOTE_WEB_ROOT"

strip_web_debug_artifacts() {
  find "$PROJECT_ROOT/build/web" -name '.DS_Store' -delete || true
  rm -f "$PROJECT_ROOT/build/web/.last_build_id" || true
  for file in \
    "$PROJECT_ROOT/build/web/flutter.js" \
    "$PROJECT_ROOT/build/web/flutter_bootstrap.js"
  do
    [[ -f "$file" ]] || continue
    perl -0pi -e 's/[[:space:]]*\/\/# sourceMappingURL=flutter\.js\.map//g; s/[[:space:]]*sourceMappingURL=flutter\.js\.map# sourceMappingURL=flutter\.js\.map//g' "$file" || true
    rm -f "$file.bak"
  done
}

normalize_web_build_permissions() {
  [[ -d "$PROJECT_ROOT/build/web" ]] || return 0
  find "$PROJECT_ROOT/build/web" -type d -exec chmod 755 {} +
  find "$PROJECT_ROOT/build/web" -type f -exec chmod 644 {} +
}

install_custom_service_worker() {
  local source="$PROJECT_ROOT/web/push_service_worker.js"
  local target="$PROJECT_ROOT/build/web/flutter_service_worker.js"
  [[ -f "$source" ]] || return 0
  [[ -d "$PROJECT_ROOT/build/web" ]] || return 0
  cp "$source" "$target"
  chmod 644 "$target"
}

cd "$PROJECT_ROOT"

if [[ "${1:-}" != "--skip-build" ]]; then
  echo "[deploy_web] building flutter web..."
  rm -rf "$PROJECT_ROOT/.dart_tool/flutter_build" "$PROJECT_ROOT/build/web"
  flutter build web $BUILD_ARGS
else
  echo "[deploy_web] skip build requested"
fi

strip_web_debug_artifacts
install_custom_service_worker
normalize_web_build_permissions

echo "[deploy_web] uploading build/web to server tmp..."
run_rsync -avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r --exclude='.DS_Store' --exclude='.last_build_id' \
  "$PROJECT_ROOT/build/web/" "$SERVER:$REMOTE_TMP_DIR/"

echo "[deploy_web] applying build on server..."
run_ssh "$SERVER" "
  set -euo pipefail
  mkdir -p '$REMOTE_WEB_ROOT'
  rsync -av --delete '$REMOTE_TMP_DIR/' '$REMOTE_WEB_ROOT/'
  find '$REMOTE_WEB_ROOT' -name '.DS_Store' -delete || true
  rm -f '$REMOTE_WEB_ROOT/.last_build_id' || true
  chown -R www-data:www-data '$REMOTE_WEB_ROOT'
  nginx -t
  systemctl reload nginx
"

echo "[deploy_web] done"
if [[ "$RUN_HEALTH_CHECK" == "1" ]]; then
  echo "[deploy_web] running production health check for $HEALTH_DOMAIN"
  bash "$SCRIPT_DIR/prod_health_check.sh" "$HEALTH_DOMAIN"
else
  echo "[deploy_web] RUN_HEALTH_CHECK=0, skip production health check"
fi
