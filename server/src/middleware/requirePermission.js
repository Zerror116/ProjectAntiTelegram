const db = require('../db');
const { resolvePermissionSet, hasPermission } = require('../utils/flexibleRoles');

function normalizeRole(role) {
  return String(role || '').toLowerCase().trim();
}

function normalizePermissions(args) {
  if (args.length === 1 && Array.isArray(args[0])) {
    return args[0]
      .map((item) => String(item || '').trim())
      .filter(Boolean);
  }
  return args.map((item) => String(item || '').trim()).filter(Boolean);
}

module.exports = function requirePermission(...permissionsArgs) {
  const requiredPermissions = normalizePermissions(permissionsArgs);
  if (requiredPermissions.length === 0) {
    throw new Error('requirePermission: at least one permission is required');
  }

  return async (req, res, next) => {
    try {
      if (!req.user) {
        return res.status(401).json({ ok: false, error: 'Unauthorized' });
      }

      // Если создатель не в режиме просмотра другой роли — полный доступ.
      const role = normalizeRole(req.user.role);
      const baseRole = normalizeRole(req.user.base_role || req.user.role);
      const viewRole = normalizeRole(req.user.view_role || '');
      if (baseRole === 'creator' && (!viewRole || viewRole === 'creator') && role === 'creator') {
        return next();
      }

      const resolved = await resolvePermissionSet(req.user, db);
      req.permissionSet = resolved;

      if (requiredPermissions.some((permission) => hasPermission(resolved.permissions, permission))) {
        return next();
      }

      return res.status(403).json({
        ok: false,
        error: 'Недостаточно прав',
        code: 'PERMISSION_DENIED',
        required_permissions: requiredPermissions,
      });
    } catch (err) {
      console.error('requirePermission error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  };
};
