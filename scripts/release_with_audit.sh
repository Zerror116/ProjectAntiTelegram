#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DOMAIN="${DOMAIN:-garphoenix.com}"
RUN_BUILD_AUDIT="${RUN_BUILD_AUDIT:-0}" # 1 => rebuild web/apk in audit phase

cd "$PROJECT_ROOT"

echo "[release_with_audit] step 1/2: deploy"
RUN_HEALTH_CHECK=1 "$SCRIPT_DIR/deploy_full.sh" --no-commit "$@"

echo "[release_with_audit] step 2/2: full cluster audit"
RUN_BUILDS="$RUN_BUILD_AUDIT" RUN_REMOTE=1 DOMAIN="$DOMAIN" "$SCRIPT_DIR/full_cluster_audit.sh"

echo "[release_with_audit] done"
