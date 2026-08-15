// server/src/db.js
const { AsyncLocalStorage } = require('async_hooks');
const { Pool } = require('pg');
require('dotenv').config();

const DEFAULT_DATABASE_URL =
  process.env.DATABASE_URL ||
  'postgresql://projectphoenix:projectphoenix@localhost:5432/projectphoenix';

const NODE_ENV = String(process.env.NODE_ENV || 'development')
  .toLowerCase()
  .trim();
const IS_PRODUCTION = NODE_ENV === 'production';

function parsePositiveIntegerEnv(name, fallback, { min = 0, max = 600000 } = {}) {
  const rawValue = process.env[name];
  const parsed =
    rawValue === undefined || rawValue === null || rawValue === ''
      ? Number(fallback)
      : Number(rawValue);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(parsed)));
}

const DATABASE_PLATFORM_POOL_MAX = parsePositiveIntegerEnv(
  'DATABASE_PLATFORM_POOL_MAX',
  IS_PRODUCTION ? 12 : 10,
  { min: 1, max: 100 },
);
const DATABASE_TENANT_POOL_MAX = parsePositiveIntegerEnv(
  'DATABASE_TENANT_POOL_MAX',
  IS_PRODUCTION ? 4 : 4,
  { min: 1, max: 50 },
);
const DATABASE_CONNECTION_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_CONNECTION_TIMEOUT_MS',
  IS_PRODUCTION ? 5000 : 10000,
  { min: 0, max: 60000 },
);
const DATABASE_IDLE_CLIENT_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_IDLE_CLIENT_TIMEOUT_MS',
  30000,
  { min: 1000, max: 600000 },
);
const DATABASE_STATEMENT_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_STATEMENT_TIMEOUT_MS',
  IS_PRODUCTION ? 60000 : 0,
);
const DATABASE_QUERY_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_QUERY_TIMEOUT_MS',
  IS_PRODUCTION ? 65000 : 0,
  { min: 0, max: 650000 },
);
const DATABASE_LOCK_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_LOCK_TIMEOUT_MS',
  IS_PRODUCTION ? 10000 : 0,
  { min: 0, max: 120000 },
);
const DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS',
  IS_PRODUCTION ? 60000 : 0,
);
const DATABASE_MAINTENANCE_STATEMENT_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_MAINTENANCE_STATEMENT_TIMEOUT_MS',
  IS_PRODUCTION ? 300000 : 0,
  { min: 0, max: 3600000 },
);
const DATABASE_MAINTENANCE_QUERY_TIMEOUT_MS = parsePositiveIntegerEnv(
  'DATABASE_MAINTENANCE_QUERY_TIMEOUT_MS',
  IS_PRODUCTION ? 310000 : 0,
  { min: 0, max: 3610000 },
);
const DATABASE_TENANT_POOL_TTL_MS = parsePositiveIntegerEnv(
  'DATABASE_TENANT_POOL_TTL_MS',
  IS_PRODUCTION ? 10 * 60 * 1000 : 30 * 60 * 1000,
  { min: 60 * 1000, max: 24 * 60 * 60 * 1000 },
);

function addPositivePoolOption(config, name, value) {
  if (Number.isFinite(value) && value > 0) {
    config[name] = value;
  }
}

function normalizePoolMax(rawValue, fallback) {
  const parsed = Number(rawValue);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(1, Math.min(100, Math.floor(parsed)));
}

function buildPoolConfig(connectionString, options = {}) {
  const maintenance = options.maintenance === true;
  const platformMax = options.tenant === true
    ? DATABASE_TENANT_POOL_MAX
    : DATABASE_PLATFORM_POOL_MAX;
  const config = {
    connectionString,
    max: normalizePoolMax(options.max, platformMax),
    idleTimeoutMillis: DATABASE_IDLE_CLIENT_TIMEOUT_MS,
    connectionTimeoutMillis: DATABASE_CONNECTION_TIMEOUT_MS,
  };

  addPositivePoolOption(
    config,
    'statement_timeout',
    maintenance
      ? DATABASE_MAINTENANCE_STATEMENT_TIMEOUT_MS
      : DATABASE_STATEMENT_TIMEOUT_MS,
  );
  addPositivePoolOption(
    config,
    'query_timeout',
    maintenance
      ? DATABASE_MAINTENANCE_QUERY_TIMEOUT_MS
      : DATABASE_QUERY_TIMEOUT_MS,
  );
  addPositivePoolOption(config, 'lock_timeout', DATABASE_LOCK_TIMEOUT_MS);
  addPositivePoolOption(
    config,
    'idle_in_transaction_session_timeout',
    DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS,
  );

  return config;
}

function attachPoolHandlers(pool, label = 'pool') {
  if (!pool || pool.__projectPhoenixPoolHandlersAttached === true) return pool;
  pool.on('error', (err) => {
    console.error(`[db] idle pool error (${label}):`, err);
  });
  Object.defineProperty(pool, '__projectPhoenixPoolHandlersAttached', {
    value: true,
    enumerable: false,
    configurable: false,
    writable: false,
  });
  return pool;
}

function createPool(connectionString, options = {}) {
  const pool = new Pool(buildPoolConfig(connectionString, options));
  return attachPoolHandlers(pool, options.label || 'pool');
}

const platformPool = createPool(DEFAULT_DATABASE_URL, {
  label: 'platform',
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

  pruneIdleTenantPools();

  const dbUrl = String(tenantRow.db_url || '').trim();
  const cached = tenantPoolCache.get(dbUrl);
  if (cached?.pool) {
    cached.lastUsedAt = Date.now();
    return cached.pool;
  }
  if (cached?.promise) {
    cached.lastUsedAt = Date.now();
    return cached.promise;
  }

  const entry = {
    pool: null,
    lastUsedAt: Date.now(),
    promise: null,
  };
  entry.promise = (async () => {
    const pool = createPool(dbUrl, {
      tenant: true,
      label: `tenant:${tenantRow.code || tenantRow.id || 'isolated'}`,
    });
    try {
      await pool.query('SELECT 1');
      entry.pool = pool;
      entry.lastUsedAt = Date.now();
      return pool;
    } catch (err) {
      tenantPoolCache.delete(dbUrl);
      await pool.end().catch(() => {});
      throw err;
    } finally {
      entry.promise = null;
    }
  })();
  tenantPoolCache.set(dbUrl, entry);
  return entry.promise;
}

function pruneIdleTenantPools(now = Date.now()) {
  for (const [dbUrl, entry] of tenantPoolCache.entries()) {
    const pool = entry?.pool || null;
    if (!pool) {
      if (!entry?.promise) tenantPoolCache.delete(dbUrl);
      continue;
    }
    if (now - Number(entry.lastUsedAt || 0) < DATABASE_TENANT_POOL_TTL_MS) {
      continue;
    }
    const activeCount = Math.max(0, pool.totalCount - pool.idleCount);
    if (activeCount > 0 || pool.waitingCount > 0) continue;
    tenantPoolCache.delete(dbUrl);
    pool.end().catch((err) => {
      console.error(`[db] tenant pool cleanup failed (${dbUrl}):`, err);
    });
  }
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

async function platformQuery(text, params) {
  const client = await platformPool.connect();
  try {
    await client.query("SELECT set_config('app.tenant_id', '', false)");
    await client.query("SELECT set_config('search_path', 'public', false)");
    return await client.query(text, params);
  } finally {
    client.release();
  }
}

function platformConnect() {
  return platformPool.connect();
}

async function closeAllPools() {
  const tenantEntries = [...tenantPoolCache.values()];
  tenantPoolCache.clear();
  await Promise.allSettled(
    tenantEntries.map(async (entry) => {
      const pool =
        entry?.pool ||
        (entry?.promise ? await entry.promise.catch(() => null) : null);
      if (pool) await pool.end();
    }),
  );
  await platformPool.end();
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
  closeAllPools,
  applyClientContext,
  buildPoolConfig,
  createPool,
  pruneIdleTenantPools,

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
