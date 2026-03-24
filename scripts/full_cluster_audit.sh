#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DOMAIN="${DOMAIN:-garphoenix.com}"
SERVER="${SERVER:-root@89.23.99.18}"
RUN_BUILDS="${RUN_BUILDS:-0}" # 1 => include flutter build web/apk
RUN_REMOTE="${RUN_REMOTE:-1}" # 0 => skip SSH part

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

  print_section "Local Node Syntax + Security Audit"
  cd "$PROJECT_ROOT/server"
  find src -type f -name "*.js" -print0 | xargs -0 -n1 node --check
  npm audit --omit=dev
  npm run audit:self
}

run_prod_http_checks() {
  print_section "Production HTTP/TLS Health"
  cd "$PROJECT_ROOT"
  bash "$SCRIPT_DIR/prod_health_check.sh" "$DOMAIN"
}

run_remote_checks() {
  if [[ "$RUN_REMOTE" != "1" ]]; then
    print_section "Remote Checks Skipped"
    echo "RUN_REMOTE=0, skip SSH checks"
    return
  fi

  if ! command -v sshpass >/dev/null 2>&1; then
    print_section "Remote Checks Skipped"
    echo "sshpass not found; install it to run remote checks"
    return
  fi

  if [[ -z "${SSH_PASSWORD:-}" ]]; then
    print_section "Remote Checks Skipped"
    echo "Set SSH_PASSWORD env to run remote checks"
    return
  fi

  print_section "Remote Service + Nginx Audit"
  SSHPASS="$SSH_PASSWORD" sshpass -e ssh \
    -o ConnectTimeout=10 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    "$SERVER" '
      set -euo pipefail
      hostname
      echo
      echo "== fenix-server.service =="
      systemctl is-active fenix-server.service || true
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
    '
}

main() {
  print_section "Cluster Audit Start"
  echo "project: $PROJECT_ROOT"
  echo "domain:  $DOMAIN"
  echo "server:  $SERVER"

  run_local_checks
  run_prod_http_checks
  run_remote_checks

  print_section "Cluster Audit Completed"
  echo "All configured checks completed successfully."
}

main "$@"

