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

function resolveTenantSettingValue(ctx = currentContext()) {
  const tenantId = String(ctx?.tenant?.id || "").trim();
  return tenantId;
}

async function applyClientContext(client, ctx = currentContext()) {
  const tenantSetting = resolveTenantSettingValue(ctx);
  await client.query("SELECT set_config('app.tenant_id', $1, false)", [
    tenantSetting,
  ]);
  await client.query("SELECT set_config('search_path', $1, false)", [
    resolveSearchPath(ctx),
  ]);
}

function normalizeTenantCode(raw) {
  return String(raw || '')
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}_-]/gu, '');
}

function isIsolatedTenantRow(row) {
  const mode = String(row?.db_mode || '')
    .toLowerCase()
    .trim();
  const dbUrl = String(row?.db_url || '').trim();
  return mode === 'isolated' && dbUrl.length > 0;
}

function isSchemaIsolatedTenantRow(row) {
  const mode = String(row?.db_mode || '')
    .toLowerCase()
    .trim();
  const schemaName = String(row?.db_schema || '')
    .toLowerCase()
    .trim();
  return mode === 'schema_isolated' && schemaName.length > 0;
}

function normalizeSchemaName(raw) {
  return String(raw || '')
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 48);
}

function resolveSearchPath(ctx = currentContext()) {
  const schemaName = normalizeSchemaName(ctx?.tenant?.db_schema || '');
  if (isSchemaIsolatedTenantRow(ctx?.tenant) && schemaName) {
    return `"${schemaName}", public`;
  }
  return 'public';
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
            db_name,
            db_schema
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
            db_name,
            db_schema
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
      source: isIsolatedTenantRow(tenantRow)
        ? 'tenant-isolated'
        : isSchemaIsolatedTenantRow(tenantRow)
        ? 'tenant-schema-isolated'
        : 'shared',
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

async function connect() {
  const pool = currentPool();
  const ctx = currentContext();
  const client = await pool.connect();
  const originalQuery = client.query.bind(client);
  const originalRelease = client.release.bind(client);
  let contextReady = false;

  const ensureContext = async () => {
    if (contextReady) return;
    await originalQuery("SELECT set_config('app.tenant_id', $1, false)", [
      resolveTenantSettingValue(ctx),
    ]);
    await originalQuery("SELECT set_config('search_path', $1, false)", [
      resolveSearchPath(ctx),
    ]);
    contextReady = true;
  };

  client.query = async (...args) => {
    await ensureContext();
    return originalQuery(...args);
  };

  client.release = (...args) => {
    client.query = originalQuery;
    client.release = originalRelease;
    return originalRelease(...args);
  };

  try {
    await ensureContext();
  } catch (err) {
    client.release(err);
    throw err;
  }

  return client;
}

async function query(text, params) {
  const client = await connect();
  try {
    return await client.query(text, params);
  } finally {
    client.release();
  }
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
      if (prop === "query") return query;
      if (prop === "connect") return connect;
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
  connect,

  // Platform DB primitives (always central DB)
  platformPool,
  platformQuery,
  platformConnect,
  applyClientContext,

  // Tenant helpers
  normalizeTenantCode,
  isIsolatedTenantRow,
  isSchemaIsolatedTenantRow,
  resolveTenantByCode,
  resolveTenantById,
  runWithTenantRow,
  runWithTenantCode,
  runWithTenantId,
  runWithPlatform,
  currentTenantContext,
};
