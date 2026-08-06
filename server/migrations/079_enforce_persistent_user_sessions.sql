-- User sessions are persistent by product rule: users stay signed in until
-- explicit logout or administrative session revocation.

UPDATE user_sessions
SET expires_at = NULL
WHERE is_active = true
  AND expires_at IS NOT NULL;
