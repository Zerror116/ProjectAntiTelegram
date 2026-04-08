#!/usr/bin/env bash
set -euo pipefail

KEY_ID=""
OUT_DIR=""
FORCE="0"
OPENSSL_BIN="${OPENSSL_BIN:-}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/generate_android_update_manifest_keys.sh [--key-id fenix-ed25519-v1] [--out-dir /secure/path] [--force]

What it creates:
- private.pem                # server-only secret
- public.pem                 # public key for Android release build + server env
- server_manifest.env        # APP_UPDATE_MANIFEST_* for backend server
- android_release_build.env  # public key + key id for local release build shell
- README.txt                 # one-time setup notes

Defaults:
- key id: fenix-ed25519-v<UTC timestamp>
- out dir: /tmp/fenix-android-update-keys-<key-id>

Optional env:
- OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl
USAGE
}

fail() {
  echo "[generate_android_update_manifest_keys] ERROR: $*" >&2
  exit 1
}

note() {
  echo "[generate_android_update_manifest_keys] $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

resolve_openssl_bin() {
  if [[ -n "$OPENSSL_BIN" ]]; then
    [[ -x "$OPENSSL_BIN" ]] || fail "OPENSSL_BIN is not executable: $OPENSSL_BIN"
    return
  fi

  local candidates=(
    "/opt/homebrew/opt/openssl@3/bin/openssl"
    "/opt/homebrew/opt/openssl/bin/openssl"
    "$(command -v openssl 2>/dev/null || true)"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    [[ -x "$candidate" ]] || continue
    if "$candidate" list -public-key-algorithms 2>/dev/null | grep -q 'ED25519'; then
      OPENSSL_BIN="$candidate"
      return
    fi
  done

  fail "Could not find an OpenSSL binary with Ed25519 support. Install openssl@3 or set OPENSSL_BIN."
}

escape_pem_for_env() {
  python3 - <<'PY' "$1"
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').strip().replace('\n', '\\n'))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-id)
      shift
      KEY_ID="${1:-}"
      ;;
    --out-dir)
      shift
      OUT_DIR="${1:-}"
      ;;
    --force)
      FORCE="1"
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

require_command openssl
require_command python3
resolve_openssl_bin

if [[ -z "$KEY_ID" ]]; then
  KEY_ID="fenix-ed25519-v$(date -u +%Y%m%d%H%M%S)"
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="/tmp/fenix-android-update-keys-$KEY_ID"
fi

if [[ -e "$OUT_DIR" && "$FORCE" != "1" ]]; then
  fail "Output path already exists: $OUT_DIR (use --force to overwrite)"
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

PRIVATE_KEY_PATH="$OUT_DIR/private.pem"
PUBLIC_KEY_PATH="$OUT_DIR/public.pem"
SERVER_ENV_PATH="$OUT_DIR/server_manifest.env"
ANDROID_ENV_PATH="$OUT_DIR/android_release_build.env"
README_PATH="$OUT_DIR/README.txt"

note "generating Ed25519 private key"
"$OPENSSL_BIN" genpkey -algorithm Ed25519 -out "$PRIVATE_KEY_PATH" >/dev/null 2>&1 \
  || fail "OpenSSL failed to generate Ed25519 private key via $OPENSSL_BIN"
"$OPENSSL_BIN" pkey -in "$PRIVATE_KEY_PATH" -pubout -out "$PUBLIC_KEY_PATH" >/dev/null 2>&1 \
  || fail "OpenSSL failed to derive public key via $OPENSSL_BIN"
chmod 600 "$PRIVATE_KEY_PATH" "$PUBLIC_KEY_PATH"

ESCAPED_PUBLIC_KEY="$(escape_pem_for_env "$PUBLIC_KEY_PATH")"
ESCAPED_PRIVATE_KEY="$(escape_pem_for_env "$PRIVATE_KEY_PATH")"

cat > "$SERVER_ENV_PATH" <<ENVEOF
APP_UPDATE_MANIFEST_KEY_ID=$KEY_ID
APP_UPDATE_MANIFEST_PUBLIC_KEY=$ESCAPED_PUBLIC_KEY
APP_UPDATE_MANIFEST_PRIVATE_KEY=$ESCAPED_PRIVATE_KEY
ENVEOF
chmod 600 "$SERVER_ENV_PATH"

cat > "$ANDROID_ENV_PATH" <<ENVEOF
APP_UPDATE_MANIFEST_KEY_ID=$KEY_ID
APP_UPDATE_MANIFEST_PUBLIC_KEY=$ESCAPED_PUBLIC_KEY
ENVEOF
chmod 600 "$ANDROID_ENV_PATH"

cat > "$README_PATH" <<READEOF
Android updater manifest signing keys
====================================

Key id:
$KEY_ID

Files:
- private.pem                -> server-only secret, do not copy into the app
- public.pem                 -> safe to use in Android release build and server env
- server_manifest.env        -> set these vars on the backend server once
- android_release_build.env  -> source this locally before running release_android_update.sh

Server one-time setup:
1. Add APP_UPDATE_MANIFEST_KEY_ID to server env
2. Add APP_UPDATE_MANIFEST_PUBLIC_KEY to server env
3. Add APP_UPDATE_MANIFEST_PRIVATE_KEY to server env
4. Restart backend once

Local release setup:
1. source "$ANDROID_ENV_PATH"
2. run /Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/release_android_update.sh --changelog-file /abs/path/changelog.txt

Important:
- Keep private.pem and server_manifest.env secret
- Do not commit these files into git
- The Android app only needs the public key + key id during release build
READEOF
chmod 600 "$README_PATH"

note "done"
note "openssl bin: $OPENSSL_BIN"
note "out dir: $OUT_DIR"
note "server env file: $SERVER_ENV_PATH"
note "android build env file: $ANDROID_ENV_PATH"
note "readme: $README_PATH"
