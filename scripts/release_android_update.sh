#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/opt/fenix}"
REMOTE_DOWNLOADS_DIR="${REMOTE_DOWNLOADS_DIR:-$REMOTE_PROJECT_DIR/server/downloads}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://garphoenix.com}"
RUN_ANALYZE="${RUN_ANALYZE:-1}"
FLUTTER_BIN="${FLUTTER_BIN:-}"
APKANALYZER_BIN="${APKANALYZER_BIN:-}"
USE_SSHPASS="0"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

CHANGELOG_FILE=""
MESSAGE=""
TITLE="Доступно обновление Феникс"
REQUIRED="0"
MIN_SUPPORTED_MODE="keep"
APK_INPUT=""
SKIP_BUILD="0"

APP_VERSION_NAME=""
APP_BUILD_NUMBER=""
EXPECTED_PACKAGE_NAME=""
IMMUTABLE_APK_NAME=""
LOCAL_APK_PATH=""
LOCAL_RELEASE_JSON=""
EXISTING_RELEASE_JSON=""

DEV_MANIFEST_KEY_ID="dev-ed25519"
DEV_MANIFEST_PUBLIC_KEY="-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA3q2i6PehgDQjJGDh632o6N43lDFbQUpSbOnaerrTgmk=
-----END PUBLIC KEY-----"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/release_android_update.sh \
    --changelog-file /abs/path/changelog.txt \
    [--message "Исправления и улучшения"] \
    [--title "Доступно обновление Феникс"] \
    [--required] \
    [--min-supported keep|current|1.2.3+45] \
    [--apk /abs/path/app-release.apk] \
    [--skip-build]

Env vars:
  SERVER=root@89.23.99.18
  REMOTE_PROJECT_DIR=/opt/fenix
  REMOTE_DOWNLOADS_DIR=/opt/fenix/server/downloads
  PUBLIC_BASE_URL=https://garphoenix.com
  SSH_PASSWORD=...                     # optional, requires sshpass
  FLUTTER_BIN=/opt/homebrew/bin/flutter
  APKANALYZER_BIN=/path/to/apkanalyzer
  RUN_ANALYZE=1
USAGE
}

fail() {
  echo "[release_android_update] ERROR: $*" >&2
  exit 1
}

note() {
  echo "[release_android_update] $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

cleanup() {
  if [[ -n "$LOCAL_RELEASE_JSON" && -f "$LOCAL_RELEASE_JSON" ]]; then
    rm -f "$LOCAL_RELEASE_JSON"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changelog-file)
      shift
      CHANGELOG_FILE="${1:-}"
      ;;
    --message)
      shift
      MESSAGE="${1:-}"
      ;;
    --title)
      shift
      TITLE="${1:-}"
      ;;
    --required)
      REQUIRED="1"
      ;;
    --min-supported)
      shift
      MIN_SUPPORTED_MODE="${1:-keep}"
      ;;
    --apk)
      shift
      APK_INPUT="${1:-}"
      ;;
    --skip-build)
      SKIP_BUILD="1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown arg: $1"
      ;;
  esac
  shift || true
done

[[ -n "$CHANGELOG_FILE" ]] || fail "--changelog-file is required"
[[ -f "$CHANGELOG_FILE" ]] || fail "Changelog file not found: $CHANGELOG_FILE"

if [[ -n "${SSH_PASSWORD:-}" ]]; then
  command -v sshpass >/dev/null 2>&1 || fail "SSH_PASSWORD is set, but sshpass is not installed"
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

resolve_flutter_bin() {
  if [[ -n "$FLUTTER_BIN" ]]; then
    [[ -x "$FLUTTER_BIN" ]] || fail "FLUTTER_BIN is not executable: $FLUTTER_BIN"
    return
  fi
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
    return
  fi
  if [[ -x "/opt/homebrew/bin/flutter" ]]; then
    FLUTTER_BIN="/opt/homebrew/bin/flutter"
    return
  fi
  fail "Flutter binary not found. Set FLUTTER_BIN explicitly."
}

resolve_apkanalyzer_bin() {
  if [[ -n "$APKANALYZER_BIN" ]]; then
    [[ -x "$APKANALYZER_BIN" ]] || fail "APKANALYZER_BIN is not executable: $APKANALYZER_BIN"
    return
  fi
  if command -v apkanalyzer >/dev/null 2>&1; then
    APKANALYZER_BIN="$(command -v apkanalyzer)"
    return
  fi
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  local candidate="$sdk_root/cmdline-tools/latest/bin/apkanalyzer"
  if [[ -x "$candidate" ]]; then
    APKANALYZER_BIN="$candidate"
    return
  fi
  candidate="$sdk_root/cmdline-tools/latest/cmdline-tools-temp/cmdline-tools/bin/apkanalyzer"
  if [[ -x "$candidate" ]]; then
    APKANALYZER_BIN="$candidate"
    return
  fi
  fail "apkanalyzer not found. Install Android command-line tools or set APKANALYZER_BIN."
}

normalize_pem() {
  printf '%s' "$1" | perl -0pe 's/\\n/\n/g'
}

validate_public_base_url() {
  local base="$1"
  [[ -n "$base" ]] || fail "PUBLIC_BASE_URL is required"
  case "$base" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*|http://[::1]*) ;;
    *) fail "PUBLIC_BASE_URL must be https in production (or local http for dev smoke)" ;;
  esac
}

resolve_version_info() {
  local version_line raw
  version_line="$(sed -n 's/^version:[[:space:]]*//p' "$PROJECT_ROOT/pubspec.yaml" | head -n 1 | tr -d '\r')"
  raw="$(printf '%s' "$version_line" | xargs)"
  [[ -n "$raw" ]] || fail "Could not parse version from pubspec.yaml"
  APP_VERSION_NAME="${raw%%+*}"
  APP_BUILD_NUMBER="${raw#*+}"
  [[ "$APP_BUILD_NUMBER" != "$raw" ]] || fail "pubspec.yaml version must include build number, e.g. 1.2.3+45"
  [[ -n "$APP_VERSION_NAME" ]] || fail "Invalid version name in pubspec.yaml"
  [[ "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "Invalid build number in pubspec.yaml: $APP_BUILD_NUMBER"
  IMMUTABLE_APK_NAME="fenix-${APP_VERSION_NAME}-build${APP_BUILD_NUMBER}.apk"
}

resolve_expected_package_name() {
  EXPECTED_PACKAGE_NAME="$(sed -n 's/^[[:space:]]*applicationId = "\([^"]*\)".*/\1/p' "$PROJECT_ROOT/android/app/build.gradle.kts" | head -n 1 | tr -d '\r')"
  [[ -n "$EXPECTED_PACKAGE_NAME" ]] || fail "Could not parse Android applicationId from android/app/build.gradle.kts"
}

validate_manifest_public_key_env() {
  local key_id="${APP_UPDATE_MANIFEST_KEY_ID:-}"
  local public_key_raw="${APP_UPDATE_MANIFEST_PUBLIC_KEY:-}"
  [[ -n "$key_id" ]] || fail "APP_UPDATE_MANIFEST_KEY_ID must be set for release build"
  [[ "$key_id" != "$DEV_MANIFEST_KEY_ID" ]] || fail "APP_UPDATE_MANIFEST_KEY_ID must not use dev-ed25519 for release"
  [[ -n "$public_key_raw" ]] || fail "APP_UPDATE_MANIFEST_PUBLIC_KEY must be set for release build"
  local normalized_key normalized_dev_key
  normalized_key="$(normalize_pem "$public_key_raw")"
  normalized_dev_key="$(normalize_pem "$DEV_MANIFEST_PUBLIC_KEY")"
  [[ -n "$normalized_key" ]] || fail "APP_UPDATE_MANIFEST_PUBLIC_KEY resolved to empty value"
  [[ "$normalized_key" != "$normalized_dev_key" ]] || fail "APP_UPDATE_MANIFEST_PUBLIC_KEY must not use the dev fallback key"
}

run_flutter_checks() {
  note "flutter pub get"
  "$FLUTTER_BIN" pub get

  if [[ "$RUN_ANALYZE" == "1" ]]; then
    note "flutter analyze"
    "$FLUTTER_BIN" analyze
  else
    note "RUN_ANALYZE=0, skipping flutter analyze"
  fi
}

build_release_apk_if_needed() {
  if [[ -n "$APK_INPUT" ]]; then
    LOCAL_APK_PATH="$APK_INPUT"
    [[ -f "$LOCAL_APK_PATH" ]] || fail "APK file not found: $LOCAL_APK_PATH"
    note "using provided APK: $LOCAL_APK_PATH"
    return
  fi

  if [[ "$SKIP_BUILD" != "1" ]]; then
    note "flutter build apk --release"
    "$FLUTTER_BIN" build apk --release
  else
    note "--skip-build: reusing existing local APK"
  fi

  local candidates=(
    "$PROJECT_ROOT/build/app/outputs/flutter-apk/app-release.apk"
    "$PROJECT_ROOT/build/app/outputs/apk/release/app-release.apk"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      LOCAL_APK_PATH="$candidate"
      note "resolved APK: $LOCAL_APK_PATH"
      return
    fi
  done

  fail "Release APK not found. Build it first or pass --apk /path/to/app-release.apk"
}

resolve_apk_package_name() {
  local package_name
  package_name="$($APKANALYZER_BIN manifest application-id "$LOCAL_APK_PATH" 2>/dev/null | head -n 1 | tr -d '\r')"
  [[ -n "$package_name" ]] || fail "Could not read package name from APK via apkanalyzer"
  printf '%s\n' "$package_name"
}

stat_file_size() {
  local file_path="$1"
  if stat -f%z "$file_path" >/dev/null 2>&1; then
    stat -f%z "$file_path"
  else
    stat -c%s "$file_path"
  fi
}

read_existing_release_json() {
  EXISTING_RELEASE_JSON="$(run_ssh "$SERVER" "if [ -f '$REMOTE_DOWNLOADS_DIR/android-stable.release.json' ]; then cat '$REMOTE_DOWNLOADS_DIR/android-stable.release.json'; fi" 2>/dev/null || true)"
}

resolve_min_supported() {
  local mode="$1"
  local min_version=""
  local min_build=""

  case "$mode" in
    keep)
      if [[ -n "$EXISTING_RELEASE_JSON" ]]; then
        min_version="$(printf '%s' "$EXISTING_RELEASE_JSON" | jq -r '.min_supported_version // empty' 2>/dev/null || true)"
        min_build="$(printf '%s' "$EXISTING_RELEASE_JSON" | jq -r '.min_supported_build // empty' 2>/dev/null || true)"
      fi
      ;;
    current)
      min_version="$APP_VERSION_NAME"
      min_build="$APP_BUILD_NUMBER"
      ;;
    *)
      if [[ "$mode" =~ ^([0-9]+(\.[0-9]+)*)\+([0-9]+)$ ]]; then
        min_version="${BASH_REMATCH[1]}"
        min_build="${BASH_REMATCH[3]}"
      else
        fail "--min-supported must be keep, current, or <version+build>"
      fi
      ;;
  esac

  printf '%s|%s\n' "$min_version" "$min_build"
}

read_changelog_json() {
  local changelog_json
  changelog_json="$(jq -R -s 'split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' "$CHANGELOG_FILE")"
  [[ "$changelog_json" != "[]" ]] || fail "Changelog file must contain at least one non-empty line"
  printf '%s\n' "$changelog_json"
}

write_release_json() {
  local min_supported_version="$1"
  local min_supported_build="$2"
  local changelog_json="$3"
  local published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local message_value="$MESSAGE"
  local mirrors_json='[]'
  if [[ -n "${ANDROID_UPDATE_MIRRORS:-}" ]]; then
    mirrors_json="$(printf '%s' "$ANDROID_UPDATE_MIRRORS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
  fi

  LOCAL_RELEASE_JSON="$(mktemp -t android-stable-release.XXXXXX.json)"
  jq -n \
    --arg version "$APP_VERSION_NAME" \
    --argjson build "$APP_BUILD_NUMBER" \
    --arg channel "stable" \
    --argjson required "$([[ "$REQUIRED" == "1" ]] && printf 'true' || printf 'false')" \
    --arg minSupportedVersion "$min_supported_version" \
    --arg minSupportedBuild "$min_supported_build" \
    --arg title "$TITLE" \
    --arg message "$message_value" \
    --arg apkFile "$IMMUTABLE_APK_NAME" \
    --arg packageName "$EXPECTED_PACKAGE_NAME" \
    --arg publishedAt "$published_at" \
    --argjson changelog "$changelog_json" \
    --argjson mirrors "$mirrors_json" \
    '{
      version: $version,
      build: $build,
      channel: $channel,
      required: $required,
      min_supported_version: (if $minSupportedVersion == "" then null else $minSupportedVersion end),
      min_supported_build: (if $minSupportedBuild == "" then null else ($minSupportedBuild | tonumber) end),
      title: $title,
      message: (if $message == "" then null else $message end),
      changelog: $changelog,
      apk_file: $apkFile,
      package_name: $packageName,
      published_at: $publishedAt,
      mirrors: $mirrors
    }' > "$LOCAL_RELEASE_JSON"
}

upload_release_files() {
  local remote_apk_tmp="$REMOTE_DOWNLOADS_DIR/.${IMMUTABLE_APK_NAME}.tmp.$$"
  local remote_json_tmp="$REMOTE_DOWNLOADS_DIR/.android-stable.release.json.tmp.$$"

  note "prepare remote downloads dir"
  run_ssh "$SERVER" "mkdir -p '$REMOTE_DOWNLOADS_DIR'"

  note "upload APK -> $SERVER:$REMOTE_DOWNLOADS_DIR/$IMMUTABLE_APK_NAME"
  run_rsync -avz --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "$LOCAL_APK_PATH" "$SERVER:$remote_apk_tmp"

  note "upload release JSON -> $SERVER:$REMOTE_DOWNLOADS_DIR/android-stable.release.json"
  run_rsync -avz --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "$LOCAL_RELEASE_JSON" "$SERVER:$remote_json_tmp"

  run_ssh "$SERVER" "chmod 644 '$remote_apk_tmp' '$remote_json_tmp' && mv -f '$remote_apk_tmp' '$REMOTE_DOWNLOADS_DIR/$IMMUTABLE_APK_NAME' && mv -f '$remote_json_tmp' '$REMOTE_DOWNLOADS_DIR/android-stable.release.json'"
}

smoke_check_remote_release() {
  local base="${PUBLIC_BASE_URL%/}"
  local update_json manifest_json legacy_manifest_21_json headers_html landing_html legacy20_manifest_file legacy20_status

  note "smoke: GET $base/api/app/update"
  update_json="$(curl -fsSL "$base/api/app/update")"
  [[ "$(printf '%s' "$update_json" | jq -r '.ok')" == "true" ]] || fail "Smoke failed: /api/app/update returned ok=false"
  [[ "$(printf '%s' "$update_json" | jq -r '.data.android.enabled')" == "true" ]] || fail "Smoke failed: android.enabled is not true"
  [[ "$(printf '%s' "$update_json" | jq -r '.data.android.latest_version')" == "$APP_VERSION_NAME" ]] || fail "Smoke failed: latest_version mismatch"
  [[ "$(printf '%s' "$update_json" | jq -r '.data.android.latest_build')" == "$APP_BUILD_NUMBER" ]] || fail "Smoke failed: latest_build mismatch"
  [[ "$(printf '%s' "$update_json" | jq -r '.data.android.channel')" == "stable" ]] || fail "Smoke failed: channel is not stable"

  note "smoke: GET $base/api/app/update/android/manifest"
  manifest_json="$(curl -fsSL "$base/api/app/update/android/manifest")"
  [[ "$(printf '%s' "$manifest_json" | jq -r '.ok')" == "true" ]] || fail "Smoke failed: manifest returned ok=false"
  [[ "$(printf '%s' "$manifest_json" | jq -r '.data.manifest.version')" == "$APP_VERSION_NAME" ]] || fail "Smoke failed: manifest version mismatch"
  [[ "$(printf '%s' "$manifest_json" | jq -r '.data.manifest.build')" == "$APP_BUILD_NUMBER" ]] || fail "Smoke failed: manifest build mismatch"
  [[ "$(printf '%s' "$manifest_json" | jq -r '.data.manifest.package_name')" == "$EXPECTED_PACKAGE_NAME" ]] || fail "Smoke failed: manifest package_name mismatch"
  [[ "$(printf '%s' "$manifest_json" | jq -r '.data.manifest.sha256')" == "$APK_SHA256" ]] || fail "Smoke failed: manifest sha256 mismatch"
  [[ "$(printf '%s' "$manifest_json" | jq -r '.data.key_id')" == "${APP_UPDATE_MANIFEST_KEY_ID}" ]] || fail "Smoke failed: manifest key_id mismatch"
  printf '%s' "$manifest_json" | APP_UPDATE_MANIFEST_PUBLIC_KEY="$APP_UPDATE_MANIFEST_PUBLIC_KEY" \
    node "$SCRIPT_DIR/check_android_manifest_parity.js" --stdin >/dev/null || fail "Smoke failed: manifest parity/signature verification failed"

  note "smoke: GET $base/api/app/update/android/manifest?current_build=21"
  legacy_manifest_21_json="$(curl -fsSL "$base/api/app/update/android/manifest?current_build=21")"
  [[ "$(printf '%s' "$legacy_manifest_21_json" | jq -r '.ok')" == "true" ]] || fail "Smoke failed: legacy build 21 manifest returned ok=false"
  [[ "$(printf '%s' "$legacy_manifest_21_json" | jq -r '.data.manifest.version')" == "$APP_VERSION_NAME" ]] || fail "Smoke failed: legacy build 21 manifest version mismatch"
  [[ "$(printf '%s' "$legacy_manifest_21_json" | jq -r '.data.manifest.build')" == "$APP_BUILD_NUMBER" ]] || fail "Smoke failed: legacy build 21 manifest build mismatch"
  printf '%s' "$legacy_manifest_21_json" | APP_UPDATE_MANIFEST_PUBLIC_KEY="$APP_UPDATE_MANIFEST_PUBLIC_KEY" \
    node "$SCRIPT_DIR/check_android_manifest_parity.js" --stdin >/dev/null || fail "Smoke failed: legacy build 21 parity/signature verification failed"

  legacy20_manifest_file="$(mktemp -t fenix-legacy20-manifest.XXXXXX.json)"
  legacy20_status="$(curl -sS -o "$legacy20_manifest_file" -w '%{http_code}' "$base/api/app/update/android/manifest?current_build=20")"
  [[ "$legacy20_status" == "404" ]] || fail "Smoke failed: legacy build 20 expected 404, got $legacy20_status"
  [[ "$(jq -r '.code' < "$legacy20_manifest_file")" == "unsupported_legacy_build" ]] || fail "Smoke failed: legacy build 20 code mismatch"
  rm -f "$legacy20_manifest_file"

  note "smoke: HEAD $base/api/app/update/android/apk"
  headers_html="$(curl -fsSI -H 'User-Agent: Android' -H 'X-Fenix-Platform: android' "$base/api/app/update/android/apk")"
  printf '%s' "$headers_html" | grep -iq '^accept-ranges: bytes' || fail "Smoke failed: APK endpoint missing Accept-Ranges"
  printf '%s' "$headers_html" | grep -iq '^etag:' || fail "Smoke failed: APK endpoint missing ETag"
  printf '%s' "$headers_html" | grep -iq '^last-modified:' || fail "Smoke failed: APK endpoint missing Last-Modified"

  note "smoke: GET $base/download/android"
  landing_html="$(curl -fsSL -L "$base/download/android")"
  printf '%s' "$landing_html" | grep -q 'Феникс для Android' || fail "Smoke failed: landing page title missing"
  printf '%s' "$landing_html" | grep -q 'SHA-256' || fail "Smoke failed: landing page missing SHA-256"
  printf '%s' "$landing_html" | grep -q "$APP_VERSION_NAME" || fail "Smoke failed: landing page version mismatch"
  printf '%s' "$landing_html" | grep -q "$APK_SHA256" || fail "Smoke failed: landing page sha256 mismatch"
}

resolve_flutter_bin
resolve_apkanalyzer_bin
require_command jq
require_command curl
require_command shasum
require_command rsync
require_command ssh
require_command node
validate_public_base_url "$PUBLIC_BASE_URL"
resolve_version_info
resolve_expected_package_name
validate_manifest_public_key_env

note "project root: $PROJECT_ROOT"
note "server: $SERVER"
note "public base url: $PUBLIC_BASE_URL"
note "version: ${APP_VERSION_NAME}+${APP_BUILD_NUMBER}"
note "expected package: $EXPECTED_PACKAGE_NAME"
note "release APK name: $IMMUTABLE_APK_NAME"

cd "$PROJECT_ROOT"
run_flutter_checks
build_release_apk_if_needed

ACTUAL_PACKAGE_NAME="$(resolve_apk_package_name)"
[[ "$ACTUAL_PACKAGE_NAME" == "$EXPECTED_PACKAGE_NAME" ]] || fail "APK package_name mismatch: expected $EXPECTED_PACKAGE_NAME, got $ACTUAL_PACKAGE_NAME"

APK_SHA256="$(shasum -a 256 "$LOCAL_APK_PATH" | awk '{print $1}')"
APK_FILE_SIZE="$(stat_file_size "$LOCAL_APK_PATH")"
note "APK sha256: $APK_SHA256"
note "APK size: $APK_FILE_SIZE bytes"

read_existing_release_json
IFS='|' read -r MIN_SUPPORTED_VERSION MIN_SUPPORTED_BUILD <<< "$(resolve_min_supported "$MIN_SUPPORTED_MODE")"
CHANGELOG_JSON="$(read_changelog_json)"
write_release_json "$MIN_SUPPORTED_VERSION" "$MIN_SUPPORTED_BUILD" "$CHANGELOG_JSON"
upload_release_files
if SMOKE_OUTPUT="$(smoke_check_remote_release 2>&1)"; then
  printf '%s\n' "$SMOKE_OUTPUT"
  report_remote_release_check \
    "android_release" \
    "pass" \
    "Android stable release published" \
    "$PUBLIC_BASE_URL" \
    "android release smoke ok" \
    "{\"public_base_url\":\"$PUBLIC_BASE_URL\",\"immutable_apk_name\":\"$IMMUTABLE_APK_NAME\",\"apk_sha256\":\"$APK_SHA256\",\"apk_size\":$APK_FILE_SIZE,\"smoke_output\":$(printf '%s' "$SMOKE_OUTPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
else
  SMOKE_STATUS=$?
  printf '%s\n' "$SMOKE_OUTPUT"
  report_remote_release_check \
    "android_release" \
    "fail" \
    "Android stable release smoke failed" \
    "$PUBLIC_BASE_URL" \
    "android release smoke failed" \
    "{\"public_base_url\":\"$PUBLIC_BASE_URL\",\"immutable_apk_name\":\"$IMMUTABLE_APK_NAME\",\"apk_sha256\":\"$APK_SHA256\",\"apk_size\":$APK_FILE_SIZE,\"smoke_output\":$(printf '%s' "$SMOKE_OUTPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
  exit "$SMOKE_STATUS"
fi

note "release published successfully"
note "remote APK: $REMOTE_DOWNLOADS_DIR/$IMMUTABLE_APK_NAME"
note "remote JSON: $REMOTE_DOWNLOADS_DIR/android-stable.release.json"
