-- server/migrations/024_tenant_database_routing.sql

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS db_mode TEXT NOT NULL DEFAULT 'shared'
  CHECK (db_mode IN ('shared', 'isolated'));

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS db_name TEXT;

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS db_url TEXT;

CREATE INDEX IF NOT EXISTS idx_tenants_db_mode
  ON tenants(db_mode);

CREATE INDEX IF NOT EXISTS idx_tenants_db_name
  ON tenants(db_name)
  WHERE db_name IS NOT NULL;

UPDATE tenants
SET db_mode = 'shared'
WHERE db_mode IS NULL
   OR db_mode NOT IN ('shared', 'isolated');

UPDATE tenants
SET db_name = COALESCE(NULLIF(db_name, ''), current_database())
WHERE code = 'default';
