CREATE TABLE IF NOT EXISTS tenant_user_index (
  tenant_id UUID NOT NULL,
  user_id UUID NOT NULL,
  email TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'client',
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_user_index_tenant_email
  ON tenant_user_index (tenant_id, lower(email));

CREATE INDEX IF NOT EXISTS idx_tenant_user_index_email
  ON tenant_user_index (lower(email));

DO $$
BEGIN
  IF to_regclass('public.users') IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO tenant_user_index (
    tenant_id,
    user_id,
    email,
    role,
    is_active,
    created_at,
    updated_at
  )
  SELECT u.tenant_id,
         u.id,
         lower(u.email),
         COALESCE(NULLIF(BTRIM(u.role), ''), 'client'),
         COALESCE(u.is_active, true),
         COALESCE(u.created_at, now()),
         now()
  FROM users u
  WHERE u.tenant_id IS NOT NULL
    AND NULLIF(BTRIM(u.email), '') IS NOT NULL
  ON CONFLICT (tenant_id, user_id) DO UPDATE
  SET email = EXCLUDED.email,
      role = EXCLUDED.role,
      is_active = EXCLUDED.is_active,
      updated_at = now();
END$$;
