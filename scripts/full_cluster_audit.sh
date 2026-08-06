#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DOMAIN="${DOMAIN:-garphoenix.com}"
SERVER="${SERVER:-root@89.23.99.18}"
RUN_BUILDS="${RUN_BUILDS:-0}" # 1 => include flutter build web/apk
RUN_E2E="${RUN_E2E:-0}" # 1 => include backend full E2E regression
RUN_REMOTE="${RUN_REMOTE:-1}" # 0 => skip SSH part
RUN_GITHUB_ACTIONS="${RUN_GITHUB_ACTIONS:-0}" # 1 => require latest Security CI run to pass for current HEAD

print_section() {
  printf "\n===== %s =====\n" "$1"
}

run_local_checks() {
  print_section "Local Flutter Analyze"
  cd "$PROJECT_ROOT"
  flutter analyze

  print_section "Local Flutter Tests"
  flutter test

  if [[ "$RUN_BUILDS" == "1" ]]; then
    print_section "Local Flutter Web Build"
    flutter build web --release --no-wasm-dry-run

    print_section "Local Flutter APK Build"
    flutter build apk --release
  else
    print_section "Builds Skipped"
    echo "RUN_BUILDS=0, skip flutter build web/apk"
  fi

  print_section "Local Node Syntax + Business Guards + Security Audit"
  cd "$PROJECT_ROOT/server"
  find src scripts -type f -name "*.js" -print0 | xargs -0 -n1 node --check
  npm run test:business:settings
  npm run lint
  npm audit --omit=dev --audit-level=high
  npm run audit:gate
  npm run audit:self

  if [[ "$RUN_E2E" == "1" ]]; then
    print_section "Local Backend Full E2E Regression"
    E2E_REQUIRE_FULL="${E2E_REQUIRE_FULL:-1}" npm run test:e2e:full
  else
    print_section "Backend Full E2E Skipped"
    echo "RUN_E2E=0, skip backend full E2E regression"
  fi
}

run_prod_http_checks() {
  print_section "Production HTTP/TLS Health"
  cd "$PROJECT_ROOT"
  bash "$SCRIPT_DIR/prod_health_check.sh" "$DOMAIN"
}

run_github_actions_checks() {
  if [[ "$RUN_GITHUB_ACTIONS" != "1" ]]; then
    print_section "GitHub Actions Health Skipped"
    echo "RUN_GITHUB_ACTIONS=0, skip GitHub Actions status check"
    return
  fi

  print_section "GitHub Actions Health"
  cd "$PROJECT_ROOT"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  node "$SCRIPT_DIR/github_actions_health_check.js" \
    --workflow "Security CI" \
    --branch "$branch" \
    --require-current-head
}

run_remote_checks() {
  if [[ "$RUN_REMOTE" != "1" ]]; then
    print_section "Remote Checks Skipped"
    echo "RUN_REMOTE=0, skip SSH checks"
    return
  fi

  print_section "Remote Service + Nginx Audit"
  local ssh_cmd=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no)
  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "SSH_PASSWORD is set, but sshpass is not installed" >&2
      return 1
    fi
    ssh_cmd=(sshpass -e ssh -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no)
  else
    ssh_cmd+=( -o BatchMode=yes )
  fi

  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    SSHPASS="$SSH_PASSWORD" "${ssh_cmd[@]}" "$SERVER" '
      set -euo pipefail
      hostname
      echo
      echo "== fenix-server.service =="
      systemctl is-active fenix-server.service || true
      echo
      echo "== fenix-worker.service =="
      systemctl is-active fenix-worker.service || true
      echo
      echo "== nginx.service =="
      systemctl is-active nginx.service || true
      systemctl status fenix-server.service --no-pager -l | sed -n "1,60p"
      echo
      echo "== listeners :3000 =="
      ss -ltnp | grep ":3000" || true
      echo
      echo "== nginx -t =="
      nginx -t
      echo
      echo "== suspicious web files =="
      find /var/www/garphoenix.com -maxdepth 3 \( -name ".DS_Store" -o -name ".env" \) -print
      echo
      echo "== deployed server revision =="
      cd /opt/fenix/server
      git rev-parse --short HEAD
      node -v
      npm -v
      echo
      echo "== address provider config =="
      node - <<'"'"'NODE'"'"'
require("dotenv").config();
const configured = Boolean(
  process.env.DELIVERY_ADDRESS_SUGGEST_URL ||
  process.env.PHOTON_SEARCH_URL ||
  String(process.env.DELIVERY_ADDRESS_PROVIDER || "").toLowerCase() === "nominatim"
);
const reverseConfigured = Boolean(
  process.env.DELIVERY_ADDRESS_REVERSE_URL ||
  process.env.PHOTON_REVERSE_URL ||
  String(process.env.DELIVERY_ADDRESS_PROVIDER || "").toLowerCase() === "nominatim"
);
console.log(JSON.stringify({
  provider: process.env.DELIVERY_ADDRESS_PROVIDER || "photon",
  suggest_configured: configured,
  reverse_configured: reverseConfigured
}));
if (!configured || !reverseConfigured) process.exit(2);
NODE
      echo
      echo "== production self-audit =="
      NODE_ENV=production npm run audit:self
      if [ -f audit/nightly-self-audit.md ]; then
        grep -nE "Findings:|tenant_features|backup|android.release|monitoring.unresolved|notifications.queue|critical|warn" audit/nightly-self-audit.md | head -100 || true
      fi
    '
  else
    "${ssh_cmd[@]}" "$SERVER" '
      set -euo pipefail
      hostname
      echo
      echo "== fenix-server.service =="
      systemctl is-active fenix-server.service || true
      echo
      echo "== fenix-worker.service =="
      systemctl is-active fenix-worker.service || true
      echo
      echo "== nginx.service =="
      systemctl is-active nginx.service || true
      systemctl status fenix-server.service --no-pager -l | sed -n "1,60p"
      echo
      echo "== listeners :3000 =="
      ss -ltnp | grep ":3000" || true
      echo
      echo "== nginx -t =="
      nginx -t
      echo
      echo "== suspicious web files =="
      find /var/www/garphoenix.com -maxdepth 3 \( -name ".DS_Store" -o -name ".env" \) -print
      echo
      echo "== deployed server revision =="
      cd /opt/fenix/server
      git rev-parse --short HEAD
      node -v
      npm -v
      echo
      echo "== address provider config =="
      node - <<'"'"'NODE'"'"'
require("dotenv").config();
const configured = Boolean(
  process.env.DELIVERY_ADDRESS_SUGGEST_URL ||
  process.env.PHOTON_SEARCH_URL ||
  String(process.env.DELIVERY_ADDRESS_PROVIDER || "").toLowerCase() === "nominatim"
);
const reverseConfigured = Boolean(
  process.env.DELIVERY_ADDRESS_REVERSE_URL ||
  process.env.PHOTON_REVERSE_URL ||
  String(process.env.DELIVERY_ADDRESS_PROVIDER || "").toLowerCase() === "nominatim"
);
console.log(JSON.stringify({
  provider: process.env.DELIVERY_ADDRESS_PROVIDER || "photon",
  suggest_configured: configured,
  reverse_configured: reverseConfigured
}));
if (!configured || !reverseConfigured) process.exit(2);
NODE
      echo
      echo "== production self-audit =="
      NODE_ENV=production npm run audit:self
      if [ -f audit/nightly-self-audit.md ]; then
        grep -nE "Findings:|tenant_features|backup|android.release|monitoring.unresolved|notifications.queue|critical|warn" audit/nightly-self-audit.md | head -100 || true
      fi
    '
  fi
}

main() {
  print_section "Cluster Audit Start"
  echo "project: $PROJECT_ROOT"
  echo "domain:  $DOMAIN"
  echo "server:  $SERVER"
  echo "run_e2e: $RUN_E2E"
  echo "github_actions: $RUN_GITHUB_ACTIONS"

  run_local_checks
  run_github_actions_checks
  run_prod_http_checks
  run_remote_checks

  print_section "Cluster Audit Completed"
  echo "All configured checks completed successfully."
}

main "$@"
