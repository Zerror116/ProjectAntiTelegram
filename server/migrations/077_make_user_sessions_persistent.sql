-- Active sessions should not expire automatically. Users leave accounts only
-- through explicit logout or administrative session revocation.

UPDATE user_sessions
SET expires_at = NULL
WHERE is_active = true
  AND expires_at IS NOT NULL;
