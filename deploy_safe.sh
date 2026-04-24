#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/opt/fenix}"
REMOTE_WEB_ROOT="${REMOTE_WEB_ROOT:-/var/www/garphoenix.com}"
REMOTE_TMP_WEB_DIR="${REMOTE_TMP_WEB_DIR:-/tmp/garphoenix-web-safe}"
HEALTH_DOMAIN="${HEALTH_DOMAIN:-garphoenix.com}"
RUN_ANALYZE="${RUN_ANALYZE:-1}"
RUN_TESTS="${RUN_TESTS:-0}"
RUN_HEALTH_CHECK="${RUN_HEALTH_CHECK:-1}"
RUN_BACKUP_BEFORE_DEPLOY="${RUN_BACKUP_BEFORE_DEPLOY:-1}"
BUILD_ARGS="${BUILD_ARGS:---release --no-wasm-dry-run}"
SKIP_BUILD="0"
SKIP_BACKEND="0"
SKIP_WEB="0"

CONTROL_SOCKET="/tmp/phoenix-safe-deploy-$(id -u)-$(echo "$SERVER" | tr '@/:' '_').sock"
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="$CONTROL_SOCKET"
)
USE_SSHPASS="0"

usage() {
  cat <<'USAGE'
Usage:
  ./deploy_safe.sh [--skip-build] [--skip-backend] [--skip-web] [--no-health-check]

What it does:
  1) flutter pub get
  2) flutter analyze (optional)
  3) flutter test (optional)
  4) flutter build web
  5) safe backend sync (excludes uploads/downloads/.env/node_modules)
  6) upload build/web and reload nginx
  7) production health-check

Important env vars:
  SERVER=root@89.23.99.18
  SSH_PASSWORD=...                   # optional, requires sshpass
  REMOTE_PROJECT_DIR=/opt/fenix
  REMOTE_WEB_ROOT=/var/www/garphoenix.com
  HEALTH_DOMAIN=garphoenix.com
  RUN_ANALYZE=1
  RUN_TESTS=0
  RUN_HEALTH_CHECK=1
  RUN_BACKUP_BEFORE_DEPLOY=1
  BUILD_ARGS='--release --no-wasm-dry-run'

Examples:
  ./deploy_safe.sh
  SSH_PASSWORD='***' ./deploy_safe.sh
  RUN_ANALYZE=0 RUN_TESTS=1 ./deploy_safe.sh
  ./deploy_safe.sh --skip-build --skip-backend
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD="1"
      ;;
    --skip-backend)
      SKIP_BACKEND="1"
      ;;
    --skip-web)
      SKIP_WEB="1"
      ;;
    --no-health-check)
      RUN_HEALTH_CHECK="0"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

cleanup_control_socket() {
  ssh -S "$CONTROL_SOCKET" -O exit "$SERVER" >/dev/null 2>&1 || true
  rm -f "$CONTROL_SOCKET" >/dev/null 2>&1 || true
}
trap cleanup_control_socket EXIT

if [[ -n "${SSH_PASSWORD:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "[deploy_safe] SSH_PASSWORD is set, but sshpass is not installed." >&2
    echo "[deploy_safe] On macOS: brew install hudochenkov/sshpass/sshpass" >&2
    exit 1
  fi
  USE_SSHPASS="1"
  SSH_OPTS+=( -o PreferredAuthentications=password -o PubkeyAuthentication=no )
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

echo "[deploy_safe] project: $PROJECT_ROOT"
echo "[deploy_safe] server:  $SERVER"
echo "[deploy_safe] remote project: $REMOTE_PROJECT_DIR"
echo "[deploy_safe] remote web root: $REMOTE_WEB_ROOT"

cd "$PROJECT_ROOT"

echo "[deploy_safe] checking remote storage configuration"
run_ssh "$SERVER" "grep -q '^APP_STORAGE_ROOT=/opt/fenix-data$' '$REMOTE_PROJECT_DIR/server/.env'"

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "[deploy_safe] flutter pub get"
  flutter pub get

  if [[ "$RUN_ANALYZE" == "1" ]]; then
    echo "[deploy_safe] flutter analyze"
    flutter analyze
  else
    echo "[deploy_safe] RUN_ANALYZE=0, skip analyze"
  fi

  if [[ "$RUN_TESTS" == "1" ]]; then
    echo "[deploy_safe] flutter test"
    flutter test
  else
    echo "[deploy_safe] RUN_TESTS=0, skip tests"
  fi

  if [[ "$SKIP_WEB" != "1" ]]; then
    echo "[deploy_safe] flutter build web $BUILD_ARGS"
    rm -rf "$PROJECT_ROOT/.dart_tool/flutter_build" "$PROJECT_ROOT/build/web"
    flutter build web $BUILD_ARGS
    strip_web_debug_artifacts
    install_custom_service_worker
    normalize_web_build_permissions
  fi
else
  echo "[deploy_safe] --skip-build: skip flutter build/analyze/tests"
fi

if [[ "$SKIP_BACKEND" != "1" ]]; then
  if [[ "$RUN_BACKUP_BEFORE_DEPLOY" == "1" ]]; then
    echo "[deploy_safe] running remote pre-deploy backup"
    run_ssh "$SERVER" "if [[ -x '$REMOTE_PROJECT_DIR/server/scripts/nightly_backup.sh' ]]; then '$REMOTE_PROJECT_DIR/server/scripts/nightly_backup.sh'; fi"
  else
    echo "[deploy_safe] RUN_BACKUP_BEFORE_DEPLOY=0, skip pre-deploy backup"
  fi

  echo "[deploy_safe] syncing backend code safely"
  SERVER="$SERVER" REMOTE_PROJECT_DIR="$REMOTE_PROJECT_DIR" SSH_PASSWORD="${SSH_PASSWORD:-}" DEPLOY_CONTROL_SOCKET="$CONTROL_SOCKET" \
    "$SCRIPTS_DIR/sync_server_code_safe.sh"

  echo "[deploy_safe] installing remote systemd units"
  run_ssh "$SERVER" "\
    set -e; \
    install -m 644 '$REMOTE_PROJECT_DIR/server/deploy/systemd/fenix-worker.service' /etc/systemd/system/fenix-worker.service; \
    install -m 644 '$REMOTE_PROJECT_DIR/server/deploy/systemd/fenix-nightly-backup.service' /etc/systemd/system/fenix-nightly-backup.service; \
    install -m 644 '$REMOTE_PROJECT_DIR/server/deploy/systemd/fenix-nightly-backup.timer' /etc/systemd/system/fenix-nightly-backup.timer; \
    install -m 644 '$REMOTE_PROJECT_DIR/server/deploy/systemd/fenix-nightly-maintenance.service' /etc/systemd/system/fenix-nightly-maintenance.service; \
    install -m 644 '$REMOTE_PROJECT_DIR/server/deploy/systemd/fenix-nightly-maintenance.timer' /etc/systemd/system/fenix-nightly-maintenance.timer; \
    mkdir -p /opt/fenix-backups/postgres /opt/fenix-backups/storage; \
    systemctl daemon-reload; \
    systemctl enable --now fenix-worker.service; \
    systemctl enable --now fenix-nightly-backup.timer; \
    systemctl enable --now fenix-nightly-maintenance.timer; \
    systemctl restart fenix-worker.service; \
    systemctl is-active fenix-server.service; \
    systemctl is-active fenix-worker.service\
  "
else
  echo "[deploy_safe] --skip-backend: skip backend sync"
fi

if [[ "$SKIP_WEB" != "1" ]]; then
  echo "[deploy_safe] uploading build/web -> $SERVER:$REMOTE_TMP_WEB_DIR"
  run_ssh "$SERVER" "mkdir -p '$REMOTE_TMP_WEB_DIR' '$REMOTE_WEB_ROOT' '$REMOTE_PROJECT_DIR/build/web'"
  run_rsync -avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    --exclude='.DS_Store' \
    --exclude='.last_build_id' \
    "$PROJECT_ROOT/build/web/" "$SERVER:$REMOTE_TMP_WEB_DIR/"
  run_rsync -avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    --exclude='.DS_Store' \
    --exclude='.last_build_id' \
    "$PROJECT_ROOT/build/web/" "$SERVER:$REMOTE_PROJECT_DIR/build/web/"

  echo "[deploy_safe] applying web build on server"
  run_ssh "$SERVER" "\
    set -e; \
    rsync -av --delete '$REMOTE_TMP_WEB_DIR/' '$REMOTE_WEB_ROOT/'; \
    find '$REMOTE_WEB_ROOT' -name '.DS_Store' -delete || true; \
    rm -f '$REMOTE_WEB_ROOT/.last_build_id' || true; \
    chown -R www-data:www-data '$REMOTE_WEB_ROOT'; \
    nginx -t; \
    systemctl reload nginx\
  "
else
  echo "[deploy_safe] --skip-web: skip web upload"
fi

if [[ "$SKIP_BACKEND" != "1" ]]; then
  echo "[deploy_safe] running remote media backfill/sanitation"
  run_ssh "$SERVER" "\
    set -e; \
    cd '$REMOTE_PROJECT_DIR/server'; \
    PUBLIC_BASE_URL='https://$HEALTH_DOMAIN' npm run media:backfill; \
    PUBLIC_BASE_URL='https://$HEALTH_DOMAIN' npm run media:sanitize; \
    npm run perf:budget\
  "
fi

if [[ "$RUN_HEALTH_CHECK" == "1" ]]; then
  echo "[deploy_safe] production health check"
  "$SCRIPTS_DIR/prod_health_check.sh" "$HEALTH_DOMAIN"
else
  echo "[deploy_safe] RUN_HEALTH_CHECK=0, skip health check"
fi

echo "[deploy_safe] done"
