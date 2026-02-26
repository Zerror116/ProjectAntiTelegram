const jwt = require('jsonwebtoken');

module.exports = function requireAuth(req, res, next) {
  try {
    const authHeader = req.headers.authorization;

    console.log('AUTH HEADER:', authHeader);

    if (!authHeader) {
      return res.status(401).json({
        ok: false,
        error: 'No token provided'
      });
    }

    if (!authHeader.startsWith('Bearer ')) {
      return res.status(401).json({
        ok: false,
        error: 'Invalid token format'
      });
    }

    const token = authHeader.substring(7);

    const decoded = jwt.verify(
      token,
      process.env.JWT_SECRET || 'dev_secret'
    );

    console.log('JWT DECODED:', decoded);

    // КРИТИЧЕСКИЙ FIX
    req.user = {
      id: decoded.id,
      email: decoded.email,
      role: decoded.role
    };

    next();

  } catch (err) {
    console.error('AUTH ERROR:', err.message);

    return res.status(401).json({
      ok: false,
      error: 'Invalid token'
    });
  }
};