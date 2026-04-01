// server/src/routes/auth.js
const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const validator = require('validator');
const { v4: uuidv4 } = require('uuid');
const db = require('../db'); // предполагается, что db экспортирует функцию query
const { authMiddleware } = require('../utils/auth');
const { signJwt } = require('../utils/jwt');
const {
  PLATFORM_CREATOR_EMAIL,
  normalizeAccessKey,
  normalizeInviteCode,
  generateInviteCode,
  hashAccessKey,
  isTenantActive,
  isTenantAccessKey,
} = require('../utils/tenants');
const {
  createUserSession,
  listUserSessions,
  revokeOtherUserSessions,
  revokeSessionByRecordId,
  revokeUserSession,
} = require('../utils/sessions');
const {
  normalizePhoneDigits,
  findOldestPhoneOwner,
  createPhoneAccessRequest,
  rebalancePendingPhoneRequestOwners,
  resolvePhoneAccessState,
  listPendingPhoneAccessRequestsForOwner,
  decidePhoneAccessRequest,
} = require('../utils/phoneAccess');
const {
  isTwoFactorEligibleRole,
  normalizeTotpCode,
  generateTwoFactorSetup,
  verifyTwoFactorCode,
  encryptTwoFactorSecret,
  decryptTwoFactorSecret,
  normalizeBackupCode,
  hashBackupCode,
  generateBackupCodes,
} = require('../utils/twoFactor');
const { isMailConfigured, sendMail } = require('../utils/mailer');
const { ensureSystemChannels } = require("../utils/systemChannels");
require('dotenv').config();
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

// Настройки для Creator
const CREATOR_EMAIL = PLATFORM_CREATOR_EMAIL;
const CREATOR_SECRET = String(process.env.CREATOR_SECRET || '').trim();
const CREATOR_SECRET_HASH = String(process.env.CREATOR_SECRET_HASH || '')
  .trim()
  .toLowerCase();
const MAX_ACCOUNTS_PER_DEVICE = 2;
const TRUST_DEVICE_2FA_DAYS = 30;
const BACKUP_CODES_DEFAULT_COUNT = 10;
const MAGIC_LINK_TTL_MINUTES = Math.max(
  5,
  Math.min(Number(process.env.AUTH_MAGIC_LINK_TTL_MINUTES || 15) || 15, 60),
);
const PASSWORD_RESET_TTL_MINUTES = Math.max(
  5,
  Math.min(Number(process.env.AUTH_PASSWORD_RESET_TTL_MINUTES || 15) || 15, 60),
);

if (
  process.env.NODE_ENV === 'production' &&
  !CREATOR_SECRET &&
  !CREATOR_SECRET_HASH
) {
  throw new Error(
    'CREATOR_SECRET or CREATOR_SECRET_HASH must be configured in production',
  );
}

function signToken(payload) {
  return signJwt(payload, { expiresIn: '7d' });
}

function buildSessionExpiry() {
  return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
}

function constantTimeEquals(leftValue, rightValue) {
  const left = Buffer.from(String(leftValue || ''), 'utf8');
  const right = Buffer.from(String(rightValue || ''), 'utf8');
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

function sha256Hex(value) {
  return crypto
    .createHash('sha256')
    .update(String(value || ''), 'utf8')
    .digest('hex')
    .toLowerCase();
}

function isValidCreatorSecret(inputSecret) {
  if (CREATOR_SECRET_HASH) {
    const inputHash = sha256Hex(inputSecret);
    return constantTimeEquals(inputHash, CREATOR_SECRET_HASH);
  }
  if (!CREATOR_SECRET) return false;
  return constantTimeEquals(inputSecret, CREATOR_SECRET);
}

function requireTenantOrCreator(req, res, next) {
  const role = String(req.user?.role || "")
    .toLowerCase()
    .trim();
  const baseRole = String(req.user?.base_role || "")
    .toLowerCase()
    .trim();
  const allowed =
    role === "tenant" ||
    role === "creator" ||
    baseRole === "tenant" ||
    baseRole === "creator";
  if (!allowed) {
    return res.status(403).json({
      ok: false,
      error: "Доступ к сессиям разрешён только арендатору и создателю",
    });
  }
  return next();
}

function requireTwoFactorEligible(req, res, next) {
  if (!isTwoFactorEligibleRole(req.user)) {
    return res.status(403).json({
      ok: false,
      error: '2FA доступна только для admin/tenant/creator',
    });
  }
  return next();
}

function normalizeDeviceFingerprint(value) {
  const normalized = String(value || '').trim();
  return normalized ? normalized.slice(0, 255) : null;
}

function ensureDeviceFingerprint(value) {
  const normalized = normalizeDeviceFingerprint(value);
  if (!normalized) {
    const error = new Error(
      'Для регистрации требуется отпечаток устройства. Обновите приложение и повторите попытку.',
    );
    error.statusCode = 400;
    throw error;
  }
  return normalized;
}

function parseBooleanFlag(raw) {
  if (raw === true || raw === false) return raw;
  if (raw === 1 || raw === "1") return true;
  if (raw === 0 || raw === "0") return false;
  const normalized = String(raw || "")
    .toLowerCase()
    .trim();
  return normalized === "true" || normalized === "yes" || normalized === "y";
}

function maskDeviceFingerprint(raw) {
  const value = String(raw || "").trim();
  if (!value) return "unknown";
  if (value.length <= 10) return value;
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function decodeTenantCodeHeaderValue(raw) {
  const value = String(raw || '').trim();
  if (!value) return '';
  try {
    return decodeURIComponent(value);
  } catch (_) {
    return value;
  }
}

function extractTenantCodeHint(req) {
  const fromHeader = decodeTenantCodeHeaderValue(req.get('x-tenant-code'));
  if (fromHeader) return db.normalizeTenantCode(fromHeader);

  const fromBody = String(req.body?.tenant_code || '').trim();
  if (fromBody) return db.normalizeTenantCode(fromBody);

  const fromQuery = String(req.query?.tenant || req.query?.tenant_code || '').trim();
  if (fromQuery) return db.normalizeTenantCode(fromQuery);

  return '';
}

function buildInviteLink(req, inviteCode, tenantCode = '') {
  const base = String(process.env.INVITE_LINK_BASE || '').trim();
  const encodedInvite = encodeURIComponent(String(inviteCode || '').trim());
  const encodedTenant = encodeURIComponent(String(tenantCode || '').trim());
  const tenantPart = encodedTenant ? `&tenant=${encodedTenant}` : '';
  if (base) {
    const glue = base.includes('?') ? '&' : '?';
    return `${base}${glue}invite=${encodedInvite}${tenantPart}`;
  }
  return `${req.protocol}://${req.get('host')}/?invite=${encodedInvite}${tenantPart}`;
}

function normalizeTenantGroupName(raw) {
  return String(raw || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

function normalizeMainChannelTitle(raw) {
  return String(raw || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

async function assertDeviceAccountLimit(
  queryable,
  deviceFingerprint,
  userId = null,
  tenantId = null,
) {
  const fingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  if (!fingerprint) return;

  const usage = await queryable.query(
    `SELECT d.user_id::text AS user_id
     FROM devices d
     JOIN users u ON u.id = d.user_id
     WHERE d.device_fingerprint = $1
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
     GROUP BY d.user_id`,
    [fingerprint, tenantId || null],
  );
  const userIds = usage.rows
    .map((row) => String(row.user_id || '').trim())
    .filter(Boolean);
  const uniqueUsers = new Set(userIds);
  if (userId) uniqueUsers.delete(String(userId));
  if (uniqueUsers.size >= MAX_ACCOUNTS_PER_DEVICE) {
    const error = new Error('На одном устройстве можно использовать максимум 2 аккаунта');
    error.statusCode = 403;
    throw error;
  }
}

async function upsertDevice(queryable, userId, deviceFingerprint) {
  const fingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  if (!userId || !fingerprint) return null;
  const result = await queryable.query(
    `INSERT INTO devices (
       id,
       user_id,
       device_fingerprint,
       trusted,
       created_at,
       last_seen
     )
     VALUES (gen_random_uuid(), $1, $2, true, now(), now())
     ON CONFLICT (user_id, device_fingerprint) DO UPDATE
       SET trusted = true,
           last_seen = now()
     RETURNING id, device_fingerprint, trusted_2fa_until, trusted_2fa_set_at`,
    [userId, fingerprint],
  );
  return result.rows[0] || null;
}

async function isTwoFactorTrustedDevice(queryable, userId, deviceFingerprint) {
  const fingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  if (!userId || !fingerprint) return false;
  const q = await queryable.query(
    `SELECT id
     FROM devices
     WHERE user_id = $1
       AND device_fingerprint = $2
       AND trusted_2fa_until IS NOT NULL
       AND trusted_2fa_until > now()
     LIMIT 1`,
    [userId, fingerprint],
  );
  return q.rowCount > 0;
}

async function grantTwoFactorDeviceTrust(
  queryable,
  userId,
  deviceFingerprint,
  { days = TRUST_DEVICE_2FA_DAYS } = {},
) {
  const fingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  if (!userId || !fingerprint) return null;
  const safeDays = Math.max(1, Math.min(Number(days) || TRUST_DEVICE_2FA_DAYS, 90));
  const q = await queryable.query(
    `INSERT INTO devices (
       id,
       user_id,
       device_fingerprint,
       trusted,
       created_at,
       last_seen,
       trusted_2fa_until,
       trusted_2fa_set_at
     )
     VALUES (
       gen_random_uuid(),
       $1,
       $2,
       true,
       now(),
       now(),
       now() + make_interval(days => $3::int),
       now()
     )
     ON CONFLICT (user_id, device_fingerprint) DO UPDATE
       SET trusted = true,
           last_seen = now(),
           trusted_2fa_until = now() + make_interval(days => $3::int),
           trusted_2fa_set_at = now()
     RETURNING id, trusted_2fa_until`,
    [userId, fingerprint, safeDays],
  );
  return q.rows[0] || null;
}

async function revokeAllTwoFactorTrustedDevices(queryable, userId) {
  if (!userId) return 0;
  const q = await queryable.query(
    `UPDATE devices
     SET trusted_2fa_until = NULL,
         trusted_2fa_set_at = NULL
     WHERE user_id = $1
       AND trusted_2fa_until IS NOT NULL`,
    [userId],
  );
  return q.rowCount || 0;
}

async function listTwoFactorTrustedDevices(queryable, userId) {
  if (!userId) return [];
  const q = await queryable.query(
    `SELECT id,
            device_fingerprint,
            last_seen,
            trusted_2fa_until,
            trusted_2fa_set_at,
            created_at
     FROM devices
     WHERE user_id = $1
       AND trusted_2fa_until IS NOT NULL
       AND trusted_2fa_until > now()
     ORDER BY trusted_2fa_until DESC, last_seen DESC, created_at DESC
     LIMIT 30`,
    [userId],
  );
  return q.rows;
}

async function countTwoFactorTrustedDevices(queryable, userId) {
  if (!userId) return 0;
  const q = await queryable.query(
    `SELECT COUNT(*)::int AS count
     FROM devices
     WHERE user_id = $1
       AND trusted_2fa_until IS NOT NULL
       AND trusted_2fa_until > now()`,
    [userId],
  );
  return Number(q.rows[0]?.count || 0);
}

async function revokeTwoFactorTrustedDeviceById(queryable, userId, deviceId) {
  if (!userId || !deviceId) return false;
  const q = await queryable.query(
    `UPDATE devices
     SET trusted_2fa_until = NULL,
         trusted_2fa_set_at = NULL
     WHERE id = $1::uuid
       AND user_id = $2
       AND trusted_2fa_until IS NOT NULL
     RETURNING id`,
    [deviceId, userId],
  );
  return q.rowCount > 0;
}

async function countActiveBackupCodes(queryable, userId) {
  if (!userId) return 0;
  const q = await queryable.query(
    `SELECT COUNT(*)::int AS count
     FROM user_two_factor_backup_codes
     WHERE user_id = $1
       AND used_at IS NULL`,
    [userId],
  );
  return Number(q.rows[0]?.count || 0);
}

async function replaceUserBackupCodes(
  queryable,
  userId,
  { count = BACKUP_CODES_DEFAULT_COUNT } = {},
) {
  if (!userId) return [];
  const generated = generateBackupCodes({ count });
  await queryable.query(
    `DELETE FROM user_two_factor_backup_codes
     WHERE user_id = $1`,
    [userId],
  );
  for (const hash of generated.hashes) {
    await queryable.query(
      `INSERT INTO user_two_factor_backup_codes (
         id,
         user_id,
         code_hash,
         used_at,
         created_at
       )
       VALUES (gen_random_uuid(), $1, $2, NULL, now())`,
      [userId, hash],
    );
  }
  return generated.plain;
}

async function consumeBackupCode(queryable, userId, rawCode) {
  if (!userId) return false;
  const normalized = normalizeBackupCode(rawCode);
  if (!normalized) return false;
  const hash = hashBackupCode(normalized);
  if (!hash) return false;
  const q = await queryable.query(
    `UPDATE user_two_factor_backup_codes
     SET used_at = now()
     WHERE user_id = $1
       AND code_hash = $2
       AND used_at IS NULL
     RETURNING id`,
    [userId, hash],
  );
  return q.rowCount > 0;
}

async function upsertTenantUserIndex({
  tenantId,
  userId,
  email,
  role = 'client',
  isActive = true,
}) {
  const normalizedTenantId = String(tenantId || '').trim();
  const normalizedUserId = String(userId || '').trim();
  const normalizedEmail = String(email || '').trim().toLowerCase();
  if (!normalizedTenantId || !normalizedUserId || !normalizedEmail) return;

  try {
    await db.platformQuery(
      `INSERT INTO tenant_user_index (
         tenant_id,
         user_id,
         email,
         role,
         is_active,
         created_at,
         updated_at
       )
       VALUES ($1, $2, $3, $4, $5, now(), now())
       ON CONFLICT (tenant_id, user_id) DO UPDATE
       SET email = EXCLUDED.email,
           role = EXCLUDED.role,
           is_active = EXCLUDED.is_active,
           updated_at = now()`,
      [
        normalizedTenantId,
        normalizedUserId,
        normalizedEmail,
        String(role || 'client').toLowerCase().trim() || 'client',
        isActive === true,
      ],
    );
  } catch (err) {
    if (String(err?.code || '') === '42P01') return;
    throw err;
  }
}

async function resolveTenantByAccessKey(accessKey) {
  const normalized = normalizeAccessKey(accessKey);
  if (!normalized) return null;
  const hash = hashAccessKey(normalized);
  const tenantRes = await db.platformQuery(
    `SELECT id, code, name, status, subscription_expires_at,
            db_mode, db_url, db_name, db_schema
     FROM tenants
     WHERE access_key_hash = $1
     LIMIT 1`,
    [hash],
  );
  return tenantRes.rowCount > 0 ? tenantRes.rows[0] : null;
}

async function resolveTenantByUserEmail(email) {
  const normalizedEmail = String(email || '').trim().toLowerCase();
  if (!normalizedEmail) return null;

  try {
    const indexedTenantRes = await db.platformQuery(
      `SELECT t.id,
              t.code,
              t.name,
              t.status,
              t.subscription_expires_at,
              t.db_mode,
              t.db_url,
              t.db_name,
              t.db_schema
       FROM tenant_user_index tui
       JOIN tenants t ON t.id = tui.tenant_id
       WHERE lower(tui.email) = $1
         AND tui.is_active = true
       ORDER BY tui.updated_at DESC, tui.created_at DESC
       LIMIT 2`,
      [normalizedEmail],
    );
    if (indexedTenantRes.rowCount === 1) {
      return indexedTenantRes.rows[0];
    }
    if (indexedTenantRes.rowCount > 1) {
      const uniqueTenantIds = new Set(
        indexedTenantRes.rows
          .map((row) => String(row.id || '').trim())
          .filter(Boolean),
      );
      if (uniqueTenantIds.size === 1) {
        return indexedTenantRes.rows[0];
      }
      return null;
    }
  } catch (err) {
    if (String(err?.code || '') !== '42P01') {
      throw err;
    }
  }

  const tenantRes = await db.platformQuery(
    `SELECT t.id,
            t.code,
            t.name,
            t.status,
            t.subscription_expires_at,
            t.db_mode,
            t.db_url,
            t.db_name,
            t.db_schema
     FROM users u
     JOIN tenants t ON t.id = u.tenant_id
     WHERE lower(u.email) = $1
       AND u.is_active = true
     LIMIT 2`,
    [normalizedEmail],
  );

  if (tenantRes.rowCount > 1) {
    const uniqueTenantIds = new Set(
      tenantRes.rows
        .map((row) => String(row.id || '').trim())
        .filter(Boolean),
    );
    if (uniqueTenantIds.size === 1) {
      return tenantRes.rows[0];
    }
    return null;
  }
  if (tenantRes.rowCount === 1) return tenantRes.rows[0];

  // Fallback for isolated tenant databases when tenant_user_index is missing
  // or not yet populated: probe tenant scopes and find the single matching tenant.
  const tenantCandidatesRes = await db.platformQuery(
    `SELECT id,
            code,
            name,
            status,
            subscription_expires_at,
            db_mode,
            db_url,
            db_name,
            db_schema
     FROM tenants
     WHERE COALESCE(status, 'active') <> 'deleted'
     ORDER BY created_at DESC
     LIMIT 200`,
  );

  if (tenantCandidatesRes.rowCount === 0) return null;

  let matchedTenant = null;
  for (const tenantRow of tenantCandidatesRes.rows) {
    const tenantId = String(tenantRow?.id || '').trim();
    if (!tenantId) continue;
    try {
      const hasUser = await db.runWithTenantRow(tenantRow, async () => {
        const q = await db.query(
          `SELECT u.id
           FROM users u
           WHERE lower(u.email) = $1
             AND u.is_active = true
             AND (u.tenant_id = $2::uuid OR u.tenant_id IS NULL)
           LIMIT 1`,
          [normalizedEmail, tenantId],
        );
        return q.rowCount > 0;
      });
      if (!hasUser) continue;
      if (matchedTenant && String(matchedTenant.id || '') !== tenantId) {
        // Ambiguous email across multiple tenants: force explicit tenant code.
        return null;
      }
      matchedTenant = tenantRow;
    } catch (err) {
      console.error('auth.resolveTenantByUserEmail tenant scan error', {
        tenant_id: tenantId,
        error: err?.message || String(err),
      });
    }
  }

  return matchedTenant;
}

async function resolveTenantInviteByCode(inviteCode) {
  const normalized = normalizeInviteCode(inviteCode);
  if (!normalized) return null;
  const inviteRes = await db.platformQuery(
    `SELECT i.id,
            i.tenant_id,
            i.code,
            i.role,
            i.is_active,
            i.max_uses,
            i.used_count,
            i.expires_at,
            t.code AS tenant_code,
            t.name AS tenant_name,
            t.status,
            t.subscription_expires_at,
            t.db_mode,
            t.db_url,
            t.db_name,
            t.db_schema
     FROM tenant_invites i
     JOIN tenants t ON t.id = i.tenant_id
     WHERE i.code = $1
     LIMIT 1
     FOR UPDATE`,
    [normalized],
  );
  if (inviteRes.rowCount === 0) return null;
  return inviteRes.rows[0];
}

async function resolveDefaultTenant() {
  const result = await db.platformQuery(
    `SELECT id, code, name, status, subscription_expires_at, db_mode, db_url, db_name, db_schema
     FROM tenants
     WHERE code = 'default'
     LIMIT 1`,
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

function getRequestIp(req) {
  return String(
    req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
      req.ip ||
      '',
  ).trim();
}

function buildPublicAppUrl(req) {
  const configured = String(
    process.env.AUTH_EMAIL_LINK_BASE || process.env.PUBLIC_BASE_URL || '',
  ).trim();
  if (configured) {
    return configured.replace(/\/+$/, '');
  }
  return `${req.protocol}://${req.get('host')}`;
}

function buildAuthActionLink(req, action, token) {
  const url = new URL(buildPublicAppUrl(req));
  url.searchParams.set('auth_action', action);
  url.searchParams.set('token', token);
  return url.toString();
}

function generateAuthEmailToken() {
  return crypto.randomBytes(32).toString('hex');
}

function normalizeAuthEmailToken(rawValue) {
  const value = String(rawValue || '').trim();
  if (!value) return '';
  if (value.length < 32 || value.length > 200) return '';
  return value;
}

function buildGenericRecoveryResponse(kind) {
  if (kind === 'magic_login') {
    return {
      ok: true,
      message:
        'Если аккаунт существует, мы отправили ссылку для входа на указанную почту',
    };
  }
  return {
    ok: true,
    message:
      'Если аккаунт существует, мы отправили ссылку для сброса пароля на указанную почту',
  };
}

async function revokeAllUserSessions({ queryable = db, userId }) {
  if (!userId) return 0;
  const result = await queryable.query(
    `UPDATE user_sessions
     SET is_active = false
     WHERE user_id = $1
       AND is_active = true
     RETURNING id`,
    [userId],
  );
  return result.rowCount || 0;
}

async function invalidateUnusedAuthEmailTokens(queryable, userId, kind) {
  if (!userId || !kind) return 0;
  const result = await queryable.query(
    `UPDATE auth_email_tokens
     SET used_at = now()
     WHERE user_id = $1
       AND kind = $2
       AND used_at IS NULL`,
    [userId, kind],
  );
  return result.rowCount || 0;
}

async function issueAuthEmailToken(
  queryable,
  { userId, tenantId = null, email, kind, ttlMinutes, req },
) {
  const token = generateAuthEmailToken();
  const tokenHash = sha256Hex(token);
  const safeTtlMinutes = Math.max(5, Math.min(Number(ttlMinutes) || 15, 60));
  await invalidateUnusedAuthEmailTokens(queryable, userId, kind);
  await queryable.query(
    `INSERT INTO auth_email_tokens (
       id,
       user_id,
       tenant_id,
       email,
       kind,
       token_hash,
       requested_ip,
       requested_user_agent,
       expires_at,
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
       now() + make_interval(mins => $8::int),
       now()
     )`,
    [
      userId,
      tenantId || null,
      String(email || '').trim().toLowerCase(),
      kind,
      tokenHash,
      getRequestIp(req),
      req.get('user-agent') || '',
      safeTtlMinutes,
    ],
  );
  return token;
}

async function claimAuthEmailToken(queryable, { token, kind, req }) {
  const normalizedToken = normalizeAuthEmailToken(token);
  if (!normalizedToken) return null;
  const tokenHash = sha256Hex(normalizedToken);
  const result = await queryable.query(
    `WITH claimed AS (
       UPDATE auth_email_tokens
       SET used_at = now(),
           consumed_ip = NULLIF($2, ''),
           consumed_user_agent = NULLIF($3, '')
       WHERE token_hash = $1
         AND kind = $4
         AND used_at IS NULL
         AND expires_at > now()
       RETURNING id, user_id, tenant_id, email, kind, expires_at
     )
     SELECT c.id AS token_id,
            c.user_id,
            c.tenant_id,
            c.email,
            c.kind,
            c.expires_at,
            u.id,
            u.email AS user_email,
            u.name,
            u.role,
            u.is_active,
            u.block_reason,
            u.tenant_id AS user_tenant_id,
            u.two_factor_enabled,
            t.code AS tenant_code,
            t.name AS tenant_name,
            t.status AS tenant_status,
            t.subscription_expires_at
     FROM claimed c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN tenants t ON t.id = u.tenant_id
     LIMIT 1`,
    [
      tokenHash,
      getRequestIp(req),
      req.get('user-agent') || '',
      kind,
    ],
  );
  return result.rows[0] || null;
}

async function resolveTenantForEmailAuthRequest(req, normalizedEmail) {
  const isPlatformCreator =
    normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase();
  if (isPlatformCreator) {
    return { tenant: null, isPlatformCreator: true };
  }

  let tenant = null;
  const tenantCodeHint = extractTenantCodeHint(req);
  if (tenantCodeHint) {
    tenant = await db.resolveTenantByCode(tenantCodeHint);
  }
  if (!tenant) {
    tenant = await resolveTenantByUserEmail(normalizedEmail);
  }
  return { tenant, isPlatformCreator: false };
}

async function findUserForEmailAuthRequest(req, normalizedEmail) {
  const { tenant, isPlatformCreator } = await resolveTenantForEmailAuthRequest(
    req,
    normalizedEmail,
  );
  if (!isPlatformCreator && !tenant) {
    return { user: null, tenant: null, isPlatformCreator: false };
  }

  const user = await db.runWithTenantRow(
    isPlatformCreator ? null : tenant,
    async () => {
      const q = await db.query(
        `SELECT u.id,
                u.email,
                u.name,
                u.role,
                u.is_active,
                u.block_reason,
                u.tenant_id,
                u.two_factor_enabled,
                t.code AS tenant_code,
                t.name AS tenant_name,
                t.status AS tenant_status,
                t.subscription_expires_at
         FROM users u
         LEFT JOIN tenants t ON t.id = u.tenant_id
         WHERE lower(u.email) = $1
         LIMIT 1`,
        [normalizedEmail],
      );
      return q.rows[0] || null;
    },
  );

  return {
    user,
    tenant,
    isPlatformCreator,
  };
}

async function resolvePhoneAccessForUser({
  user,
  tenant,
  isPlatformCreator = false,
}) {
  let phoneAccess = { state: 'none' };
  if (!isPlatformCreator && user?.tenant_id) {
    try {
      phoneAccess = await db.runWithTenantRow(tenant, async () =>
        await resolvePhoneAccessState(db, {
          requesterUserId: user.id,
          tenantId: user.tenant_id || tenant?.id || null,
        }),
      );
    } catch (err) {
      console.error('auth.phoneAccess state resolve error', err);
    }
  }
  return phoneAccess;
}

async function createAuthenticatedSession({
  client,
  user,
  req,
  deviceFingerprint = null,
}) {
  const normalizedFingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  await assertDeviceAccountLimit(
    client,
    normalizedFingerprint,
    user.id,
    user.tenant_id || null,
  );
  await upsertDevice(client, user.id, normalizedFingerprint);

  const sessionId = uuidv4();
  const sessionExpiresAt = buildSessionExpiry();
  await createUserSession({
    queryable: client,
    userId: user.id,
    sessionId,
    deviceFingerprint: normalizedFingerprint,
    userAgent: req.get('user-agent') || '',
    ipAddress: getRequestIp(req),
    expiresAt: sessionExpiresAt,
  });
  return {
    sessionId,
    normalizedFingerprint,
  };
}

async function buildSuccessfulAuthResponse({
  req,
  user,
  tenant,
  sessionId,
  isPlatformCreator = false,
  twoFactor = null,
}) {
  if (!isPlatformCreator) {
    try {
      await upsertTenantUserIndex({
        tenantId: user?.tenant_id || tenant?.id || null,
        userId: user?.id || null,
        email: user?.email || '',
        role: user?.role || 'client',
        isActive: user?.is_active !== false,
      });
    } catch (err) {
      console.error('auth.buildSuccessfulAuthResponse tenantUserIndex error', err);
    }
  }

  const phoneAccess = await resolvePhoneAccessForUser({
    user,
    tenant,
    isPlatformCreator,
  });
  const effectiveTenantCode = tenant?.code || user?.tenant_code || null;
  const token = signToken({
    id: user.id,
    email: user.email,
    role: user.role,
    tenant_id: user.tenant_id || null,
    tenant_code: effectiveTenantCode,
    sid: sessionId,
  });

  return {
    token,
    session_id: sessionId,
    two_factor: twoFactor || {
      enabled: false,
      method: 'disabled',
      trust_device_applied: false,
    },
    user: {
      id: user.id,
      email: user.email,
      role: user.role,
      tenant_id: user.tenant_id || null,
      tenant_code: effectiveTenantCode,
      tenant_name: user.tenant_name || tenant?.name || null,
      phone_access_state: phoneAccess.state || 'none',
      phone_access: phoneAccess,
    },
    tenant: user.tenant_id
      ? {
          id: user.tenant_id,
          code: effectiveTenantCode,
          name: user.tenant_name || tenant?.name || null,
          status: user.tenant_status || tenant?.status || null,
          subscription_expires_at:
            user.subscription_expires_at || tenant?.subscription_expires_at || null,
        }
      : null,
  };
}

function buildPasswordResetEmail({ req, user, token }) {
  const link = buildAuthActionLink(req, 'password_reset', token);
  const greeting = String(user?.name || '').trim() || String(user?.email || '').trim();
  return {
    subject: 'Сброс пароля Fenix',
    text: [
      `Здравствуйте, ${greeting}.`,
      '',
      'Вы запросили сброс пароля для входа в Fenix.',
      'Откройте ссылку ниже и задайте новый пароль:',
      link,
      '',
      `Ссылка действует ${PASSWORD_RESET_TTL_MINUTES} минут и работает только один раз.`,
      'Если это были не вы, просто проигнорируйте письмо.',
    ].join('\n'),
    html: `
      <div style="font-family:Arial,sans-serif;line-height:1.6;color:#1f2937">
        <h2 style="margin-bottom:12px">Сброс пароля Fenix</h2>
        <p>Здравствуйте, ${greeting}.</p>
        <p>Вы запросили сброс пароля для входа в Fenix.</p>
        <p>
          <a href="${link}" style="display:inline-block;padding:12px 18px;background:#111827;color:#ffffff;text-decoration:none;border-radius:8px">
            Сбросить пароль
          </a>
        </p>
        <p style="word-break:break-all">${link}</p>
        <p>Ссылка действует ${PASSWORD_RESET_TTL_MINUTES} минут и работает только один раз.</p>
        <p>Если это были не вы, просто проигнорируйте письмо.</p>
      </div>
    `,
  };
}

function buildMagicLinkEmail({ req, user, token }) {
  const link = buildAuthActionLink(req, 'magic_login', token);
  const greeting = String(user?.name || '').trim() || String(user?.email || '').trim();
  return {
    subject: 'Вход в Fenix по ссылке',
    text: [
      `Здравствуйте, ${greeting}.`,
      '',
      'Вы запросили вход в Fenix без пароля.',
      'Откройте ссылку ниже для входа:',
      link,
      '',
      `Ссылка действует ${MAGIC_LINK_TTL_MINUTES} минут и работает только один раз.`,
      'Если это были не вы, просто проигнорируйте письмо.',
    ].join('\n'),
    html: `
      <div style="font-family:Arial,sans-serif;line-height:1.6;color:#1f2937">
        <h2 style="margin-bottom:12px">Вход в Fenix по ссылке</h2>
        <p>Здравствуйте, ${greeting}.</p>
        <p>Вы запросили вход в Fenix без пароля.</p>
        <p>
          <a href="${link}" style="display:inline-block;padding:12px 18px;background:#111827;color:#ffffff;text-decoration:none;border-radius:8px">
            Войти в Fenix
          </a>
        </p>
        <p style="word-break:break-all">${link}</p>
        <p>Ссылка действует ${MAGIC_LINK_TTL_MINUTES} минут и работает только один раз.</p>
        <p>Если это были не вы, просто проигнорируйте письмо.</p>
      </div>
    `,
  };
}

/**
 * POST /api/auth/check_email
 * body: { email }
 */
router.post('/check_email', async (req, res) => {
  try {
    const { email } = req.body || {};
    if (!email) return res.status(400).json({ error: 'email required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email' });
    }

    const tenantCodeHint = extractTenantCodeHint(req);
    const existing = tenantCodeHint
      ? await db.runWithTenantCode(
          tenantCodeHint,
          () => db.query('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]),
        )
      : await db.platformQuery('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]);
    return res.json({ exists: existing.rowCount > 0 });
  } catch (err) {
    if (String(err?.code || '') === 'TENANT_NOT_FOUND') {
      return res.status(404).json({ exists: false, error: 'Арендатор не найден' });
    }
    console.error('check_email error', err);
    return res.status(500).json({ error: 'Server error' });
  }
});

router.get('/email-auth/status', async (req, res) => {
  try {
    const enabled = isMailConfigured();
    return res.json({
      ok: true,
      data: {
        mail_configured: enabled,
        password_reset_enabled: enabled,
        magic_link_enabled: enabled,
      },
    });
  } catch (err) {
    console.error('auth.emailAuth.status error', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

router.post('/invite/resolve', async (req, res) => {
  try {
    const normalized = normalizeInviteCode(
      req.body?.invite_code || req.body?.invite || req.body?.code || '',
    );
    if (!normalized) {
      return res.status(400).json({
        ok: false,
        error: 'invite_code required',
      });
    }

    const invite = await resolveTenantInviteByCode(normalized);
    if (!invite) {
      return res.status(404).json({
        ok: false,
        error: 'Код приглашения не найден',
      });
    }
    if (invite.is_active !== true) {
      return res.status(403).json({ ok: false, error: 'Код приглашения отключен' });
    }
    if (invite.expires_at && new Date(invite.expires_at).getTime() < Date.now()) {
      return res.status(403).json({ ok: false, error: 'Срок действия кода приглашения истек' });
    }
    const maxUses = Number(invite.max_uses);
    const usedCount = Number(invite.used_count || 0);
    if (Number.isFinite(maxUses) && maxUses > 0 && usedCount >= maxUses) {
      return res.status(403).json({
        ok: false,
        error: 'Лимит использований этого кода приглашения исчерпан',
      });
    }

    const tenantState = isTenantActive({
      status: invite.status,
      subscription_expires_at: invite.subscription_expires_at,
    });
    if (!tenantState.ok) {
      return res.status(403).json({ ok: false, error: tenantState.error });
    }

    return res.json({
      ok: true,
      data: {
        invite_code: normalized,
        role: String(invite.role || 'client').toLowerCase().trim(),
        tenant_id: invite.tenant_id,
        tenant_code: invite.tenant_code,
        tenant_name: invite.tenant_name,
      },
    });
  } catch (err) {
    console.error('auth.invite.resolve error', err);
    return res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

/**
 * POST /api/auth/register
 * body: { email, password, name?, phone?, secret? }
 *
 * Notes:
 * - If email equals CREATOR_EMAIL and correct secret provided, role becomes 'creator'
 * - Returns { token, user: { id, email, name, role } }
 */
router.post('/register', async (req, res) => {
  try {
    const {
      email,
      password,
      name,
      phone,
      secret,
      device_fingerprint,
      access_key,
      invite_code,
      group_name,
      main_channel_title,
    } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }
    if (typeof password !== 'string' || password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }
    const requiredDeviceFingerprint = ensureDeviceFingerprint(device_fingerprint);

    let role = 'client';
    let tenant = null;
    let invite = null;
    const isPlatformCreator = normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase();
    const tenantGroupName = normalizeTenantGroupName(group_name);
    const tenantMainChannelTitle = normalizeMainChannelTitle(main_channel_title);

    if (isPlatformCreator) {
      if (!CREATOR_SECRET && !CREATOR_SECRET_HASH) {
        return res.status(503).json({
          error:
            'Регистрация создателя временно отключена: на сервере не задан секрет создателя.',
        });
      }
      if (!isValidCreatorSecret(secret)) {
        return res.status(403).json({ error: 'Invalid secret for this email' });
      }
      role = 'creator';
      tenant = await resolveDefaultTenant();
      if (!tenant?.id) {
        return res.status(500).json({
          error: 'Default-арендатор не найден. Выполните /api/setup и перезапустите сервер.',
        });
      }
    } else {
      const rawInputCode = String(access_key || '').trim();
      const rawAccessKey = normalizeAccessKey(rawInputCode);
      const rawInviteCode = normalizeInviteCode(invite_code || access_key);
      const looksLikeAccessKey = isTenantAccessKey(rawAccessKey);

      if (looksLikeAccessKey) {
        tenant = await resolveTenantByAccessKey(rawAccessKey);
        if (!tenant) {
          return res.status(403).json({ error: 'Неверный ключ арендатора.' });
        }
        if (!tenantGroupName) {
          return res.status(400).json({
            error: "Введите название вашей группы арендатора",
          });
        }
        if (!tenantMainChannelTitle) {
          return res.status(400).json({
            error: "Введите название основного канала",
          });
        }
        role = 'tenant';
      } else if (rawInviteCode) {
        invite = await resolveTenantInviteByCode(rawInviteCode);
        if (!invite) {
          return res.status(403).json({ error: 'Неверный или устаревший код приглашения.' });
        }
        if (invite.is_active !== true) {
          return res.status(403).json({ error: 'Код приглашения отключен.' });
        }
        if (invite.expires_at && new Date(invite.expires_at).getTime() < Date.now()) {
          return res.status(403).json({ error: 'Срок действия кода приглашения истек.' });
        }
        const maxUses = Number(invite.max_uses);
        const usedCount = Number(invite.used_count || 0);
        if (Number.isFinite(maxUses) && maxUses > 0 && usedCount >= maxUses) {
          return res.status(403).json({ error: 'Лимит использований этого кода приглашения исчерпан.' });
        }
        tenant = {
          id: invite.tenant_id,
          code: invite.tenant_code,
          name: invite.tenant_name,
          status: invite.status,
          subscription_expires_at: invite.subscription_expires_at,
          db_mode: invite.db_mode || 'shared',
          db_url: invite.db_url || null,
          db_name: invite.db_name || null,
          db_schema: invite.db_schema || null,
        };
        // Приглашения всегда регистрируют клиента.
        role = 'client';
      } else {
        return res.status(403).json({
          error:
            'Для регистрации нужен ключ арендатора (для владельца) или клиентский код приглашения.',
        });
      }

      const shouldEnforceTenantSubscription = role !== 'client';
      if (shouldEnforceTenantSubscription) {
        const tenantState = isTenantActive(tenant);
        if (!tenantState.ok) {
          return res.status(403).json({ error: tenantState.error });
        }
      }
    }

    const registerInScope = async () => {
      const client = await db.pool.connect();
      try {
        await client.query('BEGIN');

        const existing = await client.query('SELECT id FROM users WHERE email = $1', [normalizedEmail]);
        if (existing.rowCount > 0) {
          await client.query('ROLLBACK');
          return { ok: false, status: 409, error: 'Email already registered' };
        }

        await assertDeviceAccountLimit(
          client,
          requiredDeviceFingerprint,
          null,
          tenant?.id || null,
        );

        const normalizedPhone = normalizePhoneDigits(phone);
        if (phone && normalizedPhone.length < 10) {
          await client.query('ROLLBACK');
          return { ok: false, status: 400, error: 'Invalid phone format' };
        }
        let duplicatePhoneOwner = null;
        if (role === 'client' && tenant?.id && normalizedPhone.length >= 10) {
          duplicatePhoneOwner = await findOldestPhoneOwner(client, {
            tenantId: tenant.id,
            phoneDigits: normalizedPhone,
          });
        }

        const password_hash = await bcrypt.hash(password, SALT_ROUNDS);
        const insertUser = await client.query(
          `INSERT INTO users (email, password_hash, name, role, tenant_id, created_at)
           VALUES ($1, $2, $3, $4, $5, now())
           RETURNING id, email, name, role, tenant_id`,
          [
            normalizedEmail,
            password_hash,
            name || null,
            role,
            tenant?.id || null,
          ],
        );
        const user = insertUser.rows[0];

        let phoneAccessRequest = null;
        if (normalizedPhone.length >= 10) {
          await client.query(
            `INSERT INTO phones (user_id, phone, status, created_at)
             VALUES ($1, $2, 'pending_verification', now())
             ON CONFLICT (user_id) DO UPDATE
               SET phone = $2, status = 'pending_verification', created_at = now()`,
            [user.id, normalizedPhone],
          );
          if (
            duplicatePhoneOwner &&
            String(duplicatePhoneOwner.id || '') !== String(user.id || '')
          ) {
            phoneAccessRequest = await createPhoneAccessRequest(client, {
              tenantId: tenant?.id || null,
              phoneDigits: normalizedPhone,
              ownerUserId: duplicatePhoneOwner.id,
              requesterUserId: user.id,
            });
          }
        }

        if (role === "tenant" && tenant?.id) {
          const ownerQ = await client.query(
            `SELECT id
             FROM users
             WHERE tenant_id = $1
               AND role = 'tenant'
               AND id <> $2
             LIMIT 1`,
            [tenant.id, user.id],
          );
          if (ownerQ.rowCount > 0) {
            await client.query("ROLLBACK");
            return {
              ok: false,
              status: 409,
              error:
                "Этот ключ арендатора уже активирован. Обратитесь к создателю за новым ключом.",
            };
          }

          await client.query(
            `UPDATE tenants
             SET name = $1,
                 updated_at = now()
             WHERE id = $2`,
            [tenantGroupName, tenant.id],
          );
          tenant.name = tenantGroupName;

          const ensured = await ensureSystemChannels(client, user.id || null, tenant.id);
          if (tenantMainChannelTitle && ensured?.mainChannel?.id) {
            await client.query(
              `UPDATE chats
               SET title = $1,
                   updated_at = now()
               WHERE id = $2`,
              [tenantMainChannelTitle, ensured.mainChannel.id],
            );
          }
        }

        await upsertDevice(client, user.id, requiredDeviceFingerprint);

        const sessionId = uuidv4();
        const sessionExpiresAt = buildSessionExpiry();
        await createUserSession({
          queryable: client,
          userId: user.id,
          sessionId,
          deviceFingerprint: requiredDeviceFingerprint,
          userAgent: req.get('user-agent') || '',
          ipAddress:
            req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
            req.ip ||
            '',
          expiresAt: sessionExpiresAt,
        });

        await client.query('COMMIT');
        return { ok: true, user, sessionId, phoneAccessRequest };
      } catch (err) {
        try { await client.query('ROLLBACK'); } catch (_) {}
        throw err;
      } finally {
        client.release();
      }
    };

    const registration = await db.runWithTenantRow(
      isPlatformCreator ? null : tenant,
      registerInScope,
    );
    if (!registration?.ok) {
      return res.status(registration?.status || 500).json({
        error: registration?.error || 'Internal server error',
      });
    }

    if (invite?.id) {
      try {
        await db.platformQuery(
          `UPDATE tenant_invites
           SET used_count = used_count + 1,
               is_active = CASE
                 WHEN max_uses IS NOT NULL AND used_count + 1 >= max_uses THEN false
                 ELSE is_active
               END,
               last_used_at = now(),
               updated_at = now()
           WHERE id = $1`,
          [invite.id],
        );
      } catch (err) {
        console.error('auth.register invite usage update error', err);
      }
    }
    if (!isPlatformCreator) {
      try {
        await upsertTenantUserIndex({
          tenantId: registration.user?.tenant_id || tenant?.id || null,
          userId: registration.user?.id || null,
          email: registration.user?.email || normalizedEmail,
          role: registration.user?.role || role,
          isActive: true,
        });
      } catch (err) {
        console.error('auth.register tenantUserIndex error', err);
      }
    }

    let phoneAccess = { state: 'none' };
    if (!isPlatformCreator && registration.user?.tenant_id) {
      try {
        phoneAccess = await db.runWithTenantRow(tenant, async () =>
          await resolvePhoneAccessState(db, {
            requesterUserId: registration.user.id,
            tenantId: registration.user.tenant_id || tenant?.id || null,
          }),
        );
      } catch (err) {
        console.error('auth.register phoneAccess state error', err);
      }
    }

    if (registration.phoneAccessRequest?.id) {
      try {
        const io = req.app.get('io');
        const ownerUserId = String(
          registration.phoneAccessRequest.owner_user_id || '',
        ).trim();
        if (io && ownerUserId) {
          io.to(`user:${ownerUserId}`).emit('phone-access:request', {
            request_id: registration.phoneAccessRequest.id,
            tenant_id:
              registration.phoneAccessRequest.tenant_id ||
              registration.user?.tenant_id ||
              null,
            phone: registration.phoneAccessRequest.phone || '',
            requester_user_id: registration.user.id,
            requester_name: registration.user.name || '',
            requester_email: registration.user.email || '',
            requested_at: registration.phoneAccessRequest.requested_at || null,
          });
        }
      } catch (err) {
        console.error('auth.register phoneAccess notify error', err);
      }
    }

    const token = signToken({
      id: registration.user.id,
      email: registration.user.email,
      role: registration.user.role,
      tenant_id: registration.user.tenant_id || null,
      tenant_code: tenant?.code || null,
      sid: registration.sessionId,
    });

    return res.status(201).json({
      token,
      session_id: registration.sessionId,
      user: {
        id: registration.user.id,
        email: registration.user.email,
        name: registration.user.name,
        role: registration.user.role,
        tenant_id: registration.user.tenant_id || null,
        tenant_code: tenant?.code || null,
        tenant_name: tenant?.name || null,
        phone_access_state: phoneAccess.state || 'none',
        phone_access: phoneAccess,
      },
      tenant: tenant
        ? {
            id: tenant.id,
            code: tenant.code,
            name: tenant.name,
            subscription_expires_at: tenant.subscription_expires_at,
          }
        : null,
    });
  } catch (err) {
    console.error('auth.register error', err);
    return res.status(err.statusCode || 500).json({ error: err.message || 'Internal server error' });
  }
});

/**
 * POST /api/auth/login
 * body: { email, password }
 *
 * Returns { token, user: { id, email, role } }
 */
router.post('/login', async (req, res) => {
  try {
    const {
      email,
      password,
      device_fingerprint,
      access_key,
      otp_code,
      trust_device,
    } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Неверный логин или пароль' });
    }

    const isPlatformCreator = normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase();
    let tenant = null;

    if (!isPlatformCreator) {
      const tenantCodeHint = extractTenantCodeHint(req);
      if (tenantCodeHint) {
        tenant = await db.resolveTenantByCode(tenantCodeHint);
      } else {
        const normalizedAccessKey = normalizeAccessKey(access_key);
        if (isTenantAccessKey(normalizedAccessKey)) {
          tenant = await resolveTenantByAccessKey(normalizedAccessKey);
        }
      }

      if (!tenant) {
        tenant = await resolveTenantByUserEmail(normalizedEmail);
      }

      if (!tenant) {
        return res.status(400).json({
          error:
            'Не определен арендатор. Войдите по приглашению вашей группы или укажите код арендатора.',
        });
      }
    }

    const loginInScope = async () => {
      const client = await db.pool.connect();
      try {
        await client.query('BEGIN');
        const userRes = await client.query(
          `SELECT u.id, u.email, u.password_hash, u.role, u.is_active, u.block_reason, u.tenant_id,
                  u.two_factor_enabled,
                  u.two_factor_secret,
                  t.code AS tenant_code, t.name AS tenant_name, t.status AS tenant_status,
                  t.subscription_expires_at
           FROM users u
           LEFT JOIN tenants t ON t.id = u.tenant_id
           WHERE u.email = $1
           LIMIT 1`,
          [normalizedEmail],
        );
        const user = userRes.rows[0];
        if (!user) {
          await client.query('ROLLBACK');
          return { ok: false, status: 401, error: 'Неверные данные' };
        }

        const ok = await bcrypt.compare(password, user.password_hash);
        if (!ok) {
          await client.query('ROLLBACK');
          return { ok: false, status: 401, error: 'Неверные данные' };
        }
        if (user.is_active === false) {
          await client.query('ROLLBACK');
          const blockReason = String(user.block_reason || '').trim();
          return {
            ok: false,
            status: 403,
            error: blockReason || 'Вас заблокировали за нарушение правил',
          };
        }

        if (!isPlatformCreator) {
          if (!user.tenant_id && tenant?.id) {
            const patchedTenantRes = await client.query(
              `UPDATE users
               SET tenant_id = $1
               WHERE id = $2
                 AND tenant_id IS NULL
               RETURNING tenant_id`,
              [tenant.id, user.id],
            );
            if (patchedTenantRes.rowCount > 0) {
              user.tenant_id = patchedTenantRes.rows[0]?.tenant_id || tenant.id;
            }
          }
          if (!user.tenant_id) {
            await client.query('ROLLBACK');
            return {
              ok: false,
              status: 403,
              error: 'Аккаунт не привязан к арендатору. Обратитесь к владельцу приложения.',
            };
          }
          const userRole = String(user.role || '').toLowerCase().trim();
          const shouldEnforceTenantSubscription =
            userRole === 'tenant' ||
            userRole === 'admin' ||
            userRole === 'worker';
          if (shouldEnforceTenantSubscription) {
            const tenantState = isTenantActive({
              status: user.tenant_status || tenant?.status,
              subscription_expires_at:
                user.subscription_expires_at || tenant?.subscription_expires_at,
            });
            if (!tenantState.ok) {
              await client.query('ROLLBACK');
              return {
                ok: false,
                status: tenantState.reason === 'tenant_expired' ? 402 : 403,
                error: tenantState.error,
              };
            }
          }
        }

        const requiresTwoFactor =
          isTwoFactorEligibleRole(user) && user.two_factor_enabled === true;
        const normalizedFingerprint = normalizeDeviceFingerprint(
          device_fingerprint,
        );
        const trustDeviceRequested = parseBooleanFlag(trust_device);
        let twoFactorMethod = 'disabled';
        let trustedByDevice = false;

        if (requiresTwoFactor) {
          const secret = decryptTwoFactorSecret(user.two_factor_secret);
          if (!secret) {
            await client.query('ROLLBACK');
            return {
              ok: false,
              status: 403,
              error: '2FA включена, но ключ недоступен. Обратитесь к создателю приложения.',
            };
          }

          trustedByDevice = await isTwoFactorTrustedDevice(
            client,
            user.id,
            normalizedFingerprint,
          );

          if (trustedByDevice) {
            twoFactorMethod = 'trusted_device';
          } else {
            const providedCode = normalizeTotpCode(
              otp_code || req.body?.two_factor_code || req.body?.totp_code,
            );
            let verified = false;
            if (verifyTwoFactorCode(secret, providedCode)) {
              verified = true;
              twoFactorMethod = 'totp';
            } else {
              const backupAccepted = await consumeBackupCode(
                client,
                user.id,
                providedCode,
              );
              if (backupAccepted) {
                verified = true;
                twoFactorMethod = 'backup_code';
              }
            }
            if (!verified) {
              await client.query('ROLLBACK');
              return {
                ok: false,
                status: 401,
                error: 'Требуется код 2FA (Google Authenticator или резервный код)',
                twoFactorRequired: true,
              };
            }
          }
        }

        await assertDeviceAccountLimit(
          client,
          normalizedFingerprint,
          user.id,
          user.tenant_id || null,
        );
        await upsertDevice(client, user.id, normalizedFingerprint);

        if (
          requiresTwoFactor &&
          trustDeviceRequested &&
          !trustedByDevice &&
          normalizedFingerprint
        ) {
          await grantTwoFactorDeviceTrust(
            client,
            user.id,
            normalizedFingerprint,
          );
        }

        const sessionId = uuidv4();
        const sessionExpiresAt = buildSessionExpiry();
        await createUserSession({
          queryable: client,
          userId: user.id,
          sessionId,
          deviceFingerprint: device_fingerprint,
          userAgent: req.get('user-agent') || '',
          ipAddress:
            req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
            req.ip ||
            '',
          expiresAt: sessionExpiresAt,
        });

        await client.query('COMMIT');
        return {
          ok: true,
          user,
          sessionId,
          twoFactor: {
            enabled: requiresTwoFactor,
            method: twoFactorMethod,
            trust_device_applied:
              requiresTwoFactor &&
              trustDeviceRequested &&
              !trustedByDevice &&
              Boolean(normalizedFingerprint),
          },
        };
      } catch (err) {
        try { await client.query('ROLLBACK'); } catch (_) {}
        throw err;
      } finally {
        client.release();
      }
    };

    const result = await db.runWithTenantRow(
      isPlatformCreator ? null : tenant,
      loginInScope,
    );
    if (!result?.ok) {
      const payload = {
        error: result?.error || 'Internal server error',
      };
      if (result?.twoFactorRequired) {
        payload.two_factor_required = true;
      }
      return res.status(result?.status || 500).json(payload);
    }
    return res.json(
      await buildSuccessfulAuthResponse({
        req,
        user: result.user,
        tenant,
        sessionId: result.sessionId,
        isPlatformCreator,
        twoFactor: result.twoFactor,
      }),
    );
  } catch (err) {
    console.error('auth.login error', err);
    return res.status(err.statusCode || 500).json({ error: err.message || 'Internal server error' });
  }
});

router.post('/password-reset/request', async (req, res) => {
  try {
    if (!isMailConfigured()) {
      return res.status(503).json({
        error:
          'Восстановление по почте пока не настроено на сервере. Обратитесь к создателю приложения.',
      });
    }

    const normalizedEmail = validator.normalizeEmail(req.body?.email || '');
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Введите корректный email' });
    }

    const result = await findUserForEmailAuthRequest(req, normalizedEmail);
    if (result.user && result.user.is_active !== false) {
      const token = await issueAuthEmailToken(db, {
        userId: result.user.id,
        tenantId: result.user.tenant_id || result.tenant?.id || null,
        email: result.user.email,
        kind: 'password_reset',
        ttlMinutes: PASSWORD_RESET_TTL_MINUTES,
        req,
      });
      await sendMail({
        to: result.user.email,
        ...buildPasswordResetEmail({
          req,
          user: result.user,
          token,
        }),
      });
    }

    return res.json(buildGenericRecoveryResponse('password_reset'));
  } catch (err) {
    console.error('auth.passwordReset.request error', err);
    return res
      .status(err.statusCode || 500)
      .json({ error: err.message || 'Ошибка сервера' });
  }
});

router.post('/magic-link/request', async (req, res) => {
  try {
    if (!isMailConfigured()) {
      return res.status(503).json({
        error:
          'Вход по ссылке пока не настроен на сервере. Обратитесь к создателю приложения.',
      });
    }

    const normalizedEmail = validator.normalizeEmail(req.body?.email || '');
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Введите корректный email' });
    }

    const result = await findUserForEmailAuthRequest(req, normalizedEmail);
    if (result.user && result.user.is_active !== false) {
      const token = await issueAuthEmailToken(db, {
        userId: result.user.id,
        tenantId: result.user.tenant_id || result.tenant?.id || null,
        email: result.user.email,
        kind: 'magic_login',
        ttlMinutes: MAGIC_LINK_TTL_MINUTES,
        req,
      });
      await sendMail({
        to: result.user.email,
        ...buildMagicLinkEmail({
          req,
          user: result.user,
          token,
        }),
      });
    }

    return res.json(buildGenericRecoveryResponse('magic_login'));
  } catch (err) {
    console.error('auth.magicLink.request error', err);
    return res
      .status(err.statusCode || 500)
      .json({ error: err.message || 'Ошибка сервера' });
  }
});

router.post('/magic-link/consume', async (req, res) => {
  const token = req.body?.token;
  const deviceFingerprint = req.body?.device_fingerprint;
  if (!normalizeAuthEmailToken(token)) {
    return res.status(400).json({ error: 'Ссылка недействительна или устарела' });
  }

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const claimed = await claimAuthEmailToken(client, {
      token,
      kind: 'magic_login',
      req,
    });
    if (!claimed) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'Ссылка недействительна или устарела' });
    }
    if (claimed.is_active === false) {
      await client.query('ROLLBACK');
      return res.status(403).json({
        error: String(claimed.block_reason || '').trim() ||
          'Вас заблокировали за нарушение правил',
      });
    }

    const isPlatformCreator =
      String(claimed.user_email || claimed.email || '').trim().toLowerCase() ===
      CREATOR_EMAIL.toLowerCase();
    const userRole = String(claimed.role || '').toLowerCase().trim();
    const shouldEnforceTenantSubscription =
      !isPlatformCreator &&
      (userRole === 'tenant' || userRole === 'admin' || userRole === 'worker');
    if (shouldEnforceTenantSubscription) {
      const tenantState = isTenantActive({
        status: claimed.tenant_status,
        subscription_expires_at: claimed.subscription_expires_at,
      });
      if (!tenantState.ok) {
        await client.query('ROLLBACK');
        return res.status(tenantState.reason === 'tenant_expired' ? 402 : 403).json({
          error: tenantState.error,
        });
      }
    }

    const user = {
      id: claimed.id,
      email: claimed.user_email || claimed.email,
      role: claimed.role,
      tenant_id: claimed.user_tenant_id || null,
      tenant_code: claimed.tenant_code || null,
      tenant_name: claimed.tenant_name || null,
      tenant_status: claimed.tenant_status || null,
      subscription_expires_at: claimed.subscription_expires_at || null,
      is_active: claimed.is_active !== false,
    };
    const tenant = user.tenant_id
      ? {
          id: user.tenant_id,
          code: claimed.tenant_code || null,
          name: claimed.tenant_name || null,
          status: claimed.tenant_status || null,
          subscription_expires_at: claimed.subscription_expires_at || null,
        }
      : null;
    const session = await createAuthenticatedSession({
      client,
      user,
      req,
      deviceFingerprint,
    });
    const payload = await buildSuccessfulAuthResponse({
      req,
      user,
      tenant,
      sessionId: session.sessionId,
      isPlatformCreator,
      twoFactor: {
        enabled: false,
        method: 'magic_link',
        trust_device_applied: false,
      },
    });

    await client.query('COMMIT');
    return res.json(payload);
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('auth.magicLink.consume error', err);
    return res
      .status(err.statusCode || 500)
      .json({ error: err.message || 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.post('/password-reset/confirm', async (req, res) => {
  const token = req.body?.token;
  const newPassword = String(
    req.body?.new_password || req.body?.password || '',
  );
  if (!normalizeAuthEmailToken(token)) {
    return res.status(400).json({ error: 'Ссылка недействительна или устарела' });
  }
  if (newPassword.trim().length < 8) {
    return res.status(400).json({
      error: 'Пароль должен быть не менее 8 символов',
    });
  }

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const claimed = await claimAuthEmailToken(client, {
      token,
      kind: 'password_reset',
      req,
    });
    if (!claimed) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'Ссылка недействительна или устарела' });
    }
    if (claimed.is_active === false) {
      await client.query('ROLLBACK');
      return res.status(403).json({
        error: String(claimed.block_reason || '').trim() ||
          'Вас заблокировали за нарушение правил',
      });
    }

    const passwordHash = await bcrypt.hash(newPassword, SALT_ROUNDS);
    await client.query(
      `UPDATE users
       SET password_hash = $2
       WHERE id = $1`,
      [claimed.id, passwordHash],
    );
    await revokeAllUserSessions({ queryable: client, userId: claimed.id });
    await revokeAllTwoFactorTrustedDevices(client, claimed.id);
    await client.query(
      `UPDATE auth_email_tokens
       SET used_at = COALESCE(used_at, now())
       WHERE user_id = $1
         AND used_at IS NULL`,
      [claimed.id],
    );

    await client.query('COMMIT');
    return res.json({
      ok: true,
      message: 'Пароль обновлён. Теперь войдите с новым паролем.',
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('auth.passwordReset.confirm error', err);
    return res
      .status(err.statusCode || 500)
      .json({ error: err.message || 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.get('/phone-access/status', authMiddleware, async (req, res) => {
  try {
    await rebalancePendingPhoneRequestOwners(db, {
      tenantId: req.user?.tenant_id || null,
    });
    const state = await resolvePhoneAccessState(db, {
      requesterUserId: req.user?.id || null,
      tenantId: req.user?.tenant_id || null,
    });
    return res.json({
      ok: true,
      data: state,
    });
  } catch (err) {
    console.error('auth.phoneAccess.status error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/phone-access/requests', authMiddleware, async (req, res) => {
  try {
    await rebalancePendingPhoneRequestOwners(db, {
      tenantId: req.user?.tenant_id || null,
    });
    const pending = await listPendingPhoneAccessRequestsForOwner(db, {
      ownerUserId: req.user?.id || null,
      tenantId: req.user?.tenant_id || null,
    });
    return res.json({
      ok: true,
      data: pending.map((row) => ({
        id: row.id,
        tenant_id: row.tenant_id || null,
        phone: row.phone || '',
        status: row.status || 'pending',
        requested_at: row.requested_at || null,
        requester_user_id: row.requester_user_id || null,
        requester_name: row.requester_name || '',
        requester_email: row.requester_email || '',
      })),
    });
  } catch (err) {
    console.error('auth.phoneAccess.requests error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/phone-access/requests/:id/decision', authMiddleware, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const requestId = String(req.params?.id || '').trim();
    const decision = String(req.body?.decision || '').trim().toLowerCase();
    const note = String(req.body?.note || '').trim();
    if (!requestId) {
      return res.status(400).json({ ok: false, error: 'id запроса обязателен' });
    }
    if (!decision) {
      return res.status(400).json({ ok: false, error: 'decision обязателен' });
    }

    await client.query('BEGIN');
    const decided = await decidePhoneAccessRequest(client, {
      requestId,
      ownerUserId: req.user?.id || null,
      tenantId: req.user?.tenant_id || null,
      decision,
      note,
    });
    if (!decided.ok || !decided.row) {
      await client.query('ROLLBACK');
      return res
        .status(decided.status || 400)
        .json({ ok: false, error: decided.error || 'Не удалось сохранить решение' });
    }
    await client.query('COMMIT');

    const io = req.app.get('io');
    if (io) {
      io.to(`user:${decided.row.requester_user_id}`).emit('phone-access:decision', {
        request_id: decided.row.id,
        status: decided.row.status,
        owner_user_id: decided.row.owner_user_id,
        requester_user_id: decided.row.requester_user_id,
        decided_at: decided.row.decided_at || null,
        note: decided.row.note || '',
      });
      io.to(`user:${decided.row.owner_user_id}`).emit('phone-access:updated', {
        request_id: decided.row.id,
        status: decided.row.status,
        requester_user_id: decided.row.requester_user_id,
      });
    }

    return res.json({
      ok: true,
      data: decided.row,
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('auth.phoneAccess.decision error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.get('/tenant/public-invite', authMiddleware, async (req, res) => {
  try {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error: 'Для создателя ссылка приглашения не требуется',
      });
    }

    const requesterRole = String(req.user?.role || '')
      .toLowerCase()
      .trim();
    if (requesterRole !== "tenant") {
      return res.status(403).json({
        ok: false,
        error: "Ссылку приглашения клиентов может создавать только арендатор",
      });
    }

    const tenantId = String(req.user?.tenant_id || '').trim();
    const tenantCode = String(req.user?.tenant_code || '').trim();
    if (!tenantId || !tenantCode) {
      return res.status(403).json({
        ok: false,
        error: 'Аккаунт не привязан к арендатору',
      });
    }

    const existing = await db.platformQuery(
      `SELECT id, code, is_active, max_uses, used_count, expires_at
       FROM tenant_invites
       WHERE tenant_id = $1
         AND role = 'client'
         AND is_active = true
         AND (expires_at IS NULL OR expires_at > now())
         AND (max_uses IS NULL OR used_count < max_uses)
       ORDER BY created_at DESC
       LIMIT 1`,
      [tenantId],
    );

    let inviteCode = '';
    let inviteId = '';

    if (existing.rowCount > 0) {
      inviteCode = String(existing.rows[0].code || '').trim();
      inviteId = String(existing.rows[0].id || '').trim();
    } else {
      let created = null;
      for (let i = 0; i < 5; i += 1) {
        const code = normalizeInviteCode(generateInviteCode());
        try {
          const insert = await db.platformQuery(
            `INSERT INTO tenant_invites (
               id, tenant_id, code, role, is_active, max_uses,
               used_count, expires_at, created_by, notes, created_at, updated_at
             )
             VALUES (
               $1, $2, $3, 'client', true, NULL,
               0, NULL, $4, 'Публичная клиентская ссылка', now(), now()
             )
             RETURNING id, code`,
            [uuidv4(), tenantId, code, req.user.id],
          );
          created = insert.rows[0];
          break;
        } catch (err) {
          if (String(err?.code || '') === '23505') continue;
          throw err;
        }
      }
      if (!created) {
        return res.status(500).json({
          ok: false,
          error: 'Не удалось создать ссылку приглашения',
        });
      }
      inviteCode = String(created.code || '').trim();
      inviteId = String(created.id || '').trim();
    }

    return res.json({
      ok: true,
      data: {
        invite_id: inviteId,
        code: inviteCode,
        tenant_code: tenantCode,
        invite_link: buildInviteLink(req, inviteCode, tenantCode),
      },
    });
  } catch (err) {
    console.error('auth.tenant.publicInvite error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/logout', authMiddleware, async (req, res) => {
  try {
    const currentSessionId = req.user?.session_id || null;
    if (currentSessionId) {
      await revokeUserSession({ queryable: db, sessionId: currentSessionId });
    }
    return res.json({ ok: true, message: 'Logged out' });
  } catch (err) {
    console.error('auth.logout error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/sessions', authMiddleware, requireTenantOrCreator, async (req, res) => {
  try {
    const rows = await listUserSessions({
      queryable: db,
      userId: req.user.id,
      currentSessionId: req.user.session_id || null,
    });
    return res.json({ ok: true, data: rows });
  } catch (err) {
    console.error('auth.sessions.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/sessions/revoke_others', authMiddleware, requireTenantOrCreator, async (req, res) => {
  try {
    const revoked = await revokeOtherUserSessions({
      queryable: db,
      userId: req.user.id,
      sessionId: req.user.session_id || null,
    });
    return res.json({ ok: true, data: { revoked } });
  } catch (err) {
    console.error('auth.sessions.revoke_others error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.delete('/sessions/:id', authMiddleware, requireTenantOrCreator, async (req, res) => {
  try {
    const sessionRecordId = String(req.params?.id || '').trim();
    if (!sessionRecordId) {
      return res.status(400).json({ ok: false, error: 'session id обязателен' });
    }
    const revoked = await revokeSessionByRecordId({
      queryable: db,
      userId: req.user.id,
      sessionRecordId,
    });
    if (!revoked) {
      return res.status(404).json({ ok: false, error: 'Сессия не найдена' });
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error('auth.sessions.revoke error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/2fa/status', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  try {
    const q = await db.query(
      `SELECT two_factor_enabled, two_factor_enabled_at
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (q.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    const row = q.rows[0];
    let backupCodesRemaining = 0;
    let trustedDevicesCount = 0;
    if (row.two_factor_enabled === true) {
      [backupCodesRemaining, trustedDevicesCount] = await Promise.all([
        countActiveBackupCodes(db, req.user.id),
        countTwoFactorTrustedDevices(db, req.user.id),
      ]);
    }
    return res.json({
      ok: true,
      data: {
        enabled: row.two_factor_enabled === true,
        enabled_at: row.two_factor_enabled_at || null,
        backup_codes_remaining: backupCodesRemaining,
        trusted_devices_count: trustedDevicesCount,
      },
    });
  } catch (err) {
    console.error('auth.2fa.status error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/2fa/setup/start', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  try {
    const q = await db.query(
      `SELECT email, name
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (q.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    const profile = q.rows[0];
    const accountName =
      String(profile.email || '').trim() ||
      String(profile.name || '').trim() ||
      `user-${req.user.id}`;
    const setup = generateTwoFactorSetup({ accountName });
    return res.json({
      ok: true,
      data: {
        secret: setup.secret,
        otpauth_url: setup.otpauthUrl,
        issuer: setup.issuer,
        account: accountName,
      },
    });
  } catch (err) {
    console.error('auth.2fa.setup.start error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/2fa/setup/confirm', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const secret = String(req.body?.secret || '').trim();
    const code = normalizeTotpCode(req.body?.code || req.body?.otp_code);
    if (!secret || !code) {
      return res.status(400).json({
        ok: false,
        error: 'Нужно передать secret и code',
      });
    }
    const valid = verifyTwoFactorCode(secret, code);
    if (!valid) {
      return res.status(400).json({
        ok: false,
        error: 'Неверный 2FA-код',
      });
    }

    await client.query('BEGIN');
    const encryptedSecret = encryptTwoFactorSecret(secret);
    await client.query(
      `UPDATE users
       SET two_factor_enabled = true,
           two_factor_secret = $2,
           two_factor_enabled_at = now()
       WHERE id = $1`,
      [req.user.id, encryptedSecret],
    );
    const backupCodes = await replaceUserBackupCodes(client, req.user.id, {
      count: BACKUP_CODES_DEFAULT_COUNT,
    });
    await revokeAllTwoFactorTrustedDevices(client, req.user.id);
    await client.query('COMMIT');
    return res.json({
      ok: true,
      data: {
        enabled: true,
        backup_codes: backupCodes,
        backup_codes_remaining: backupCodes.length,
      },
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('auth.2fa.setup.confirm error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.post('/2fa/backup-codes/regenerate', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const password = String(req.body?.password || '');
    const code = normalizeTotpCode(req.body?.code || req.body?.otp_code);
    if (!password || !code) {
      return res.status(400).json({
        ok: false,
        error: 'Нужны пароль и код 2FA',
      });
    }

    await client.query('BEGIN');
    const userQ = await client.query(
      `SELECT password_hash, two_factor_enabled, two_factor_secret
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (userQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    const user = userQ.rows[0];
    const passOk = await bcrypt.compare(password, String(user.password_hash || ''));
    if (!passOk) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Неверный пароль' });
    }
    if (user.two_factor_enabled !== true) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: 'Сначала включите 2FA',
      });
    }
    const secret = decryptTwoFactorSecret(user.two_factor_secret);
    if (!secret || !verifyTwoFactorCode(secret, code)) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: 'Неверный 2FA-код',
      });
    }

    const backupCodes = await replaceUserBackupCodes(client, req.user.id, {
      count: BACKUP_CODES_DEFAULT_COUNT,
    });
    await client.query('COMMIT');

    return res.json({
      ok: true,
      data: {
        backup_codes: backupCodes,
        backup_codes_remaining: backupCodes.length,
      },
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('auth.2fa.backupCodes.regenerate error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.get('/2fa/trusted-devices', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  try {
    const rows = await listTwoFactorTrustedDevices(db, req.user.id);
    return res.json({
      ok: true,
      data: rows.map((row) => ({
        id: row.id,
        fingerprint_mask: maskDeviceFingerprint(row.device_fingerprint),
        trusted_until: row.trusted_2fa_until || null,
        trusted_set_at: row.trusted_2fa_set_at || null,
        last_seen: row.last_seen || null,
        created_at: row.created_at || null,
      })),
    });
  } catch (err) {
    console.error('auth.2fa.trustedDevices.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/2fa/trusted-devices/revoke_all', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  try {
    const revoked = await revokeAllTwoFactorTrustedDevices(db, req.user.id);
    return res.json({ ok: true, data: { revoked } });
  } catch (err) {
    console.error('auth.2fa.trustedDevices.revokeAll error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.delete('/2fa/trusted-devices/:id', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  try {
    const deviceId = String(req.params?.id || '').trim();
    if (!deviceId) {
      return res.status(400).json({
        ok: false,
        error: 'device id обязателен',
      });
    }
    const revoked = await revokeTwoFactorTrustedDeviceById(
      db,
      req.user.id,
      deviceId,
    );
    if (!revoked) {
      return res.status(404).json({
        ok: false,
        error: 'Доверенное устройство не найдено',
      });
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error('auth.2fa.trustedDevices.revokeOne error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/2fa/disable', authMiddleware, requireTwoFactorEligible, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const password = String(req.body?.password || '');
    if (!password) {
      return res.status(400).json({
        ok: false,
        error: 'Введите пароль для отключения 2FA',
      });
    }
    const code = normalizeTotpCode(req.body?.code || req.body?.otp_code);
    await client.query('BEGIN');
    const userQ = await client.query(
      `SELECT password_hash, two_factor_enabled, two_factor_secret
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (userQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    const user = userQ.rows[0];
    const passOk = await bcrypt.compare(password, String(user.password_hash || ''));
    if (!passOk) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Неверный пароль' });
    }

    if (user.two_factor_enabled === true) {
      const secret = decryptTwoFactorSecret(user.two_factor_secret);
      if (!secret || !verifyTwoFactorCode(secret, code)) {
        await client.query('ROLLBACK');
        return res.status(400).json({
          ok: false,
          error: 'Неверный 2FA-код',
        });
      }
    }

    await client.query(
      `UPDATE users
       SET two_factor_enabled = false,
           two_factor_secret = NULL,
           two_factor_enabled_at = NULL
       WHERE id = $1`,
      [req.user.id],
    );
    await client.query(
      `DELETE FROM user_two_factor_backup_codes
       WHERE user_id = $1`,
      [req.user.id],
    );
    await revokeAllTwoFactorTrustedDevices(client, req.user.id);
    await client.query('COMMIT');
    return res.json({
      ok: true,
      data: { enabled: false },
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('auth.2fa.disable error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

/**
 * POST /api/auth/delete_account (защищённый)
 * Удаляет текущий аккаунт пользователя.
 */
router.post('/delete_account', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const identifier = String(req.body?.identifier || '').trim();
    const password = String(req.body?.password || '');
    if (!identifier || !password) {
      return res.status(400).json({
        ok: false,
        error: 'Для удаления аккаунта укажите email/номер и пароль',
      });
    }

    const profileQ = await db.query(
      `SELECT u.id, u.email, u.password_hash, p.phone
       FROM users u
       LEFT JOIN phones p ON p.user_id = u.id
       WHERE u.id = $1
       LIMIT 1`,
      [userId],
    );
    if (profileQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    const profile = profileQ.rows[0];

    const passOk = await bcrypt.compare(password, String(profile.password_hash || ''));
    if (!passOk) {
      return res.status(403).json({ ok: false, error: 'Неверный пароль' });
    }

    const normalizedInput = identifier.toLowerCase();
    const inputDigits = identifier.replace(/\D/g, '');
    const email = String(profile.email || '').trim().toLowerCase();
    const phoneDigits = String(profile.phone || '').replace(/\D/g, '');
    const samePhone =
      inputDigits.length >= 10 &&
      phoneDigits.length >= 10 &&
      (inputDigits === phoneDigits || inputDigits.slice(-10) === phoneDigits.slice(-10));
    const matchesIdentifier = normalizedInput === email || samePhone;
    if (!matchesIdentifier) {
      return res.status(403).json({
        ok: false,
        error: 'Подтверждение не совпадает с вашим email или номером телефона',
      });
    }

    const result = await db.query('DELETE FROM users WHERE id = $1 RETURNING id', [userId]);
    if (result.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    try {
      await db.platformQuery('DELETE FROM tenant_user_index WHERE user_id = $1', [userId]);
    } catch (cleanupErr) {
      console.error('auth.delete_account tenantUserIndex cleanup error', cleanupErr);
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error('auth.delete_account error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

/**
 * POST /api/auth/change_password (защищённый)
 */
router.post('/change_password', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { oldPassword, newPassword } = req.body || {};
    if (!oldPassword || !newPassword || newPassword.length < 8) {
      return res.status(400).json({ error: 'Old and new password (min 8 chars) required' });
    }

    const { rows } = await db.query('SELECT password_hash FROM users WHERE id=$1', [userId]);
    if (!rows.length) return res.status(404).json({ error: 'Пользователь не найден' });

    const currentHash = rows[0].password_hash;
    const match = await bcrypt.compare(oldPassword, currentHash);
    if (!match) return res.status(403).json({ error: 'Старый пароль неверный' });

    const newHash = await bcrypt.hash(newPassword, SALT_ROUNDS);
    await db.query('UPDATE users SET password_hash=$1 WHERE id=$2', [newHash, userId]);

    return res.json({ ok: true, message: 'Пароль изменён' });
  } catch (err) {
    console.error('auth.change_password error', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

module.exports = router;
