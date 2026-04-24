#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SERVER_ROOT"

PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://garphoenix.com}"
export PUBLIC_BASE_URL

npm run media:sanitize
npm run perf:budget
npm run audit:self
