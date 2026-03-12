ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS trusted_2fa_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS trusted_2fa_set_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_devices_user_trusted_2fa
  ON devices(user_id, trusted_2fa_until DESC);

CREATE TABLE IF NOT EXISTS user_two_factor_backup_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_two_factor_backup_codes_user_hash
  ON user_two_factor_backup_codes(user_id, code_hash);

CREATE INDEX IF NOT EXISTS idx_user_two_factor_backup_codes_user_active
  ON user_two_factor_backup_codes(user_id, used_at, created_at DESC);
