#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE_URL="${FENIX_API_BASE_URL:-http://127.0.0.1:3001}"
RUN_MACOS_ITEST="${RUN_MACOS_ITEST:-1}"
RUN_ANDROID_BUILD="${RUN_ANDROID_BUILD:-1}"

cd "$ROOT_DIR"

echo "[messenger_gate_local] health check -> $API_BASE_URL/health"
curl -fsS "$API_BASE_URL/health" >/dev/null

echo "[messenger_gate_local] flutter analyze"
flutter analyze

echo "[messenger_gate_local] flutter unit tests"
flutter test test/widget_test.dart test/messenger_ui_helpers_test.dart

echo "[messenger_gate_local] backend syntax check"
node --check server/src/index.js
node --check server/src/routes/chats.js
node --check server/src/utils/mailer.js
node --check server/src/utils/webPush.js

if [[ "$RUN_MACOS_ITEST" == "1" ]]; then
  echo "[messenger_gate_local] macOS integration test"
  flutter test integration_test/bootstrap_and_setup_flow_test.dart -d macos
fi

echo "[messenger_gate_local] web debug build"
flutter build web --debug --dart-define=FENIX_API_BASE_URL="$API_BASE_URL"

if [[ "$RUN_ANDROID_BUILD" == "1" ]]; then
  echo "[messenger_gate_local] android debug build"
  flutter build apk --debug --dart-define=FENIX_API_BASE_URL="$API_BASE_URL"
fi

echo "[messenger_gate_local] OK"
