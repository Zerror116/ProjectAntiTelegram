const db = require('../db');

function normalizeLevel(value) {
  const level = String(value || 'info').toLowerCase().trim();
  if (['info', 'warn', 'error', 'critical'].includes(level)) {
    return level;
  }
  return 'info';
}

function normalizeScope(value) {
  const scope = String(value || 'server').trim();
  return scope || 'server';
}

function normalizeJson(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }
  return value;
}

async function logMonitoringEvent({
  queryable = db,
  tenantId = null,
  userId = null,
  scope = 'server',
  level = 'info',
  code = null,
  message,
  source = null,
  details = {},
}) {
  const normalizedMessage = String(message || '').trim();
  if (!normalizedMessage) return null;

  try {
    const result = await queryable.query(
      `INSERT INTO monitoring_events (
         id,
         tenant_id,
         user_id,
         scope,
         level,
         code,
         message,
         source,
         details,
         resolved,
         created_at
       )
       VALUES (
         gen_random_uuid(),
         $1,
         $2,
         $3,
         $4,
         NULLIF($5, ''),
         $6,
         NULLIF($7, ''),
         $8::jsonb,
         false,
         now()
       )
       RETURNING id`,
      [
        tenantId || null,
        userId || null,
        normalizeScope(scope),
        normalizeLevel(level),
        String(code || '').trim(),
        normalizedMessage,
        String(source || '').trim(),
        JSON.stringify(normalizeJson(details)),
      ],
    );
    return result.rows[0]?.id || null;
  } catch (err) {
    // Monitoring must never crash business flow.
    try {
      console.error('monitoring.log insert error', err?.message || err);
    } catch (_) {}
    return null;
  }
}

module.exports = {
  logMonitoringEvent,
  normalizeLevel,
};
