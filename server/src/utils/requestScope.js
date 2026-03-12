const db = require('../db');

function normalizeTenantCode(raw) {
  return db.normalizeTenantCode(raw || '');
}

function normalizeTenantId(raw) {
  const value = String(raw || '').trim();
  return value || null;
}

async function runInRequestTenantScope(req, fn) {
  if (typeof fn !== 'function') {
    throw new Error('runInRequestTenantScope: fn must be a function');
  }
  const user = req?.user || {};
  if (user?.is_platform_creator === true) {
    return db.runWithPlatform(fn);
  }

  const tenantCode = normalizeTenantCode(user?.tenant_code || user?.tenantCode || '');
  if (tenantCode) {
    return db.runWithTenantCode(tenantCode, fn);
  }

  const tenantId = normalizeTenantId(user?.tenant_id || user?.tenantId || null);
  if (tenantId) {
    return db.runWithTenantId(tenantId, fn);
  }

  return db.runWithPlatform(fn);
}

module.exports = {
  runInRequestTenantScope,
};

