ALTER TABLE users
  ADD COLUMN IF NOT EXISTS client_city TEXT;

CREATE INDEX IF NOT EXISTS idx_users_tenant_client_city
  ON users(tenant_id, client_city)
  WHERE client_city IS NOT NULL AND client_city <> '';
