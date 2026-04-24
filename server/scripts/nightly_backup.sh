#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SERVER_ROOT"

read_env_value() {
  local key="$1"
  local env_file="${SERVER_ROOT}/.env"
  [[ -f "$env_file" ]] || return 0
  sed -n "s/^${key}=//p" "$env_file" | head -n 1
}

extract_database_name() {
  local database_url="$1"
  local db_name="${database_url##*/}"
  db_name="${db_name%%\?*}"
  printf '%s' "$db_name"
}

BACKUP_ROOT="${FENIX_BACKUP_ROOT:-/opt/fenix-backups}"
STORAGE_ROOT="${APP_STORAGE_ROOT:-$(read_env_value APP_STORAGE_ROOT)}"
DATABASE_URL_VALUE="${DATABASE_URL:-$(read_env_value DATABASE_URL)}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/fenix-data}"
DATABASE_URL_VALUE="${DATABASE_URL_VALUE:-postgresql://projectphoenix:projectphoenix@localhost:5432/projectphoenix}"
KEEP_DAYS="${FENIX_BACKUP_KEEP_DAYS:-7}"
TIMESTAMP="$(date +%F-%H%M%S)"
PG_DIR="$BACKUP_ROOT/postgres"
STORAGE_DIR="$BACKUP_ROOT/storage"
TMP_STORAGE_DIR="$STORAGE_DIR/.tmp-$TIMESTAMP"
FINAL_STORAGE_DIR="$STORAGE_DIR/$TIMESTAMP"
LAST_LINK="$STORAGE_DIR/latest"

mkdir -p "$PG_DIR" "$STORAGE_DIR"

echo "[nightly_backup] postgres dump -> $PG_DIR/$TIMESTAMP.dump"
DATABASE_NAME="$(extract_database_name "$DATABASE_URL_VALUE")"
if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1 && sudo -u postgres psql -d "$DATABASE_NAME" -Atqc 'select 1' >/dev/null 2>&1; then
  TMP_PG_DUMP="/tmp/fenix-postgres-$TIMESTAMP.dump"
  rm -f "$TMP_PG_DUMP"
  sudo -u postgres pg_dump --format=custom --file "$TMP_PG_DUMP" "$DATABASE_NAME"
  mv "$TMP_PG_DUMP" "$PG_DIR/$TIMESTAMP.dump"
else
  PGOPTIONS='-c row_security=off' pg_dump --format=custom --file "$PG_DIR/$TIMESTAMP.dump" "$DATABASE_URL_VALUE"
fi

echo "[nightly_backup] storage snapshot -> $FINAL_STORAGE_DIR"
mkdir -p "$TMP_STORAGE_DIR"
if [[ -L "$LAST_LINK" && -d "$(readlink "$LAST_LINK")" ]]; then
  PREVIOUS="$(readlink "$LAST_LINK")"
  rsync -a --delete --link-dest="$PREVIOUS" "$STORAGE_ROOT/" "$TMP_STORAGE_DIR/"
else
  rsync -a --delete "$STORAGE_ROOT/" "$TMP_STORAGE_DIR/"
fi
mv "$TMP_STORAGE_DIR" "$FINAL_STORAGE_DIR"
ln -sfn "$FINAL_STORAGE_DIR" "$LAST_LINK"

echo "[nightly_backup] retention keep_days=$KEEP_DAYS"
find "$PG_DIR" -type f -name '*.dump' -mtime "+$KEEP_DAYS" -delete || true
find "$STORAGE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP_DAYS" -exec rm -rf {} + || true

echo "[nightly_backup] done"
