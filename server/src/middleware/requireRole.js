// server/src/middleware/requireRole.js
function normalizeRole(raw) {
  return String(raw || "").toLowerCase().trim();
}

function normalizeAllowedRoles(allowedRoles) {
  const normalized = new Set(
    (allowedRoles || [])
      .map((item) => normalizeRole(item))
      .filter(Boolean),
  );
  // Арендатор имеет права не ниже администратора.
  if (normalized.has("admin")) normalized.add("tenant");
  return normalized;
}

module.exports = function requireRole(...allowedRoles) {
  const allowed = normalizeAllowedRoles(allowedRoles);
  return (req, res, next) => {
    const user = req.user;
    if (!user) return res.status(401).json({ error: "Unauthorized" });
    const role = normalizeRole(user.role);
    if (!role) return res.status(403).json({ error: "Forbidden" });
    if (allowed.has(role)) return next();
    return res.status(403).json({ error: "Forbidden" });
  };
};
