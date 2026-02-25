// server/src/utils/roles.js
function requireRole(...allowed) {
  return (req, res, next) => {
    try {
      const role = req.user && req.user.role;
      if (!role || !allowed.includes(role)) {
        return res.status(403).json({ ok: false, error: 'Forbidden' });
      }
      return next();
    } catch (err) {
      console.error('requireRole error', err);
      return res.status(500).json({ ok: false, error: 'Server error' });
    }
  };
}

module.exports = { requireRole };
