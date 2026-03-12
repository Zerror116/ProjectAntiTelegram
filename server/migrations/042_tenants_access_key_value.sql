ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS access_key_value TEXT;

