const db = require('../db');

function safeJson(value, fallback = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return fallback;
  }
  return value;
}

async function logAudit({
  queryable = db,
  tenantId = null,
  actorUserId = null,
  actorRole = null,
  action,
  entityType = null,
  entityId = null,
  before = {},
  after = {},
  meta = {},
}) {
  if (!action) return;
  try {
    await queryable.query(
      `INSERT INTO audit_logs (
         tenant_id,
         actor_user_id,
         actor_role,
         action,
         entity_type,
         entity_id,
         before_data,
         after_data,
         meta,
         created_at
       )
       VALUES ($1, $2, $3, $4, NULLIF($5, ''), NULLIF($6, ''), $7::jsonb, $8::jsonb, $9::jsonb, now())`,
      [
        tenantId || null,
        actorUserId || null,
        actorRole || null,
        String(action),
        entityType || '',
        entityId ? String(entityId) : '',
        JSON.stringify(safeJson(before)),
        JSON.stringify(safeJson(after)),
        JSON.stringify(safeJson(meta)),
      ],
    );
  } catch (err) {
    console.error('audit.log failed', err);
  }
}

module.exports = {
  logAudit,
};
