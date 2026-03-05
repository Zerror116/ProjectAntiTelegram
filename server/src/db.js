// server/src/db.js
const { AsyncLocalStorage } = require('async_hooks');
const { Pool } = require('pg');
require('dotenv').config();

const DEFAULT_DATABASE_URL =
  process.env.DATABASE_URL ||
  'postgresql://antitelegram:antitelegram@localhost:5432/antitelegram';

const platformPool = new Pool({
  connectionString: DEFAULT_DATABASE_URL,
});

const contextStorage = new AsyncLocalStorage();
const tenantPoolCache = new Map();

function currentContext() {
  return contextStorage.getStore() || null;
}

function currentPool() {
  const scopedPool = currentContext()?.pool;
  return scopedPool || platformPool;
}

function normalizeTenantCode(raw) {
  return String(raw || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, '');
}

function isIsolatedTenantRow(row) {
  const mode = String(row?.db_mode || '')
    .toLowerCase()
    .trim();
  const dbUrl = String(row?.db_url || '').trim();
  return mode === 'isolated' && dbUrl.length > 0;
}

async function resolveTenantByCode(tenantCode) {
  const normalized = normalizeTenantCode(tenantCode);
  if (!normalized) return null;
  const result = await platformPool.query(
    `SELECT id,
            code,
            name,
            status,
            subscription_expires_at,
            db_mode,
            db_url,
            db_name
     FROM tenants
     WHERE lower(code) = $1
     LIMIT 1`,
    [normalized],
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

async function resolveTenantById(tenantId) {
  const normalized = String(tenantId || '').trim();
  if (!normalized) return null;
  const result = await platformPool.query(
    `SELECT id,
            code,
            name,
            status,
            subscription_expires_at,
            db_mode,
            db_url,
            db_name
     FROM tenants
     WHERE id = $1
     LIMIT 1`,
    [normalized],
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

async function getOrCreateTenantPool(tenantRow) {
  if (!isIsolatedTenantRow(tenantRow)) {
    return platformPool;
  }

  const dbUrl = String(tenantRow.db_url || '').trim();
  const cached = tenantPoolCache.get(dbUrl);
  if (cached) return cached;

  const pool = new Pool({ connectionString: dbUrl });
  await pool.query('SELECT 1');
  tenantPoolCache.set(dbUrl, pool);
  return pool;
}

async function runWithDbContext(context, fn) {
  return await new Promise((resolve, reject) => {
    contextStorage.run(context, () => {
      Promise.resolve()
        .then(fn)
        .then(resolve)
        .catch(reject);
    });
  });
}

async function runWithTenantRow(tenantRow, fn) {
  if (!tenantRow) {
    return runWithDbContext(
      {
        pool: platformPool,
        tenant: null,
        source: 'platform',
      },
      fn,
    );
  }

  const pool = await getOrCreateTenantPool(tenantRow);
  return runWithDbContext(
    {
      pool,
      tenant: tenantRow,
      source: isIsolatedTenantRow(tenantRow) ? 'tenant-isolated' : 'shared',
    },
    fn,
  );
}

async function runWithTenantCode(tenantCode, fn) {
  const tenantRow = await resolveTenantByCode(tenantCode);
  if (!tenantRow) {
    const error = new Error('Tenant not found');
    error.code = 'TENANT_NOT_FOUND';
    throw error;
  }
  return runWithTenantRow(tenantRow, fn);
}

async function runWithTenantId(tenantId, fn) {
  const tenantRow = await resolveTenantById(tenantId);
  if (!tenantRow) {
    const error = new Error('Tenant not found');
    error.code = 'TENANT_NOT_FOUND';
    throw error;
  }
  return runWithTenantRow(tenantRow, fn);
}

async function runWithPlatform(fn) {
  return runWithDbContext(
    {
      pool: platformPool,
      tenant: null,
      source: 'platform',
    },
    fn,
  );
}

function query(text, params) {
  return currentPool().query(text, params);
}

function platformQuery(text, params) {
  return platformPool.query(text, params);
}

function platformConnect() {
  return platformPool.connect();
}

const poolProxy = new Proxy(
  {},
  {
    get(_target, prop) {
      const pool = currentPool();
      const value = pool[prop];
      if (typeof value === 'function') {
        return value.bind(pool);
      }
      return value;
    },
  },
);

function currentTenantContext() {
  return currentContext();
}

module.exports = {
  // Context-aware (tenant scoped when context present)
  query,
  pool: poolProxy,

  // Platform DB primitives (always central DB)
  platformPool,
  platformQuery,
  platformConnect,

  // Tenant helpers
  normalizeTenantCode,
  isIsolatedTenantRow,
  resolveTenantByCode,
  resolveTenantById,
  runWithTenantRow,
  runWithTenantCode,
  runWithTenantId,
  runWithPlatform,
  currentTenantContext,
};
