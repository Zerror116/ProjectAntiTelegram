#!/bin/zsh
set -euo pipefail

ROOT_URL="${1:-https://garphoenix.com}"
PAYLOAD_FILE="/Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/safari_cache_recovery_payload.js"
TMP_SCRIPT="/tmp/phoenix-safari-recovery.applescript"
INJECT_FILE="/tmp/phoenix-safari-recovery.inject.js"

python3 - <<'PY' "$INJECT_FILE"
from pathlib import Path
import json, subprocess, sys
out_path = Path(sys.argv[1])
script = [
    '-e', 'tell application "Safari"',
    '-e', 'set js to "localStorage.getItem(\\"flutter.saved_tenant_sessions_v1\\")"',
    '-e', 'return do JavaScript js in current tab of front window',
    '-e', 'end tell',
]
out = subprocess.check_output(['osascript', *script]).decode('utf-8', 'ignore').strip()
raw = json.loads(out)
sessions = json.loads(raw) if raw else []
sessions = [s for s in sessions if isinstance(s, dict) and (s.get('token') or s.get('refresh_token'))]
sessions.sort(key=lambda s: s.get('updated_at') or '', reverse=True)
session = sessions[0] if sessions else {}
js = f"window.__phoenixInjectedToken = {json.dumps(session.get('token',''))};\nwindow.__phoenixInjectedRefreshToken = {json.dumps(session.get('refresh_token',''))};\n"
out_path.write_text(js)
PY

python3 - <<'PY' "$PAYLOAD_FILE" "$ROOT_URL" "$TMP_SCRIPT" "$INJECT_FILE"
from pathlib import Path
import json, sys
payload_path = Path(sys.argv[1])
root_url = sys.argv[2]
out_path = Path(sys.argv[3])
inject_path = Path(sys.argv[4])
script = f'''
set targetUrl to {json.dumps(root_url)}
set injectJs to read POSIX file {json.dumps(str(inject_path))}
set jsPayload to read POSIX file {json.dumps(str(payload_path))}
tell application "Safari"
  activate
  if (count of documents) = 0 then
    make new document with properties {{URL:targetUrl}}
    delay 2
  else
    set URL of front document to targetUrl
    delay 2
  end if
  do JavaScript injectJs in current tab of front window
  do JavaScript jsPayload in current tab of front window
end tell
'''
out_path.write_text(script)
PY

osascript "$TMP_SCRIPT"

for attempt in {1..40}; do
  result=$(osascript -e 'tell application "Safari" to do JavaScript "JSON.stringify(window.__phoenixRecoveryState || null)" in current tab of front window' 2>/dev/null || true)
  if [[ -n "$result" && "$result" != "null" ]]; then
    echo "$result"
    if [[ "$result" == *'"status":"done"'* || "$result" == *'"status":"error"'* ]]; then
      exit 0
    fi
  fi
  sleep 3
done

echo '{"status":"timeout"}'
