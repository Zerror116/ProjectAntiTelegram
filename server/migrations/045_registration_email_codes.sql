CREATE TABLE IF NOT EXISTS registration_email_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  requested_ip TEXT NULL,
  requested_user_agent TEXT NULL,
  attempts_count INTEGER NOT NULL DEFAULT 0,
  consumed_at TIMESTAMPTZ NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_registration_email_codes_active
  ON registration_email_codes (lower(email), expires_at DESC)
  WHERE consumed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_registration_email_codes_expires_at
  ON registration_email_codes (expires_at);
