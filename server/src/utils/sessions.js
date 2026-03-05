const crypto = require('crypto');
const db = require('../db');

function hashSessionId(sessionId) {
  return crypto
    .createHash('sha256')
    .update(String(sessionId || ''))
    .digest('hex');
}

function getBearerToken(authHeader) {
  const value = String(authHeader || '').trim();
  if (!value) return null;
  if (value.toLowerCase().startsWith('bearer ')) {
    const token = value.slice(7).trim();
    return token || null;
  }
  return null;
}

async function createUserSession({
  queryable = db,
  userId,
  sessionId,
  deviceFingerprint = null,
  userAgent = null,
  ipAddress = null,
  expiresAt = null,
}) {
  if (!userId || !sessionId) return null;
  const hash = hashSessionId(sessionId);
  const result = await queryable.query(
    `INSERT INTO user_sessions (
       id,
       user_id,
       session_token_hash,
       device_fingerprint,
       user_agent,
       ip_address,
       is_active,
       last_seen_at,
       expires_at,
       created_at
     )
     VALUES (
       gen_random_uuid(),
       $1,
       $2,
       NULLIF($3, ''),
       NULLIF($4, ''),
       NULLIF($5, ''),
       true,
       now(),
       $6,
       now()
     )
     RETURNING id, user_id, created_at`,
    [
      userId,
      hash,
      String(deviceFingerprint || '').trim(),
      String(userAgent || '').trim(),
      String(ipAddress || '').trim(),
      expiresAt || null,
    ],
  );
  return result.rows[0] || null;
}

async function touchUserSession({ queryable = db, sessionId }) {
  if (!sessionId) return false;
  const hash = hashSessionId(sessionId);
  const result = await queryable.query(
    `UPDATE user_sessions
     SET last_seen_at = now()
     WHERE session_token_hash = $1
       AND is_active = true
       AND (expires_at IS NULL OR expires_at > now())
     RETURNING id`,
    [hash],
  );
  return result.rowCount > 0;
}

async function revokeUserSession({ queryable = db, sessionId }) {
  if (!sessionId) return false;
  const hash = hashSessionId(sessionId);
  const result = await queryable.query(
    `UPDATE user_sessions
     SET is_active = false
     WHERE session_token_hash = $1
       AND is_active = true
     RETURNING id`,
    [hash],
  );
  return result.rowCount > 0;
}

async function revokeOtherUserSessions({ queryable = db, userId, sessionId }) {
  if (!userId) return 0;
  const hash = sessionId ? hashSessionId(sessionId) : null;
  const result = await queryable.query(
    `UPDATE user_sessions
     SET is_active = false
     WHERE user_id = $1
       AND is_active = true
       AND ($2::text IS NULL OR session_token_hash <> $2)
     RETURNING id`,
    [userId, hash],
  );
  return result.rowCount || 0;
}

async function revokeSessionByRecordId({
  queryable = db,
  userId,
  sessionRecordId,
}) {
  if (!userId || !sessionRecordId) return false;
  const result = await queryable.query(
    `UPDATE user_sessions
     SET is_active = false
     WHERE id = $1
       AND user_id = $2
       AND is_active = true
     RETURNING id`,
    [sessionRecordId, userId],
  );
  return result.rowCount > 0;
}

async function listUserSessions({ queryable = db, userId, currentSessionId = null }) {
  if (!userId) return [];
  const currentHash = currentSessionId ? hashSessionId(currentSessionId) : null;
  const result = await queryable.query(
    `SELECT id,
            user_id,
            device_fingerprint,
            user_agent,
            ip_address,
            is_active,
            last_seen_at,
            expires_at,
            created_at,
            (session_token_hash = $2) AS is_current
     FROM user_sessions
     WHERE user_id = $1
     ORDER BY last_seen_at DESC, created_at DESC
     LIMIT 30`,
    [userId, currentHash],
  );
  return result.rows;
}

module.exports = {
  hashSessionId,
  getBearerToken,
  createUserSession,
  touchUserSession,
  revokeUserSession,
  revokeSessionByRecordId,
  revokeOtherUserSessions,
  listUserSessions,
};
