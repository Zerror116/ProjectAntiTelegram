const db = require("../db");

const DEFAULT_SCOPE_CACHE_MS = 60 * 1000;
const TENANT_SCOPE_CACHE_MS = Math.max(
  5 * 1000,
  Math.min(
    Number(process.env.TENANT_PROCESSING_SCOPE_CACHE_MS || DEFAULT_SCOPE_CACHE_MS) ||
      DEFAULT_SCOPE_CACHE_MS,
    10 * 60 * 1000,
  ),
);

let cachedTenantRows = null;
let cachedTenantRowsUntil = 0;
let scopeCursor = 0;

function normalizeDbMode(row) {
  return String(row?.db_mode || "shared").toLowerCase().trim();
}

function isTenantDatabaseScope(row) {
  const mode = normalizeDbMode(row);
  return mode === "isolated" || mode === "schema_isolated";
}

function scopeLabel(scope) {
  const code = String(scope?.code || "").trim();
  return code || "platform";
}

async function loadTenantProcessingTargets({ force = false } = {}) {
  const now = Date.now();
  if (!force && cachedTenantRows && cachedTenantRowsUntil > now) {
    return cachedTenantRows;
  }

  const tenantsQ = await db.platformQuery(
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
      WHERE COALESCE(is_deleted, false) = false
        AND COALESCE(status, 'active') = 'active'
        AND COALESCE(db_mode, 'shared') IN ('isolated', 'schema_isolated')
      ORDER BY created_at ASC, id ASC`,
  );

  cachedTenantRows = tenantsQ.rows.filter(isTenantDatabaseScope);
  cachedTenantRowsUntil = now + TENANT_SCOPE_CACHE_MS;
  return cachedTenantRows;
}

function buildTenantProcessingScopes(tenantRows = [], { includePlatform = true } = {}) {
  const scopes = [];
  if (includePlatform) scopes.push(null);
  for (const row of Array.isArray(tenantRows) ? tenantRows : []) {
    if (isTenantDatabaseScope(row)) scopes.push(row);
  }
  return scopes;
}

function rotateTenantProcessingScopes(scopes = []) {
  if (!Array.isArray(scopes) || scopes.length <= 1) return scopes;
  const startIndex = Math.abs(scopeCursor) % scopes.length;
  scopeCursor = (startIndex + 1) % scopes.length;
  return scopes.slice(startIndex).concat(scopes.slice(0, startIndex));
}

async function runInTenantProcessingScope(scope, fn) {
  return db.runWithTenantRow(scope || null, () => fn(scope || null));
}

async function loadTenantProcessingScopes(options = {}) {
  const targets = await loadTenantProcessingTargets(options);
  const scopes = buildTenantProcessingScopes(targets, options);
  return options.rotate === false ? scopes : rotateTenantProcessingScopes(scopes);
}

module.exports = {
  TENANT_SCOPE_CACHE_MS,
  buildTenantProcessingScopes,
  isTenantDatabaseScope,
  loadTenantProcessingScopes,
  loadTenantProcessingTargets,
  rotateTenantProcessingScopes,
  runInTenantProcessingScope,
  scopeLabel,
};
