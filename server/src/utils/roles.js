// server/src/utils/roles.js
function normalizeRole(raw) {
  return String(raw || "").toLowerCase().trim();
}

function normalizeAllowed(allowed) {
  const normalized = new Set(
    (allowed || [])
      .map((item) => normalizeRole(item))
      .filter(Boolean),
  );
  // Арендатору доступны админские операции.
  if (normalized.has("admin")) normalized.add("tenant");
  return normalized;
}

function requireRole(...allowed) {
  const normalizedAllowed = normalizeAllowed(allowed);
  return (req, res, next) => {
    try {
      const role = normalizeRole(req.user && req.user.role);
      if (!role || !normalizedAllowed.has(role)) {
        return res.status(403).json({ ok: false, error: "Forbidden" });
      }
      return next();
    } catch (err) {
      console.error("requireRole error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  };
}

module.exports = { requireRole };
