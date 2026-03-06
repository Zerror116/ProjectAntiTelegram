const db = require('../db');

const DEFAULT_ROLE_PERMISSIONS = {
  client: {
    'chat.read': true,
    'chat.write.support': true,
    'chat.write.public': false,
    'cart.buy': true,
    'delivery.respond': true,
  },
  worker: {
    'chat.read': true,
    'chat.write.private': true,
    'product.create': true,
    'product.requeue': true,
    'product.edit.own_pending': true,
  },
  admin: {
    'chat.read': true,
    'chat.write.public': true,
    'chat.pin': true,
    'chat.delete.all': true,
    'product.publish': true,
    'reservation.fulfill': true,
    'delivery.manage': true,
  },
  tenant: {
    'chat.read': true,
    'chat.write.public': true,
    'chat.pin': true,
    'chat.delete.all': true,
    'product.publish': true,
    'reservation.fulfill': true,
    'delivery.manage': true,
    'tenant.invites.manage': true,
    'tenant.users.manage': true,
  },
  creator: {
    all: true,
  },
};

function normalizeRole(role) {
  return String(role || 'client').toLowerCase().trim() || 'client';
}

function normalizePermissions(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  return raw;
}

async function loadUserRoleTemplate(queryable, userId) {
  const result = await queryable.query(
    `SELECT rt.id,
            rt.code,
            rt.title,
            rt.description,
            rt.permissions,
            rt.tenant_id,
            rt.is_system,
            urt.assigned_at
     FROM user_role_templates urt
     JOIN role_templates rt ON rt.id = urt.template_id
     WHERE urt.user_id = $1
     LIMIT 1`,
    [userId],
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

async function loadRoleTemplateByCode(queryable, role, tenantId = null) {
  const normalizedRole = normalizeRole(role);
  const result = await queryable.query(
    `SELECT id,
            code,
            title,
            description,
            permissions,
            tenant_id,
            is_system
     FROM role_templates
     WHERE code = $1
       AND (
         tenant_id = $2
         OR tenant_id IS NULL
       )
     ORDER BY CASE WHEN tenant_id = $2 THEN 0 ELSE 1 END, is_system DESC
     LIMIT 1`,
    [normalizedRole, tenantId || null],
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

async function resolvePermissionSet(user, queryable = db) {
  const role = normalizeRole(user?.role || user?.base_role || 'client');
  const baseRole = normalizeRole(user?.base_role || role);
  const tenantId = user?.tenant_id || null;

  if (baseRole === 'creator') {
    return {
      role: 'creator',
      source: 'base_role',
      template: null,
      permissions: { all: true },
    };
  }

  const assigned = await loadUserRoleTemplate(queryable, user?.id || null);
  if (assigned) {
    return {
      role,
      source: 'assigned_template',
      template: assigned,
      permissions: normalizePermissions(assigned.permissions),
    };
  }

  const byRole = await loadRoleTemplateByCode(queryable, role, tenantId);
  if (byRole) {
    return {
      role,
      source: 'role_template',
      template: byRole,
      permissions: normalizePermissions(byRole.permissions),
    };
  }

  return {
    role,
    source: 'default_map',
    template: null,
    permissions: DEFAULT_ROLE_PERMISSIONS[role] || {},
  };
}

function hasPermission(permissions, key) {
  if (!permissions || typeof permissions !== 'object') return false;
  if (permissions.all === true) return true;
  if (permissions[key] === true) return true;

  const parts = String(key || '').split('.').filter(Boolean);
  for (let i = parts.length - 1; i > 0; i -= 1) {
    const wildcard = `${parts.slice(0, i).join('.')}.*`;
    if (permissions[wildcard] === true) return true;
  }

  return false;
}

module.exports = {
  DEFAULT_ROLE_PERMISSIONS,
  normalizeRole,
  resolvePermissionSet,
  hasPermission,
};
