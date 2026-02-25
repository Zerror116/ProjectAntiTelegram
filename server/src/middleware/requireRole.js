// server/src/middleware/requireRole.js
module.exports = function requireRole(...allowedRoles) {
  return (req, res, next) => {
    const user = req.user;
    if (!user) return res.status(401).json({ error: 'Unauthorized' });
    const role = user.role;
    if (!role) return res.status(403).json({ error: 'Forbidden' });
    if (allowedRoles.includes(role)) return next();
    return res.status(403).json({ error: 'Forbidden' });
  };
};
