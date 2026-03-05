// server/src/utils/auth.js
const jwt = require('jsonwebtoken');
const db = require('../db');
const { isTenantActive, isPlatformCreatorEmail } = require('./tenants');
const { touchUserSession } = require('./sessions');
require('dotenv').config();

const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
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
    return jwt.verify(token, JWT_SECRET);
  } catch (err) {
    if (NODE_ENV !== 'production') {
      console.error('jwt.verify error:', err && err.message ? err.message : err);
    }
    return null;
  }
}

async function resolveAuthContextFromToken(token, requestedViewRole = '') {
  const payload = verifyToken(token);
  if (!payload) {
    return { ok: false, status: 401, error: 'Invalid token' };
  }

  const userId = payload.id || payload.userId || payload.sub || null;
  const sessionId = payload.sid || payload.session_id || null;
  if (!userId) {
    return { ok: false, status: 401, error: 'Unauthorized' };
  }

  if (sessionId) {
    const sessionAlive = await touchUserSession({
      queryable: db,
      sessionId: String(sessionId),
    });
    if (!sessionAlive) {
      return { ok: false, status: 401, error: 'Сессия истекла или отозвана' };
    }
  }

  const userRes = await db.query(
    `SELECT u.id, u.email, u.role, u.is_active, u.tenant_id,
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

  if (userRes.rowCount === 0) {
    return { ok: false, status: 401, error: 'Unauthorized' };
  }

  const row = userRes.rows[0];
  if (row.is_active === false) {
    return { ok: false, status: 403, error: 'Аккаунт отключён' };
  }

  const baseRole = (row.role || 'client').toString().toLowerCase().trim() || 'client';
  const isPlatformCreator = baseRole === 'creator' && isPlatformCreatorEmail(row.email);

  if (!isPlatformCreator) {
    if (!row.tenant_id) {
      return {
        ok: false,
        status: 403,
        error: 'Аккаунт не привязан к арендатору. Обратитесь к владельцу приложения.',
      };
    }
    const tenantState = isTenantActive({
      status: row.tenant_status,
      subscription_expires_at: row.subscription_expires_at,
    });
    if (!tenantState.ok) {
      return {
        ok: false,
        status: tenantState.reason === 'tenant_expired' ? 402 : 403,
        error: tenantState.error,
      };
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
    role: effectiveRole,
    base_role: baseRole,
    effective_role: effectiveRole,
    view_role: effectiveRole !== baseRole ? effectiveRole : null,
    tenant_id: row.tenant_id || null,
    tenant_code: row.tenant_code || null,
    tenant_name: row.tenant_name || null,
    tenant_status: row.tenant_status || null,
    subscription_expires_at: row.subscription_expires_at || null,
    is_platform_creator: isPlatformCreator,
    session_id: sessionId ? String(sessionId) : null,
  };

  return { ok: true, user };
}

async function authMiddleware(req, res, next) {
  const auth = req.headers.authorization || req.headers.Authorization;
  if (NODE_ENV !== 'production') {
    console.log('AUTH HEADER:', auth);
  }

  const token = getTokenFromHeader(auth);
  if (!token) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    const context = await resolveAuthContextFromToken(
      token,
      req.headers['x-view-role'],
    );
    if (!context.ok) {
      if (NODE_ENV !== 'production') {
        console.error('Token verify failed or access blocked:', context.error);
      }
      return res.status(context.status || 401).json({ error: context.error || 'Unauthorized' });
    }
    req.user = context.user;
    return next();
  } catch (err) {
    console.error('authMiddleware error:', err);
    return res.status(500).json({ error: 'Server error' });
  }
}

function requireAdmin(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Unauthorized' });
  const isAdminFlag = !!req.user.isAdmin;
  const role = (req.user.role || '').toString().toLowerCase();
  if (!isAdminFlag && role !== 'admin' && role !== 'creator' && role !== 'superadmin') {
    return res.status(403).json({ error: 'Forbidden' });
  }
  return next();
}

module.exports = { authMiddleware, requireAdmin, resolveAuthContextFromToken };
