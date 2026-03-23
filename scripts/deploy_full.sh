#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/opt/fenix}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp/garphoenix-web}"
REMOTE_WEB_ROOT="${REMOTE_WEB_ROOT:-/var/www/garphoenix.com}"
REMOTE_SERVICE="${REMOTE_SERVICE:-auto}"
BUILD_ARGS="${BUILD_ARGS:---release --no-wasm-dry-run}"
RUN_ANALYZE="${RUN_ANALYZE:-1}"
SKIP_BUILD="0"
NO_COMMIT="0"

CURRENT_BRANCH="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
BRANCH="${BRANCH:-$CURRENT_BRANCH}"
COMMIT_MESSAGE=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy_full.sh [-m "commit message"] [--skip-build] [--no-commit]

What it does:
  1) git add/commit/push (optional)
  2) flutter analyze + flutter build web
  3) upload build/web to server
  4) on server: git pull, npm ci, restart backend service, reload nginx

Important env vars:
  SERVER=root@89.23.99.18
  SSH_PASSWORD=anubis              # optional; requires sshpass
  REMOTE_PROJECT_DIR=/opt/fenix
  REMOTE_WEB_ROOT=/var/www/garphoenix.com
  BRANCH=master
  REMOTE_SERVICE=auto              # or explicit, e.g. fenix-api.service
  RUN_ANALYZE=1                    # set 0 to skip flutter analyze

Examples:
  SSH_PASSWORD=anubis ./scripts/deploy_full.sh -m "web+api deploy"
  ./scripts/deploy_full.sh --skip-build --no-commit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)
      shift
      COMMIT_MESSAGE="${1:-}"
      ;;
    --skip-build)
      SKIP_BUILD="1"
      ;;
    --no-commit)
      NO_COMMIT="1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
  shift || true
done

if [[ -z "$COMMIT_MESSAGE" ]]; then
  COMMIT_MESSAGE="deploy: $(date '+%Y-%m-%d %H:%M:%S')"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
USE_SSHPASS="0"
if [[ -n "${SSH_PASSWORD:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "[deploy_full] SSH_PASSWORD is set, but sshpass is not installed."
    echo "[deploy_full] Install on macOS: brew install hudochenkov/sshpass/sshpass"
    exit 1
  fi
  USE_SSHPASS="1"
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
    rsync "$@"
  fi
}

echo "[deploy_full] project: $PROJECT_ROOT"
echo "[deploy_full] branch:  $BRANCH"
echo "[deploy_full] server:  $SERVER"
echo "[deploy_full] remote project: $REMOTE_PROJECT_DIR"
echo "[deploy_full] remote web root: $REMOTE_WEB_ROOT"

cd "$PROJECT_ROOT"

if [[ "$NO_COMMIT" != "1" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "[deploy_full] git add/commit..."
    git add -A
    if [[ -n "$(git diff --cached --name-only)" ]]; then
      git commit -m "$COMMIT_MESSAGE"
    else
      echo "[deploy_full] nothing staged after git add"
    fi
  else
    echo "[deploy_full] working tree clean, skip commit"
  fi
else
  echo "[deploy_full] --no-commit: skip git add/commit"
fi

echo "[deploy_full] git push origin $BRANCH"
git push origin "$BRANCH"

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "[deploy_full] flutter pub get"
  flutter pub get

  if [[ "$RUN_ANALYZE" == "1" ]]; then
    echo "[deploy_full] flutter analyze"
    flutter analyze
  else
    echo "[deploy_full] RUN_ANALYZE=0, skip analyze"
  fi

  echo "[deploy_full] flutter build web $BUILD_ARGS"
  flutter build web $BUILD_ARGS
else
  echo "[deploy_full] --skip-build: skip flutter build"
fi

find "$PROJECT_ROOT/build/web" -name '.DS_Store' -delete || true
rm -f "$PROJECT_ROOT/build/web/.last_build_id" || true

echo "[deploy_full] upload build/web -> $SERVER:$REMOTE_TMP_DIR"
run_rsync -avz --delete --exclude='.DS_Store' --exclude='.last_build_id' \
  "$PROJECT_ROOT/build/web/" "$SERVER:$REMOTE_TMP_DIR/"

echo "[deploy_full] apply on server"
run_ssh "$SERVER" \
  REMOTE_PROJECT_DIR="$REMOTE_PROJECT_DIR" \
  BRANCH="$BRANCH" \
  REMOTE_TMP_DIR="$REMOTE_TMP_DIR" \
  REMOTE_WEB_ROOT="$REMOTE_WEB_ROOT" \
  REMOTE_SERVICE="$REMOTE_SERVICE" \
  'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

cd "$REMOTE_PROJECT_DIR"
git pull --ff-only origin "$BRANCH"

if [[ -d "$REMOTE_PROJECT_DIR/server" ]]; then
  cd "$REMOTE_PROJECT_DIR/server"
  if command -v npm >/dev/null 2>&1; then
    npm ci --omit=dev
  fi
fi

SERVICE="$REMOTE_SERVICE"
if [[ "$SERVICE" == "auto" ]]; then
  SERVICE=""
  PID=$(ss -ltnp 2>/dev/null | awk -F'"'"'pid='"'"' '/:3000/{split($2,a,", ");print a[1]; exit}')
  if [[ -n "$PID" && -r "/proc/$PID/cgroup" ]]; then
    SERVICE=$(grep -aoE '"'"'[^/]+\.service'"'"' "/proc/$PID/cgroup" | head -n1 || true)
  fi
fi

if [[ -n "$SERVICE" ]]; then
  systemctl daemon-reload || true
  systemctl restart "$SERVICE"
  systemctl is-active "$SERVICE"
else
  echo "[deploy_full][server] WARNING: backend service not detected. Set REMOTE_SERVICE explicitly."
fi

mkdir -p "$REMOTE_WEB_ROOT"
rsync -av --delete "$REMOTE_TMP_DIR/" "$REMOTE_WEB_ROOT/"
find "$REMOTE_WEB_ROOT" -name '.DS_Store' -delete || true
rm -f "$REMOTE_WEB_ROOT/.last_build_id" || true
chown -R www-data:www-data "$REMOTE_WEB_ROOT"

nginx -t
systemctl reload nginx
REMOTE_SCRIPT

echo "[deploy_full] done"
echo "[deploy_full] quick checks:"
echo "  curl -Iv https://garphoenix.com"
echo "  curl -I https://garphoenix.com/.DS_Store"
