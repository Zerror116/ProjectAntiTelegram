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

function normalizeSubsystem(value) {
  const subsystem = String(value || 'general').toLowerCase().trim();
  return subsystem || 'general';
}

function normalizeJson(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }
  return value;
}

function truncateString(value, limit = 1200) {
  const text = String(value || '');
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}…`;
}

function redactString(value) {
  let text = truncateString(value, 4000);
  text = text.replace(/Bearer\s+[A-Za-z0-9._-]+/gi, 'Bearer [redacted]');
  text = text.replace(/("?(authorization|refresh_token|token|subscription_key)"?\s*[:=]\s*")([^"]+)(")/gi, '$1[redacted]$4');
  text = text.replace(/([A-Z0-9._%+-]+)@([A-Z0-9.-]+\.[A-Z]{2,})/gi, '[redacted-email]');
  text = text.replace(/\+?\d[\d\s().-]{8,}\d/g, '[redacted-phone]');
  return text;
}

function sanitizeDetails(value, depth = 0) {
  if (depth > 4) return '[trimmed-depth]';
  if (value == null) return null;
  if (typeof value === 'string') return redactString(value);
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) {
    return value.slice(0, 25).map((item) => sanitizeDetails(item, depth + 1));
  }
  if (typeof value === 'object') {
    const out = {};
    for (const [rawKey, rawValue] of Object.entries(value)) {
      const key = String(rawKey || '').trim();
      if (!key) continue;
      if (/(authorization|refresh[_-]?token|access[_-]?token|push[_-]?token|subscription[_-]?key)/i.test(key)) {
        out[key] = '[redacted]';
        continue;
      }
      out[key] = sanitizeDetails(rawValue, depth + 1);
    }
    return out;
  }
  return truncateString(String(value), 500);
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
  subsystem = 'general',
  platform = null,
  appVersion = null,
  appBuild = null,
  userRole = null,
  tenantCode = null,
  deviceLabel = null,
  releaseChannel = null,
  sessionState = null,
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
         subsystem,
         platform,
         app_version,
         app_build,
         user_role,
         tenant_code,
         device_label,
         release_channel,
         session_state,
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
         NULLIF($9, ''),
         NULLIF($10, ''),
         NULLIF($11, ''),
         $12,
         NULLIF($13, ''),
         NULLIF($14, ''),
         NULLIF($15, ''),
         NULLIF($16, ''),
         NULLIF($17, ''),
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
        redactString(normalizedMessage),
        redactString(String(source || '').trim()),
        JSON.stringify(sanitizeDetails(normalizeJson(details))),
        normalizeSubsystem(subsystem),
        String(platform || '').trim(),
        String(appVersion || '').trim(),
        Number.isFinite(Number(appBuild)) ? Number(appBuild) : null,
        String(userRole || '').trim(),
        String(tenantCode || '').trim(),
        String(deviceLabel || '').trim(),
        String(releaseChannel || '').trim(),
        String(sessionState || '').trim(),
      ],
    );
    return result.rows[0]?.id || null;
  } catch (err) {
    try {
      console.error('monitoring.log insert error', err?.message || err);
    } catch (_) {}
    return null;
  }
}

async function logReleaseCheck({
  queryable = db,
  tenantId = null,
  createdBy = null,
  scope = 'manual',
  status = 'pass',
  title,
  target = null,
  versionName = null,
  buildNumber = null,
  summary = null,
  details = {},
}) {
  const normalizedTitle = String(title || '').trim();
  if (!normalizedTitle) return null;
  const normalizedStatus = ['pass', 'warn', 'fail'].includes(String(status || '').trim())
    ? String(status || '').trim()
    : 'warn';
  const normalizedScope = ['deploy', 'android_release', 'after_deploy_smoke', 'nightly_audit', 'manual'].includes(String(scope || '').trim())
    ? String(scope || '').trim()
    : 'manual';

  try {
    const result = await queryable.query(
      `INSERT INTO ops_release_checks (
         id,
         tenant_id,
         created_by,
         scope,
         status,
         title,
         target,
         version_name,
         build_number,
         summary,
         details,
         created_at
       )
       VALUES (
         gen_random_uuid(),
         $1,
         $2,
         $3,
         $4,
         $5,
         NULLIF($6, ''),
         NULLIF($7, ''),
         $8,
         NULLIF($9, ''),
         $10::jsonb,
         now()
       )
       RETURNING id`,
      [
        tenantId || null,
        createdBy || null,
        normalizedScope,
        normalizedStatus,
        normalizedTitle,
        String(target || '').trim(),
        String(versionName || '').trim(),
        Number.isFinite(Number(buildNumber)) ? Number(buildNumber) : null,
        String(summary || '').trim(),
        JSON.stringify(sanitizeDetails(normalizeJson(details))),
      ],
    );

    if (normalizedStatus !== 'pass') {
      await logMonitoringEvent({
        queryable,
        tenantId,
        userId: createdBy,
        scope: 'release',
        subsystem: normalizedScope,
        level: normalizedStatus === 'fail' ? 'error' : 'warn',
        code: `release_${normalizedScope}_${normalizedStatus}`,
        message: normalizedTitle,
        source: target || normalizedScope,
        details: {
          version_name: versionName || null,
          build_number: buildNumber || null,
          summary: summary || null,
          ...sanitizeDetails(details),
        },
      });
    }

    return result.rows[0]?.id || null;
  } catch (err) {
    try {
      console.error('monitoring.release insert error', err?.message || err);
    } catch (_) {}
    return null;
  }
}

module.exports = {
  logMonitoringEvent,
  logReleaseCheck,
  normalizeLevel,
  normalizeSubsystem,
  sanitizeDetails,
};
