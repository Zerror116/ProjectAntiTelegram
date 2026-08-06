#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-garphoenix.com}"
BASE_URL="https://$DOMAIN"

tmp_headers="$(mktemp)"
tmp_body="$(mktemp)"
tmp_update_body="$(mktemp)"
cleanup() {
  rm -f "$tmp_headers" "$tmp_body" "$tmp_update_body"
}
trap cleanup EXIT
LAST_STATUS_CODE=""

check_status() {
  local name="$1"
  local url="$2"
  local expected_csv="$3"
  shift 3
  local curl_args=("$@")

  : >"$tmp_headers"
  : >"$tmp_body"
  local code
  if [[ "${#curl_args[@]}" -gt 0 ]]; then
    code=$(curl -sS -L -D "$tmp_headers" -o "$tmp_body" "${curl_args[@]}" "$url" -w "%{http_code}")
  else
    code=$(curl -sS -L -D "$tmp_headers" -o "$tmp_body" "$url" -w "%{http_code}")
  fi
  LAST_STATUS_CODE="$code"
  IFS=',' read -r -a expected <<<"$expected_csv"

  local ok=0
  for ec in "${expected[@]}"; do
    if [[ "$code" == "$ec" ]]; then
      ok=1
      break
    fi
  done

  if [[ "$ok" -eq 1 ]]; then
    echo "[ok] $name => $code"
  else
    echo "[fail] $name => $code (expected: $expected_csv)"
    echo "--- response headers ---"
    sed -n '1,40p' "$tmp_headers"
    echo "--- response body ---"
    sed -n '1,40p' "$tmp_body"
    exit 1
  fi
}

check_contains_header() {
  local name="$1"
  local header_name="$2"
  local expected_substring="$3"
  local value
  value=$(tr -d '\r' <"$tmp_headers" | grep -i "^$header_name:" | tail -n 1 || true)
  if [[ -z "$value" ]]; then
    echo "[fail] $name => missing header '$header_name'"
    exit 1
  fi
  if [[ "$value" != *"$expected_substring"* ]]; then
    echo "[fail] $name => header '$header_name' does not contain '$expected_substring'"
    echo "actual: $value"
    exit 1
  fi
  echo "[ok] $name"
}

header_value() {
  local header_name="$1"
  tr -d '\r' <"$tmp_headers" | grep -i "^$header_name:" | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' || true
}

check_header_equals() {
  local name="$1"
  local header_name="$2"
  local expected="$3"
  local value
  value="$(header_value "$header_name")"
  if [[ -z "$value" ]]; then
    echo "[fail] $name => missing header '$header_name'"
    exit 1
  fi
  if [[ "$value" != "$expected" ]]; then
    echo "[fail] $name => header '$header_name' mismatch"
    echo "expected: $expected"
    echo "actual:   $value"
    exit 1
  fi
  echo "[ok] $name"
}

json_field_from_file() {
  local file="$1"
  local path_expr="$2"
  node - "$file" "$path_expr" <<'NODE' 2>/dev/null || true
const fs = require('fs');
const file = process.argv[2];
const pathExpr = process.argv[3] || '';
try {
  let value = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const part of pathExpr.split('.').filter(Boolean)) {
    value = value?.[part];
  }
  if (value !== undefined && value !== null) {
    process.stdout.write(String(value));
  }
} catch (_) {}
NODE
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "[fail] $name => missing value"
    exit 1
  fi
  echo "[ok] $name => $value"
}

check_value_equals() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "[fail] $name => mismatch"
    echo "expected: $expected"
    echo "actual:   $actual"
    exit 1
  fi
  echo "[ok] $name"
}

check_numeric_value() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "[fail] $name => expected numeric value, got '$value'"
    exit 1
  fi
  echo "[ok] $name => $value"
}

echo "[check] domain: $DOMAIN"
echo

check_status "web root /" "$BASE_URL/" "200"
check_status "health /health" "$BASE_URL/health" "200"
check_status "setup protected /api/setup" "$BASE_URL/api/setup" "401,403"
check_status "dotfile blocked /.DS_Store" "$BASE_URL/.DS_Store" "403,404"
check_status "app update /api/app/update" "$BASE_URL/api/app/update" "200"
cp "$tmp_body" "$tmp_update_body"
ANDROID_ENABLED="$(json_field_from_file "$tmp_update_body" "data.android.enabled")"
ANDROID_LATEST_VERSION="$(json_field_from_file "$tmp_update_body" "data.android.latest_version")"
ANDROID_LATEST_BUILD="$(json_field_from_file "$tmp_update_body" "data.android.latest_build")"
ANDROID_DOWNLOAD_URL="$(json_field_from_file "$tmp_update_body" "data.android.download_url")"
ANDROID_RELEASE_FILE="$(json_field_from_file "$tmp_update_body" "data.android.release_file")"
ANDROID_FILE_SIZE="$(json_field_from_file "$tmp_update_body" "data.android.file_size")"
ANDROID_SHA256="$(json_field_from_file "$tmp_update_body" "data.android.sha256")"
check_value_equals "android update enabled" "$ANDROID_ENABLED" "true"
require_value "android update latest_version" "$ANDROID_LATEST_VERSION"
require_value "android update latest_build" "$ANDROID_LATEST_BUILD"
require_value "android update download_url" "$ANDROID_DOWNLOAD_URL"
require_value "android update release_file" "$ANDROID_RELEASE_FILE"
require_value "android update sha256" "$ANDROID_SHA256"
check_numeric_value "android update file_size" "$ANDROID_FILE_SIZE"
check_status \
  "android apk blocked for non-android ua" \
  "$BASE_URL/api/app/update/android/apk" \
  "403,404" \
  -I
check_status \
  "android apk allowed for android ua" \
  "$BASE_URL/api/app/update/android/apk" \
  "200" \
  -I \
  -A "Mozilla/5.0 (Linux; Android 14; Pixel 8)"
check_contains_header \
  "android apk content type" \
  "content-type" \
  "application/vnd.android.package-archive"
check_header_equals \
  "android apk content length" \
  "content-length" \
  "$ANDROID_FILE_SIZE"
check_contains_header \
  "android apk filename" \
  "content-disposition" \
  "$ANDROID_RELEASE_FILE"
check_status \
  "android manifest" \
  "$BASE_URL/api/app/update/android/manifest" \
  "200" \
  -A "Mozilla/5.0 (Linux; Android 14; Pixel 8)"
MANIFEST_VERSION="$(json_field_from_file "$tmp_body" "data.manifest.version")"
MANIFEST_BUILD="$(json_field_from_file "$tmp_body" "data.manifest.build")"
MANIFEST_DOWNLOAD_URL="$(json_field_from_file "$tmp_body" "data.manifest.download_url")"
MANIFEST_FILE_SIZE="$(json_field_from_file "$tmp_body" "data.manifest.file_size")"
MANIFEST_SHA256="$(json_field_from_file "$tmp_body" "data.manifest.sha256")"
require_value "android manifest version" "$MANIFEST_VERSION"
require_value "android manifest build" "$MANIFEST_BUILD"
require_value "android manifest download_url" "$MANIFEST_DOWNLOAD_URL"
require_value "android manifest sha256" "$MANIFEST_SHA256"
check_numeric_value "android manifest file_size" "$MANIFEST_FILE_SIZE"
check_value_equals "android manifest version matches update" "$MANIFEST_VERSION" "$ANDROID_LATEST_VERSION"
check_value_equals "android manifest build matches update" "$MANIFEST_BUILD" "$ANDROID_LATEST_BUILD"
check_value_equals "android manifest download_url matches update" "$MANIFEST_DOWNLOAD_URL" "$ANDROID_DOWNLOAD_URL"
check_value_equals "android manifest file_size matches update" "$MANIFEST_FILE_SIZE" "$ANDROID_FILE_SIZE"
check_value_equals "android manifest sha256 matches update" "$MANIFEST_SHA256" "$ANDROID_SHA256"
check_status \
  "direct /downloads apk path" \
  "$BASE_URL/downloads/$ANDROID_RELEASE_FILE" \
  "200" \
  -I \
  -A "Mozilla/5.0 (Linux; Android 14; Pixel 8)"
check_contains_header \
  "direct /downloads content type" \
  "content-type" \
  "application/vnd.android.package-archive"
check_header_equals \
  "direct /downloads content length" \
  "content-length" \
  "$ANDROID_FILE_SIZE"
check_status "socket polling handshake" "$BASE_URL/socket.io/?EIO=4&transport=polling" "200"

echo "[check] security headers"
curl -sI "$BASE_URL" | tr -d '\r' | grep -Ei '^(strict-transport-security|content-security-policy|x-frame-options|x-content-type-options|referrer-policy|permissions-policy|cross-origin-opener-policy|cross-origin-resource-policy):'
echo

echo "[check] certificate"
echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -dates
echo

echo "[check] web bootstrap canvaskit override"
if curl -sS "https://$DOMAIN/flutter_bootstrap.js" | grep -q "canvasKitBaseUrl"; then
  echo "[ok] canvasKitBaseUrl override detected"
else
  echo "[warn] canvasKitBaseUrl override not found in flutter_bootstrap.js"
fi
