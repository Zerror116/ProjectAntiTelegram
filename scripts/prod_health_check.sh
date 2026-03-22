#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-garphoenix.com}"

echo "[check] domain: $DOMAIN"
echo

echo "[check] /health"
curl -sS "https://$DOMAIN/health"
echo
echo

echo "[check] security headers"
curl -sI "https://$DOMAIN" | tr -d '\r' | grep -Ei '^(strict-transport-security|content-security-policy|x-frame-options|x-content-type-options|referrer-policy|permissions-policy|cross-origin-opener-policy|cross-origin-resource-policy):' || true
echo

echo "[check] certificate"
echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -dates
echo

echo "[check] web bootstrap canvaskit override"
curl -sS "https://$DOMAIN/flutter_bootstrap.js" | grep -n "canvasKitBaseUrl" || true
