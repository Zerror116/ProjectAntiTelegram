CREATE TABLE IF NOT EXISTS auth_email_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tenant_id UUID NULL REFERENCES tenants(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('password_reset', 'magic_login')),
  token_hash TEXT NOT NULL UNIQUE,
  requested_ip TEXT NULL,
  requested_user_agent TEXT NULL,
  consumed_ip TEXT NULL,
  consumed_user_agent TEXT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_auth_email_tokens_user_kind_active
  ON auth_email_tokens(user_id, kind, expires_at DESC)
  WHERE used_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_auth_email_tokens_expires_at
  ON auth_email_tokens(expires_at);
