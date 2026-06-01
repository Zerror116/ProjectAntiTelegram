// server/src/utils/auth.js
const jwt = require('jsonwebtoken');
const db = require('../db');
const { isTenantActive, isPlatformCreatorEmail } = require('./tenants');
const { touchUserSession } = require('./sessions');
const { resolvePhoneAccessState } = require('./phoneAccess');
const {
  ensurePlatformDiscussionUserShadow,
  ensurePlatformDiscussionsChat,
} = require('./systemChannels');
require('dotenv').config();

const JWT_FALLBACK_SECRET = String(process.env.JWT_SECRET || '').trim();
const NODE_ENV = process.env.NODE_ENV || 'development';

let verifyTokenFn = null;
// Try to use local jwt util if present (server/src/utils/jwt.js)
try {
  // eslint-disable-next-line global-require
  const { verifyJwt } = require('./jwt');
  if (typeof verifyJwt === 'function') verifyTokenFn = (token) => verifyJwt(token);
} catch (e) {
  // ignore, fallback to jwt.verify below
  verifyTokenFn = null;
}

function getTokenFromHeader(authHeader) {
  if (!authHeader) return null;
  if (authHeader.startsWith('Bearer ')) return authHeader.slice(7);
  if (authHeader.startsWith('bearer ')) return authHeader.slice(7);
  return null;
}

function verifyToken(token) {
  if (!token) return null;
  if (verifyTokenFn) {
    try {
      return verifyTokenFn(token);
    } catch (e) {
      if (NODE_ENV !== 'production') console.error('verifyJwt util error:', e && e.message ? e.message : e);
      return null;
    }
  }
  try {
    if (!JWT_FALLBACK_SECRET) return null;
    return jwt.verify(token, JWT_FALLBACK_SECRET);
  } catch (err) {
    if (NODE_ENV !== 'production') {
      console.error('jwt.verify error:', err && err.message ? err.message : err);
    }
    return null;
  }
}

function decodeJwtPayloadUnsafe(token) {
  try {
    const parts = String(token || '').split('.');
    if (parts.length < 2) return null;
    const payloadPart = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const normalized = payloadPart.padEnd(
      payloadPart.length + ((4 - (payloadPart.length % 4)) % 4),
      '=',
    );
    const json = Buffer.from(normalized, 'base64').toString('utf8');
    return JSON.parse(json);
  } catch (_) {
    return null;
  }
}

function isSharedTenantMode(tenantRow) {
  return String(tenantRow?.db_mode || '')
    .toLowerCase()
    .trim() === 'shared';
}

function isSubscriptionRestrictedRole(role) {
  const normalized = String(role || '').toLowerCase().trim();
  return normalized === 'tenant' || normalized === 'admin' || normalized === 'worker';
}

function isSubscriptionRestrictionReason(reason) {
  const normalized = String(reason || '').toLowerCase().trim();
  return normalized === 'tenant_blocked' ||
    normalized === 'tenant_expired' ||
    normalized === 'tenant_expiry_invalid';
}

function isProfileProbeRequest(req) {
  const method = String(req?.method || '').toUpperCase().trim();
  const fullPath = `${String(req?.baseUrl || '').trim()}${String(
    req?.path || '',
  ).trim()}`.toLowerCase();
  if (method === 'POST' && fullPath === '/api/auth/refresh/bootstrap') {
    return true;
  }
  if (method !== 'GET') return false;
  const baseUrl = String(req?.baseUrl || '').toLowerCase().trim();
  const path = String(req?.path || '').toLowerCase().trim();
  return baseUrl === '/api/profile' && (path === '' || path === '/');
}

function isPhoneAccessRestrictionState(state) {
  const normalized = String(state || '').toLowerCase().trim();
  return normalized === 'pending' || normalized === 'rejected';
}

function isPhoneAccessBypassRequest(req) {
  const method = String(req?.method || '').toUpperCase().trim();
  const fullPath = `${String(req?.baseUrl || '').trim()}${String(
    req?.path || '',
  ).trim()}`;
  if (
    method === 'GET' &&
    (fullPath === '/api/profile' || fullPath === '/api/profile/')
  ) {
    return true;
  }
  if (method === 'POST' && fullPath === '/api/auth/logout') return true;
  if (method === 'GET' && fullPath === '/api/auth/phone-access/status') {
    return true;
  }
  if (method === 'GET' && fullPath === '/api/auth/phone-access/requests') {
    return true;
  }
  if (
    method === 'POST' &&
    /^\/api\/auth\/phone-access\/requests\/[^/]+\/decision$/i.test(fullPath)
  ) {
    return true;
  }
  return false;
}

function normalizeRequestUuid(raw) {
  const value = String(raw || '').trim();
  if (
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  ) {
    return value;
  }
  return '';
}

function extractChatIdFromRequest(req) {
  return (
    normalizeRequestUuid(req?.params?.chatId) ||
    normalizeRequestUuid(req?.body?.chat_id || req?.body?.chatId) ||
    normalizeRequestUuid(req?.query?.chat_id || req?.query?.chatId)
  );
}

function extractUploadSessionIdFromRequest(req) {
  return (
    normalizeRequestUuid(req?.params?.sessionId) ||
    normalizeRequestUuid(req?.body?.session_id || req?.body?.sessionId) ||
    normalizeRequestUuid(req?.query?.session_id || req?.query?.sessionId)
  );
}

async function shouldUsePlatformDiscussionContext(req) {
  const baseUrl = String(req?.baseUrl || '').toLowerCase().trim();
  if (!baseUrl.endsWith('/api/chats')) return false;
  const chatId = extractChatIdFromRequest(req);
  try {
    if (chatId) {
      const result = await db.platformQuery(
        `SELECT 1
         FROM chats
         WHERE id = $1
           AND type = 'private'
           AND COALESCE(settings->>'system_key', '') = 'platform_discussions'
         LIMIT 1`,
        [chatId],
      );
      return result.rowCount > 0;
    }

    const sessionId = extractUploadSessionIdFromRequest(req);
    if (!sessionId) return false;
    const sessionQ = await db.platformQuery(
      `SELECT 1
       FROM chat_upload_sessions s
       JOIN chats c ON c.id = s.chat_id
       WHERE s.id = $1
         AND c.type = 'private'
         AND COALESCE(c.settings->>'system_key', '') = 'platform_discussions'
       LIMIT 1`,
      [sessionId],
    );
    return sessionQ.rowCount > 0;
  } catch (err) {
    console.error('platform discussion context check error:', err);
    return false;
  }
}

async function resolveCreatorTenantScope(requestedTenantCode = '') {
  const normalizedTenantCode = db.normalizeTenantCode(requestedTenantCode);
  if (!normalizedTenantCode) return null;
  const tenantRes = await db.platformQuery(
    `SELECT id,
            code,
            name,
            status,
            subscription_expires_at,
            db_mode,
            db_url,
            db_name,
            db_schema,
            COALESCE(is_deleted, false) AS is_deleted
     FROM tenants
     WHERE lower(code) = $1
     LIMIT 1`,
    [normalizedTenantCode],
  );
  if (tenantRes.rowCount === 0) return null;
  const tenantRow = tenantRes.rows[0];
  if (tenantRow?.is_deleted === true) return null;
  return tenantRow;
}

function normalizeScopedUserRole(rawRole) {
  const role = String(rawRole || 'client').toLowerCase().trim();
  if (['client', 'worker', 'admin', 'tenant', 'creator'].includes(role)) {
    return role;
  }
  return 'client';
}

async function ensureScopedAuthUserShadowRow(user, tenantScope) {
  const userId = String(user?.id || '').trim();
  const tenantId = String(tenantScope?.id || user?.tenant_id || '').trim();
  if (!userId || !tenantId) return;

  if (
    user?.is_platform_creator === true &&
    !db.isIsolatedTenantRow(tenantScope) &&
    !db.isSchemaIsolatedTenantRow(tenantScope)
  ) {
    // Shared tenants use one public users table. A platform creator already has a
    // global users.id row, so a per-tenant shadow row with the same UUID cannot
    // be created without fighting RLS/primary-key ownership.
    return;
  }

  const email = String(user?.email || '').trim().toLowerCase();
  const name = String(user?.name || '').trim();
  const role = normalizeScopedUserRole(user?.base_role || user?.role);

  await db.query(
    `INSERT INTO users (
       id,
       email,
       role,
       name,
       is_active,
       tenant_id,
       created_at,
       updated_at
     )
     VALUES (
       $1::uuid,
       NULLIF($2::text, ''),
       $3::text,
       NULLIF($4::text, ''),
       true,
       $5::uuid,
       now(),
       now()
     )
     ON CONFLICT (id)
     DO UPDATE SET
       email = COALESCE(NULLIF(users.email, ''), EXCLUDED.email),
       role = COALESCE(NULLIF(users.role, ''), EXCLUDED.role),
       name = COALESCE(NULLIF(users.name, ''), EXCLUDED.name),
       tenant_id = COALESCE(users.tenant_id, EXCLUDED.tenant_id),
       is_active = true,
       updated_at = now()`,
    [userId, email, role, name, tenantId],
  );
}

async function resolveAuthContextFromToken(
  token,
  requestedViewRole = '',
  options = {},
) {
  const ignoreTenantSubscription = options?.ignoreTenantSubscription === true;
  const requestedTenantCode = db.normalizeTenantCode(
    options?.requestedTenantCode || '',
  );
  const unsafePayload = decodeJwtPayloadUnsafe(token) || {};
  const tenantCodeHint = db.normalizeTenantCode(
    unsafePayload.tenant_code ||
      unsafePayload.tenantCode ||
      unsafePayload.tcode ||
      '',
  );
  const tenantIdHint = String(
    unsafePayload.tenant_id ||
      unsafePayload.tenantId ||
      '',
  ).trim();

  const payload = verifyToken(token);
  if (!payload) {
    return { ok: false, status: 401, error: 'Invalid token' };
  }

  const userId = payload.id || payload.userId || payload.sub || null;
  const sessionId = payload.sid || payload.session_id || null;
  if (!userId) {
    return { ok: false, status: 401, error: 'Unauthorized' };
  }

  let tenantScope = null;
  if (tenantCodeHint) {
    tenantScope = await db.resolveTenantByCode(tenantCodeHint);
  } else if (tenantIdHint) {
    tenantScope = await db.resolveTenantById(tenantIdHint);
  }

  if (sessionId) {
    const touchSession = async () =>
      await touchUserSession({
        queryable: db,
        sessionId: String(sessionId),
      });
    const sessionAlive = tenantScope
      ? await db.runWithTenantRow(tenantScope, touchSession)
      : await db.runWithPlatform(touchSession);
    if (!sessionAlive) {
      return { ok: false, status: 401, error: 'Сессия истекла или отозвана' };
    }
  }

  const lookupUser = async () =>
    await db.query(
      `SELECT u.id, u.email, u.name, u.role, u.is_active, u.block_reason, u.tenant_id,
              t.code AS tenant_code,
              t.name AS tenant_name,
              t.status AS tenant_status,
              t.subscription_expires_at
       FROM users u
       LEFT JOIN tenants t ON t.id = u.tenant_id
       WHERE u.id = $1
       LIMIT 1`,
      [userId],
    );

  const userRes = tenantScope
    ? await db.runWithTenantRow(tenantScope, lookupUser)
    : await db.runWithPlatform(lookupUser);
  let row = userRes.rows[0] || null;
  let creatorIdentitySource = tenantScope ? 'tenant' : 'platform';
  if (!row && tenantScope) {
    const platformUserRes = await db.runWithPlatform(lookupUser);
    const platformRow = platformUserRes.rows[0] || null;
    const platformRole =
      (platformRow?.role || 'client').toString().toLowerCase().trim() || 'client';
    const isPlatformCreatorRow =
      platformRole === 'creator' && isPlatformCreatorEmail(platformRow?.email);
    if (isPlatformCreatorRow) {
      row = platformRow;
      creatorIdentitySource = 'platform_fallback';
    }
  }
  if (!row) {
    return { ok: false, status: 401, error: 'Unauthorized' };
  }
  if (row.is_active === false) {
    const blockReason = String(row.block_reason || '').trim();
    return {
      ok: false,
      status: 403,
      error:
        blockReason ||
        'Вас заблокировали за нарушение правил',
    };
  }

  const baseRole = (row.role || 'client').toString().toLowerCase().trim() || 'client';
  const isPlatformCreator = baseRole === 'creator' && isPlatformCreatorEmail(row.email);

  let tenantRegistry = null;
  if (isPlatformCreator) {
    tenantRegistry = await resolveCreatorTenantScope(requestedTenantCode);
  } else {
    const effectiveTenantCode = db.normalizeTenantCode(
      tenantCodeHint || row.tenant_code || '',
    );
    if (!row.tenant_id || !effectiveTenantCode) {
      return {
        ok: false,
        status: 403,
        error: 'Аккаунт не привязан к арендатору. Обратитесь к владельцу приложения.',
      };
    }

    const tenantRes = await db.platformQuery(
      `SELECT id, code, name, status, subscription_expires_at, db_mode, db_url, db_name, db_schema
       FROM tenants
       WHERE lower(code) = $1
       LIMIT 1`,
      [effectiveTenantCode],
    );
    if (tenantRes.rowCount === 0) {
      return {
        ok: false,
        status: 403,
        error: 'Арендатор не найден. Обратитесь к владельцу приложения.',
      };
    }
    tenantRegistry = tenantRes.rows[0];

    const normalizedTenantCode = String(tenantRegistry.code || '')
      .toLowerCase()
      .trim();
    if (isSharedTenantMode(tenantRegistry) && normalizedTenantCode !== 'default') {
      return {
        ok: false,
        status: 503,
        error:
          'Арендатор временно недоступен: требуется изолированная база данных. Обратитесь к создателю приложения.',
      };
    }

    const shouldEnforceTenantSubscription =
      !ignoreTenantSubscription && isSubscriptionRestrictedRole(baseRole);
    if (shouldEnforceTenantSubscription) {
      const tenantState = isTenantActive({
        status: tenantRegistry.status,
        subscription_expires_at: tenantRegistry.subscription_expires_at,
      });
      if (!tenantState.ok) {
        return {
          ok: false,
          status: tenantState.reason === 'tenant_expired' ? 402 : 403,
          reason: tenantState.reason,
          error: tenantState.error,
        };
      }
    }
  }

  const rawViewRole = String(requestedViewRole || '').toLowerCase().trim();
  const allowedViewRoles = new Set(['client', 'worker', 'admin', 'creator']);
  const effectiveRole =
    baseRole === 'creator' && allowedViewRoles.has(rawViewRole) && rawViewRole
      ? rawViewRole
      : baseRole;

  const user = {
    ...payload,
    id: row.id,
    email: row.email,
    name: row.name || null,
    role: effectiveRole,
    base_role: baseRole,
    effective_role: effectiveRole,
    view_role: effectiveRole !== baseRole ? effectiveRole : null,
    tenant_id: tenantRegistry?.id || row.tenant_id || null,
    tenant_code: tenantRegistry?.code || row.tenant_code || tenantCodeHint || null,
    tenant_name: tenantRegistry?.name || row.tenant_name || null,
    tenant_status: tenantRegistry?.status || row.tenant_status || null,
    subscription_expires_at:
      tenantRegistry?.subscription_expires_at ||
      row.subscription_expires_at ||
      null,
    is_platform_creator: isPlatformCreator,
    is_creator_tenant_scoped: isPlatformCreator && !!tenantRegistry,
    creator_identity_source: isPlatformCreator ? creatorIdentitySource : null,
    session_id: sessionId ? String(sessionId) : null,
  };

  if (!isPlatformCreator && baseRole === 'client' && row.tenant_id) {
    try {
      const readPhoneAccess = async () =>
        await resolvePhoneAccessState(db, {
          requesterUserId: row.id,
          tenantId: row.tenant_id || null,
        });
      const phoneAccessState = tenantRegistry
        ? await db.runWithTenantRow(tenantRegistry, readPhoneAccess)
        : await db.runWithPlatform(readPhoneAccess);
      if (phoneAccessState && phoneAccessState.state) {
        user.phone_access_state = phoneAccessState.state;
        user.phone_access = phoneAccessState;
      }
    } catch (err) {
      if (NODE_ENV !== 'production') {
        console.error(
          'resolveAuthContextFromToken phone access state error:',
          err && err.message ? err.message : err,
        );
      }
    }
  }

  return { ok: true, user, tenantScope: tenantRegistry || tenantScope || null };
}

async function authMiddleware(req, res, next) {
  const auth = req.headers.authorization || req.headers.Authorization;
  if (NODE_ENV !== 'production') {
    const safeAuth =
      typeof auth === 'string' && auth.toLowerCase().startsWith('bearer ')
        ? `Bearer ${String(auth.slice(7)).slice(0, 8)}...`
        : auth;
    console.log('AUTH HEADER:', safeAuth);
  }

  const token = getTokenFromHeader(auth);
  if (!token) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    let context = await resolveAuthContextFromToken(
      token,
      req.headers['x-view-role'],
      { requestedTenantCode: req.headers['x-tenant-code'] },
    );
    if (!context.ok &&
        isSubscriptionRestrictionReason(context.reason) &&
        isProfileProbeRequest(req)) {
      const blockedReason = context.reason;
      context = await resolveAuthContextFromToken(
        token,
        req.headers['x-view-role'],
        {
          ignoreTenantSubscription: true,
          requestedTenantCode: req.headers['x-tenant-code'],
        },
      );
      if (context.ok) {
        req.subscriptionRestricted = true;
        req.subscriptionRestrictionReason = blockedReason || 'tenant_subscription';
      }
    }
    if (!context.ok) {
      if (NODE_ENV !== 'production') {
        console.error('Token verify failed or access blocked:', context.error);
      }
      return res.status(context.status || 401).json({
        error: context.error || 'Unauthorized',
        code: context.reason || null,
      });
    }
    req.user = context.user;
    const usePlatformDiscussionContext = await shouldUsePlatformDiscussionContext(req);
    if (
      isPhoneAccessRestrictionState(req.user?.phone_access_state) &&
      !isPhoneAccessBypassRequest(req)
    ) {
      const state = String(req.user?.phone_access_state || '').trim();
      const message =
        state === 'rejected'
          ? 'Владелец номера отклонил запрос. Обновите номер телефона в профиле.'
          : 'Ожидается разрешение первого владельца номера.';
      return res.status(423).json({
        error: message,
        code: `phone_access_${state || 'restricted'}`,
        phone_access: req.user?.phone_access || null,
      });
    }
    if (context.user?.is_platform_creator === true && !context.tenantScope) {
      return db.runWithPlatform(() => next());
    }
    if (usePlatformDiscussionContext) {
      const baseRole = String(context.user?.base_role || context.user?.role || '')
        .toLowerCase()
        .trim();
      if (baseRole === 'tenant' || baseRole === 'creator') {
        await ensurePlatformDiscussionUserShadow(db.platformPool, context.user);
        await ensurePlatformDiscussionsChat(db.platformPool, context.user.id);
      }
      return db.runWithPlatform(() => next());
    }
    if (context.tenantScope) {
      return db
        .runWithTenantRow(context.tenantScope, async () => {
          try {
            await ensureScopedAuthUserShadowRow(context.user, context.tenantScope);
            return next();
          } catch (err) {
            console.error('authMiddleware tenant shadow user sync error:', err);
            if (!res.headersSent) {
              return res.status(500).json({ error: 'Server error' });
            }
            return undefined;
          }
        })
        .catch((err) => {
          console.error('authMiddleware tenant context error:', err);
          if (!res.headersSent) {
            return res.status(500).json({ error: 'Server error' });
          }
          return undefined;
        });
    }
    return db.runWithPlatform(() => next());
  } catch (err) {
    console.error('authMiddleware error:', err);
    return res.status(500).json({ error: 'Server error' });
  }
}

function requireAdmin(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Unauthorized' });
  const isAdminFlag = !!req.user.isAdmin;
  const role = (req.user.role || '').toString().toLowerCase();
  if (
    !isAdminFlag &&
    role !== 'admin' &&
    role !== 'tenant' &&
    role !== 'creator' &&
    role !== 'superadmin'
  ) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  return next();
}

module.exports = { authMiddleware, requireAdmin, resolveAuthContextFromToken };
