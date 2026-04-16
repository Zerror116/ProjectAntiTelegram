#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/opt/fenix}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp/garphoenix-web}"
REMOTE_WEB_ROOT="${REMOTE_WEB_ROOT:-/var/www/garphoenix.com}"
REMOTE_DOWNLOADS_DIR="${REMOTE_DOWNLOADS_DIR:-$REMOTE_PROJECT_DIR/server/downloads}"
REMOTE_SERVICE="${REMOTE_SERVICE:-auto}"
BUILD_ARGS="${BUILD_ARGS:---release --no-wasm-dry-run}"
RUN_ANALYZE="${RUN_ANALYZE:-1}"
RUN_HEALTH_CHECK="${RUN_HEALTH_CHECK:-1}"
HEALTH_DOMAIN="${HEALTH_DOMAIN:-garphoenix.com}"
APK_DEFAULT_FILE_NAME="${APK_DEFAULT_FILE_NAME:-}"
APK_SOURCE="${APK_SOURCE:-}"
SKIP_BUILD="0"
NO_COMMIT="0"
APP_VERSION_NAME=""
APP_BUILD_NUMBER=""

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
  REMOTE_DOWNLOADS_DIR=/opt/fenix/server/downloads
  BRANCH=master
  REMOTE_SERVICE=auto              # or explicit, e.g. fenix-api.service
  RUN_ANALYZE=1                    # set 0 to skip flutter analyze
  APK_DEFAULT_FILE_NAME=fenix-<app-version>.apk
  APK_SOURCE=build/app/outputs/flutter-apk/app-release.apk

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

report_remote_release_check() {
  local scope="$1"
  local status="$2"
  local title="$3"
  local target="$4"
  local summary="$5"
  local details_json="${6:-{}}"
  local details_base64
  details_base64="$(printf '%s' "$details_json" | base64 | tr -d '\n')"
  run_ssh "$SERVER" \
    "cd '$REMOTE_PROJECT_DIR' && node server/scripts/report_release_health.js --scope '$scope' --status '$status' --title '$title' --target '$target' --version '${APP_VERSION_NAME:-}' --build '${APP_BUILD_NUMBER:-}' --summary '$summary' --details-base64 '$details_base64'" >/dev/null 2>&1 || true
}

echo "[deploy_full] project: $PROJECT_ROOT"
echo "[deploy_full] branch:  $BRANCH"
echo "[deploy_full] server:  $SERVER"
echo "[deploy_full] remote project: $REMOTE_PROJECT_DIR"
echo "[deploy_full] remote web root: $REMOTE_WEB_ROOT"
echo "[deploy_full] remote downloads: $REMOTE_DOWNLOADS_DIR"

resolve_app_version_info() {
  local version_line raw version_name build_number
  version_line="$(sed -n 's/^version:[[:space:]]*//p' "$PROJECT_ROOT/pubspec.yaml" | head -n 1 | tr -d '\r')"
  raw="$(printf '%s' "$version_line" | xargs)"
  if [[ -z "$raw" ]]; then
    return 1
  fi
  version_name="${raw%%+*}"
  build_number="${raw#*+}"
  if [[ "$build_number" == "$raw" ]]; then
    build_number=""
  fi
  if [[ -z "$version_name" ]]; then
    return 1
  fi
  APP_VERSION_NAME="$version_name"
  APP_BUILD_NUMBER="$build_number"
  if [[ -z "$APK_DEFAULT_FILE_NAME" ]]; then
    APK_DEFAULT_FILE_NAME="fenix-${APP_VERSION_NAME}.apk"
  fi
}

if resolve_app_version_info; then
  echo "[deploy_full] app version: ${APP_VERSION_NAME}+${APP_BUILD_NUMBER:-0}"
  echo "[deploy_full] apk file:    $APK_DEFAULT_FILE_NAME"
else
  echo "[deploy_full] warning: could not parse version from pubspec.yaml"
  if [[ -z "$APK_DEFAULT_FILE_NAME" ]]; then
    APK_DEFAULT_FILE_NAME="fenix-latest.apk"
  fi
fi

detect_apk_source() {
  if [[ -n "$APK_SOURCE" && -f "$APK_SOURCE" ]]; then
    printf '%s\n' "$APK_SOURCE"
    return 0
  fi
  local candidates=(
    "$PROJECT_ROOT/build/app/outputs/flutter-apk/app-release.apk"
    "$PROJECT_ROOT/build/app/outputs/apk/release/app-release.apk"
  )
  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
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
  rm -rf "$PROJECT_ROOT/.dart_tool/flutter_build" "$PROJECT_ROOT/build/web"
  flutter build web $BUILD_ARGS
else
  echo "[deploy_full] --skip-build: skip flutter build"
fi

strip_web_debug_artifacts
install_custom_service_worker
normalize_web_build_permissions

APK_SOURCE_RESOLVED=""
if APK_SOURCE_RESOLVED="$(detect_apk_source)"; then
  echo "[deploy_full] found APK: $APK_SOURCE_RESOLVED"
else
  echo "[deploy_full] APK not found locally, skip APK upload"
fi

echo "[deploy_full] upload build/web -> $SERVER:$REMOTE_TMP_DIR"
run_rsync -avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r --exclude='.DS_Store' --exclude='.last_build_id' \
  "$PROJECT_ROOT/build/web/" "$SERVER:$REMOTE_TMP_DIR/"

if [[ -n "$APK_SOURCE_RESOLVED" ]]; then
  REMOTE_APK_TMP_PATH="/tmp/${APK_DEFAULT_FILE_NAME}"
  echo "[deploy_full] upload APK -> $SERVER:$REMOTE_APK_TMP_PATH"
  run_rsync -avz --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "$APK_SOURCE_RESOLVED" "$SERVER:$REMOTE_APK_TMP_PATH"
fi

echo "[deploy_full] apply on server"
run_ssh "$SERVER" \
  REMOTE_PROJECT_DIR="$REMOTE_PROJECT_DIR" \
  BRANCH="$BRANCH" \
  REMOTE_TMP_DIR="$REMOTE_TMP_DIR" \
  REMOTE_WEB_ROOT="$REMOTE_WEB_ROOT" \
  REMOTE_DOWNLOADS_DIR="$REMOTE_DOWNLOADS_DIR" \
  REMOTE_SERVICE="$REMOTE_SERVICE" \
  APK_DEFAULT_FILE_NAME="$APK_DEFAULT_FILE_NAME" \
  APP_VERSION_NAME="$APP_VERSION_NAME" \
  APP_BUILD_NUMBER="$APP_BUILD_NUMBER" \
  REMOTE_APK_TMP_PATH="${REMOTE_APK_TMP_PATH:-}" \
  'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

cd "$REMOTE_PROJECT_DIR"
if [[ -n "$(git status --porcelain)" ]]; then
  STASH_NAME="autostash-before-deploy-$(date +%F-%H%M%S)"
  echo "[deploy_full][server] remote tree is dirty, creating stash: $STASH_NAME"
  git stash push -u -m "$STASH_NAME" >/dev/null || true
fi

git fetch origin "$BRANCH"
git reset --hard "origin/$BRANCH"

if [[ -d "$REMOTE_PROJECT_DIR/server" ]]; then
  cd "$REMOTE_PROJECT_DIR/server"
  if [[ -n "${APK_DEFAULT_FILE_NAME:-}" ]]; then
    if grep -q '^APP_UPDATE_ANDROID_ENABLED=' .env 2>/dev/null; then
      sed -i.bak "s#^APP_UPDATE_ANDROID_ENABLED=.*#APP_UPDATE_ANDROID_ENABLED=true#" .env
    else
      printf '\nAPP_UPDATE_ANDROID_ENABLED=true\n' >> .env
    fi
    if grep -q '^APP_UPDATE_ANDROID_DEFAULT_FILE=' .env 2>/dev/null; then
      sed -i.bak "s#^APP_UPDATE_ANDROID_DEFAULT_FILE=.*#APP_UPDATE_ANDROID_DEFAULT_FILE=$APK_DEFAULT_FILE_NAME#" .env
    else
      printf '\nAPP_UPDATE_ANDROID_DEFAULT_FILE=%s\n' "$APK_DEFAULT_FILE_NAME" >> .env
    fi
    if [[ -n "${APP_VERSION_NAME:-}" ]]; then
      if grep -q '^APP_UPDATE_ANDROID_LATEST_VERSION=' .env 2>/dev/null; then
        sed -i.bak "s#^APP_UPDATE_ANDROID_LATEST_VERSION=.*#APP_UPDATE_ANDROID_LATEST_VERSION=$APP_VERSION_NAME#" .env
      else
        printf 'APP_UPDATE_ANDROID_LATEST_VERSION=%s\n' "$APP_VERSION_NAME" >> .env
      fi
    fi
    if [[ -n "${APP_BUILD_NUMBER:-}" ]]; then
      if grep -q '^APP_UPDATE_ANDROID_LATEST_BUILD=' .env 2>/dev/null; then
        sed -i.bak "s#^APP_UPDATE_ANDROID_LATEST_BUILD=.*#APP_UPDATE_ANDROID_LATEST_BUILD=$APP_BUILD_NUMBER#" .env
      else
        printf 'APP_UPDATE_ANDROID_LATEST_BUILD=%s\n' "$APP_BUILD_NUMBER" >> .env
      fi
    fi
    rm -f .env.bak || true
  fi
  if command -v npm >/dev/null 2>&1; then
    npm ci --omit=dev
  fi
fi

if [[ -n "${REMOTE_APK_TMP_PATH:-}" && -f "$REMOTE_APK_TMP_PATH" ]]; then
  mkdir -p "$REMOTE_DOWNLOADS_DIR"
  install -m 644 "$REMOTE_APK_TMP_PATH" "$REMOTE_DOWNLOADS_DIR/$APK_DEFAULT_FILE_NAME"
fi

SERVICE="$REMOTE_SERVICE"
if [[ "$SERVICE" == "auto" ]]; then
  SERVICE=""
  PID=$(ss -ltnp 2>/dev/null | awk -F'"'"'pid='"'"' '/:3000/{split($2,a,",");print a[1]; exit}')
  if [[ -n "$PID" && -r "/proc/$PID/cgroup" ]]; then
    SERVICE=$(grep -aoE '"'"'[^/]+\.service'"'"' "/proc/$PID/cgroup" | head -n1 || true)
  fi
  if [[ -z "$SERVICE" ]]; then
    for CANDIDATE in fenix-server.service projectphoenix.service; do
      if systemctl list-unit-files --type=service | awk '{print $1}' | grep -Fxq "$CANDIDATE"; then
        SERVICE="$CANDIDATE"
        break
      fi
    done
  fi
fi

if [[ -n "$SERVICE" ]]; then
  mapfile -t PORT_3000_PIDS < <(
    ss -ltnp 2>/dev/null | grep ':3000' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
  )
  for PID in "${PORT_3000_PIDS[@]:-}"; do
    [[ -z "$PID" ]] && continue
    OWNER_SERVICE=""
    if [[ -r "/proc/$PID/cgroup" ]]; then
      OWNER_SERVICE=$(grep -aoE '[^/]+\.service' "/proc/$PID/cgroup" | head -n1 || true)
    fi
    if [[ -n "$OWNER_SERVICE" && "$OWNER_SERVICE" == "$SERVICE" ]]; then
      continue
    fi
    echo "[deploy_full][server] stopping stale process on :3000 pid=$PID service=${OWNER_SERVICE:-none}"
    kill -TERM "$PID" || true
  done
  sleep 1
  systemctl daemon-reload || true
  systemctl restart "$SERVICE"
  systemctl is-active "$SERVICE"
else
  echo "[deploy_full][server] WARNING: backend service not detected. Fallback to manual node restart."
  if [[ -d "$REMOTE_PROJECT_DIR/server" ]] && command -v npm >/dev/null 2>&1; then
    cd "$REMOTE_PROJECT_DIR/server"
    pkill -f "node src/index.js" || true
    nohup npm start >/var/log/projectphoenix-server.log 2>&1 &
    sleep 2
    if ss -ltnp 2>/dev/null | grep -q ':3000'; then
      echo "[deploy_full][server] manual backend restart OK (:3000 listening)"
    else
      echo "[deploy_full][server] ERROR: backend did not start on :3000"
      exit 1
    fi
  else
    echo "[deploy_full][server] ERROR: cannot restart backend (no server dir or npm)"
    exit 1
  fi
fi

mkdir -p "$REMOTE_WEB_ROOT"
rsync -av --delete "$REMOTE_TMP_DIR/" "$REMOTE_WEB_ROOT/"
find "$REMOTE_WEB_ROOT" -name '.DS_Store' -delete || true
rm -f "$REMOTE_WEB_ROOT/.last_build_id" || true
chown -R www-data:www-data "$REMOTE_WEB_ROOT"
if [[ -d "$REMOTE_DOWNLOADS_DIR" ]]; then
  find "$REMOTE_DOWNLOADS_DIR" -type d -exec chmod 755 {} +
  find "$REMOTE_DOWNLOADS_DIR" -type f -exec chmod 644 {} +
fi

nginx -t
systemctl reload nginx
REMOTE_SCRIPT

echo "[deploy_full] done"
if [[ "$RUN_HEALTH_CHECK" == "1" ]]; then
  echo "[deploy_full] running production health check for $HEALTH_DOMAIN"
  if HEALTH_OUTPUT="$(bash "$SCRIPT_DIR/prod_health_check.sh" "$HEALTH_DOMAIN" 2>&1)"; then
    printf '%s\n' "$HEALTH_OUTPUT"
    report_remote_release_check \
      "after_deploy_smoke" \
      "pass" \
      "Web/API after-deploy smoke passed" \
      "$HEALTH_DOMAIN" \
      "deploy smoke ok" \
      "{\"domain\":\"$HEALTH_DOMAIN\",\"branch\":\"$BRANCH\",\"app_version\":\"${APP_VERSION_NAME:-}\",\"app_build\":\"${APP_BUILD_NUMBER:-}\",\"health_output\":$(printf '%s' "$HEALTH_OUTPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
  else
    HEALTH_STATUS=$?
    printf '%s\n' "$HEALTH_OUTPUT"
    report_remote_release_check \
      "after_deploy_smoke" \
      "fail" \
      "Web/API after-deploy smoke failed" \
      "$HEALTH_DOMAIN" \
      "deploy smoke failed" \
      "{\"domain\":\"$HEALTH_DOMAIN\",\"branch\":\"$BRANCH\",\"app_version\":\"${APP_VERSION_NAME:-}\",\"app_build\":\"${APP_BUILD_NUMBER:-}\",\"health_output\":$(printf '%s' "$HEALTH_OUTPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
    exit "$HEALTH_STATUS"
  fi
else
  echo "[deploy_full] RUN_HEALTH_CHECK=0, skip production health check"
fi
