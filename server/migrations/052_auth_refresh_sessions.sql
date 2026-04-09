ALTER TABLE user_sessions
  ADD COLUMN IF NOT EXISTS session_public_id TEXT;

ALTER TABLE user_sessions
  ADD COLUMN IF NOT EXISTS refresh_token_hash TEXT;

ALTER TABLE user_sessions
  ADD COLUMN IF NOT EXISTS refresh_last_used_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_sessions_session_public_id
ON user_sessions(session_public_id)
WHERE session_public_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_sessions_refresh_token_hash
ON user_sessions(refresh_token_hash)
WHERE refresh_token_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_sessions_refresh_last_used
ON user_sessions(refresh_last_used_at DESC)
WHERE refresh_token_hash IS NOT NULL;
