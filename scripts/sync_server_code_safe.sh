#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SERVER="${SERVER:-root@89.23.99.18}"
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/opt/fenix}"
CONTROL_SOCKET="${DEPLOY_CONTROL_SOCKET:-/tmp/phoenix-safe-deploy-$(id -u)-$(echo "$SERVER" | tr '@/:' '_').sock}"
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="$CONTROL_SOCKET"
)
USE_SSHPASS="0"

if [[ -n "${SSH_PASSWORD:-}" ]]; then
  command -v sshpass >/dev/null 2>&1 || {
    echo "[sync_server_code_safe] SSH_PASSWORD is set, but sshpass is not installed." >&2
    exit 1
  }
  USE_SSHPASS="1"
  SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
fi

run_rsync() {
  if [[ "$USE_SSHPASS" == "1" ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e rsync -e "ssh ${SSH_OPTS[*]}" "$@"
  else
    rsync -e "ssh ${SSH_OPTS[*]}" "$@"
  fi
}

run_ssh() {
  if [[ "$USE_SSHPASS" == "1" ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

echo "[sync_server_code_safe] syncing code only to $SERVER:$REMOTE_PROJECT_DIR"
run_rsync -avz --delete \
  --exclude '.git' \
  --exclude '.DS_Store' \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude '.env.bak*' \
  --exclude 'uploads' \
  --exclude 'uploads.legacy*' \
  --exclude 'downloads' \
  --exclude 'downloads.legacy*' \
  "$PROJECT_ROOT/server/" "$SERVER:$REMOTE_PROJECT_DIR/server/"

echo "[sync_server_code_safe] restarting backend"
run_ssh "$SERVER" "cd '$REMOTE_PROJECT_DIR/server' && npm ci --omit=dev && systemctl restart fenix-server.service && systemctl is-active fenix-server.service"
