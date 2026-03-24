#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-garphoenix.com}"
BASE_URL="https://$DOMAIN"

tmp_headers="$(mktemp)"
tmp_body="$(mktemp)"
cleanup() {
  rm -f "$tmp_headers" "$tmp_body"
}
trap cleanup EXIT

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
  value=$(tr -d '\r' <"$tmp_headers" | grep -i "^$header_name:" || true)
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

echo "[check] domain: $DOMAIN"
echo

check_status "web root /" "$BASE_URL/" "200"
check_status "health /health" "$BASE_URL/health" "200"
check_status "setup protected /api/setup" "$BASE_URL/api/setup" "401,403"
check_status "dotfile blocked /.DS_Store" "$BASE_URL/.DS_Store" "403,404"
check_status "app update /api/app/update" "$BASE_URL/api/app/update" "200"
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
check_status "socket polling handshake" "$BASE_URL/socket.io/?EIO=4&transport=polling" "200"

echo "[check] security headers"
curl -sI "$BASE_URL" | tr -d '\r' | grep -Ei '^(strict-transport-security|content-security-policy|x-frame-options|x-content-type-options|referrer-policy|permissions-policy|cross-origin-opener-policy|cross-origin-resource-policy):'
echo

echo "[check] certificate"
echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -dates
echo

echo "[check] web bootstrap canvaskit override"
curl -sS "https://$DOMAIN/flutter_bootstrap.js" | grep -n "canvasKitBaseUrl" || true
