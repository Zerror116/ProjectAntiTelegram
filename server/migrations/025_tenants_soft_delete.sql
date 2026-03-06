-- server/migrations/025_tenants_soft_delete.sql

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_tenants_is_deleted
  ON tenants(is_deleted);

