// server/src/utils/auth.js
const jwt = require('jsonwebtoken');
require('dotenv').config();
const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const NODE_ENV = process.env.NODE_ENV || 'development';

function getTokenFromHeader(authHeader) {
  if (!authHeader) return null;
  if (authHeader.startsWith('Bearer ')) return authHeader.slice(7);
  if (authHeader.startsWith('bearer ')) return authHeader.slice(7);
  return null;
}

function authMiddleware(req, res, next) {
  const auth = req.headers.authorization;
  if (NODE_ENV !== 'production') {
    console.log('AUTH HEADER:', auth);
  }

  const token = getTokenFromHeader(auth);
  if (!token) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  try {
    const payload = jwt.verify(token, JWT_SECRET);
    req.user = payload;
    return next();
  } catch (err) {
    if (NODE_ENV !== 'production') {
      console.error('Token verify error:', err && err.message ? err.message : err);
    }
    return res.status(401).json({ error: 'Invalid token' });
  }
}

function requireAdmin(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Unauthorized' });
  if (!req.user.isAdmin) return res.status(403).json({ error: 'Forbidden' });
  return next();
}

module.exports = { authMiddleware, requireAdmin };
