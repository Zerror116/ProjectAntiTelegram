// server/src/utils/auth.js
const jwt = require('jsonwebtoken');
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

function authMiddleware(req, res, next) {
  const auth = req.headers.authorization || req.headers.Authorization;
  if (NODE_ENV !== 'production') {
    console.log('AUTH HEADER:', auth);
  }

  const token = getTokenFromHeader(auth);
  if (!token) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const payload = verifyToken(token);
  if (!payload) {
    if (NODE_ENV !== 'production') {
      console.error('Token verify failed or expired');
    }
    return res.status(401).json({ error: 'Invalid token' });
  }

  // Normalize req.user to include common fields and default role
  req.user = {
    id: payload.id || payload.userId || null,
    email: payload.email || payload.sub || null,
    role: payload.role || 'client',
    ...payload
  };

  return next();
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

module.exports = { authMiddleware, requireAdmin };
