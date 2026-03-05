-- server/migrations/021_tenants_licensing.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  access_key_hash TEXT UNIQUE NOT NULL,
  access_key_mask TEXT,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'blocked')),
  subscription_expires_at TIMESTAMPTZ NOT NULL,
  last_payment_confirmed_at TIMESTAMPTZ,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS tenant_id UUID;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.table_constraints
    WHERE constraint_name = 'fk_users_tenant_id'
      AND table_name = 'users'
  ) THEN
    ALTER TABLE users
      ADD CONSTRAINT fk_users_tenant_id
      FOREIGN KEY (tenant_id)
      REFERENCES tenants(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_tenant_id ON users(tenant_id);

ALTER TABLE chats
  ADD COLUMN IF NOT EXISTS tenant_id UUID;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.table_constraints
    WHERE constraint_name = 'fk_chats_tenant_id'
      AND table_name = 'chats'
  ) THEN
    ALTER TABLE chats
      ADD CONSTRAINT fk_chats_tenant_id
      FOREIGN KEY (tenant_id)
      REFERENCES tenants(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_chats_tenant_id ON chats(tenant_id);

-- Базовый арендатор для текущих данных
INSERT INTO tenants (
  code,
  name,
  access_key_hash,
  access_key_mask,
  status,
  subscription_expires_at,
  last_payment_confirmed_at
)
VALUES (
  'default',
  'Default Tenant',
  encode(digest('PHOENIX-DEFAULT-KEY', 'sha256'), 'hex'),
  'PHOENIX-****-****-KEY',
  'active',
  now() + interval '120 months',
  now()
)
ON CONFLICT (code) DO NOTHING;

WITH default_tenant AS (
  SELECT id
  FROM tenants
  WHERE code = 'default'
  LIMIT 1
)
UPDATE users u
SET tenant_id = dt.id
FROM default_tenant dt
WHERE u.tenant_id IS NULL;

WITH default_tenant AS (
  SELECT id
  FROM tenants
  WHERE code = 'default'
  LIMIT 1
)
UPDATE chats c
SET tenant_id = u.tenant_id
FROM users u
WHERE c.tenant_id IS NULL
  AND c.created_by = u.id
  AND u.tenant_id IS NOT NULL;

WITH default_tenant AS (
  SELECT id
  FROM tenants
  WHERE code = 'default'
  LIMIT 1
)
UPDATE chats c
SET tenant_id = dt.id
FROM default_tenant dt
WHERE c.tenant_id IS NULL;
