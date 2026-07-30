-- Allow the same client email to exist in different tenant scopes.
-- Login and invite flows always resolve email together with tenant context.

ALTER TABLE users
  DROP CONSTRAINT IF EXISTS users_email_key;

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_tenant_lower_email
  ON users (
    COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(email)
  )
  WHERE email IS NOT NULL;

