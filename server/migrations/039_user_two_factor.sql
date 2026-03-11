ALTER TABLE IF EXISTS users
  ADD COLUMN IF NOT EXISTS two_factor_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS two_factor_secret TEXT,
  ADD COLUMN IF NOT EXISTS two_factor_enabled_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_two_factor_enabled
  ON users(two_factor_enabled)
  WHERE two_factor_enabled = true;
