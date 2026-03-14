const path = require('path');
const { Pool } = require('pg');

const {
  ensureDatabaseExists,
  applyMigrationsToTarget,
  sanitizeSchemaName,
  quoteIdentifier,
} = require('./bootstrap');
const { ensureSystemChannels } = require('./systemChannels');

function sanitizeTenantDbNameFragment(raw) {
  return String(raw || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 36);
}

function buildTenantDatabaseName(tenantCode) {
  const fragment = sanitizeTenantDbNameFragment(tenantCode) || 'tenant';
  return `fenix_${fragment}`;
}

function buildDatabaseUrlWithName(baseDbUrl, dbName) {
  const base = new URL(baseDbUrl);
  base.pathname = `/${dbName}`;
  return base.toString();
}

function buildTenantSchemaName(tenantCode) {
  const fragment = sanitizeTenantDbNameFragment(tenantCode) || 'tenant';
  return sanitizeSchemaName(`tenant_${fragment}`) || 'tenant_scope';
}

function parseDatabaseNameFromUrl(dbUrl) {
  try {
    const url = new URL(dbUrl);
    return (url.pathname || '').replace(/^\//, '') || 'postgres';
  } catch (_) {
    return 'postgres';
  }
}

function isCreateDbPermissionError(err) {
  const code = String(err?.code || '').trim();
  if (code === '42501') return true;
  const msg = String(err?.message || '').toLowerCase();
  return msg.includes('permission denied') && msg.includes('create database');
}

async function setSessionSchemaSearchPath(pool, schemaName) {
  const normalized = sanitizeSchemaName(schemaName);
  if (!normalized) return;
  await pool.query(
    `CREATE SCHEMA IF NOT EXISTS ${quoteIdentifier(normalized)}`,
  );
  await pool.query("SELECT set_config('search_path', $1, false)", [
    `${quoteIdentifier(normalized)}, public`,
  ]);
}

async function resolveShadowCreatedBy(pool, createdBy) {
  const userId = String(createdBy || '').trim();
  if (!userId) return null;
  const q = await pool.query(
    `SELECT id
     FROM users
     WHERE id = $1
     LIMIT 1`,
    [userId],
  );
  if (q.rowCount > 0) return q.rows[0].id;
  return null;
}

async function upsertTenantShadowRow({
  dbUrl,
  tenantId,
  tenantCode,
  tenantName,
  accessKeyHash,
  accessKeyMask,
  accessKeyValue,
  status,
  subscriptionExpiresAt,
  createdBy,
  notes,
  dbMode = 'isolated',
  dbSchema = null,
}) {
  const pool = new Pool({ connectionString: dbUrl });
  try {
    if (dbSchema) {
      await setSessionSchemaSearchPath(pool, dbSchema);
    }
    await pool.query('BEGIN');
    const shadowCreatedBy = await resolveShadowCreatedBy(pool, createdBy);
    await pool.query(
      `INSERT INTO tenants (
         id,
         code,
         name,
         access_key_hash,
         access_key_mask,
         access_key_value,
         status,
         subscription_expires_at,
         last_payment_confirmed_at,
         created_by,
         notes,
         db_mode,
         db_name,
         db_schema,
         db_url,
         created_at,
         updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5, $6,
         $7, $8, now(),
         $9, $10,
         $11, current_database(), $12, NULL,
         now(), now()
       )
       ON CONFLICT (id)
       DO UPDATE SET
         code = EXCLUDED.code,
         name = EXCLUDED.name,
         access_key_hash = EXCLUDED.access_key_hash,
         access_key_mask = EXCLUDED.access_key_mask,
         access_key_value = EXCLUDED.access_key_value,
         status = EXCLUDED.status,
         subscription_expires_at = EXCLUDED.subscription_expires_at,
         last_payment_confirmed_at = now(),
         notes = EXCLUDED.notes,
         db_mode = EXCLUDED.db_mode,
         db_name = current_database(),
         db_schema = EXCLUDED.db_schema,
         db_url = NULL,
         updated_at = now()`,
      [
        tenantId,
        tenantCode,
        tenantName,
        accessKeyHash,
        accessKeyMask,
        accessKeyValue || null,
        status,
        subscriptionExpiresAt,
        shadowCreatedBy,
        notes || null,
        dbMode,
        dbSchema ? sanitizeSchemaName(dbSchema) : null,
      ],
    );

    const ensured = await ensureSystemChannels(pool, shadowCreatedBy, tenantId);
    await pool.query('COMMIT');

    return {
      main_channel_id: ensured.mainChannel.id,
      reserved_channel_id: ensured.reservedChannel.id,
      created: ensured.created,
    };
  } catch (err) {
    await pool.query('ROLLBACK');
    throw err;
  } finally {
    await pool.end();
  }
}

async function provisionIsolatedTenantDatabase({
  platformDbUrl,
  tenantId,
  tenantCode,
  tenantName,
  accessKeyHash,
  accessKeyMask,
  accessKeyValue,
  status = 'active',
  subscriptionExpiresAt,
  createdBy,
  notes,
}) {
  const migrationsDir = path.resolve(__dirname, '../../migrations');
  const dbName = buildTenantDatabaseName(tenantCode || tenantId);
  const dbUrl = buildDatabaseUrlWithName(platformDbUrl, dbName);
  try {
    await ensureDatabaseExists(dbUrl);
    await applyMigrationsToTarget(dbUrl, migrationsDir);

    const systemChannels = await upsertTenantShadowRow({
      dbUrl,
      tenantId,
      tenantCode,
      tenantName,
      accessKeyHash,
      accessKeyMask,
      accessKeyValue,
      status,
      subscriptionExpiresAt,
      createdBy,
      notes,
      dbMode: 'isolated',
      dbSchema: null,
    });

    return {
      dbMode: 'isolated',
      dbName,
      dbUrl,
      dbSchema: null,
      systemChannels,
    };
  } catch (err) {
    if (!isCreateDbPermissionError(err)) {
      throw err;
    }

    const dbSchema = buildTenantSchemaName(tenantCode || tenantId);
    await applyMigrationsToTarget(platformDbUrl, migrationsDir, {
      schemaName: dbSchema,
    });

    const systemChannels = await upsertTenantShadowRow({
      dbUrl: platformDbUrl,
      tenantId,
      tenantCode,
      tenantName,
      accessKeyHash,
      accessKeyMask,
      accessKeyValue,
      status,
      subscriptionExpiresAt,
      createdBy,
      notes,
      dbMode: 'schema_isolated',
      dbSchema,
    });

    return {
      dbMode: 'schema_isolated',
      dbName: parseDatabaseNameFromUrl(platformDbUrl),
      dbUrl: null,
      dbSchema,
      systemChannels,
      fallbackReason: 'createdb_permission_denied',
    };
  }
}

module.exports = {
  sanitizeTenantDbNameFragment,
  buildTenantDatabaseName,
  buildDatabaseUrlWithName,
  buildTenantSchemaName,
  isCreateDbPermissionError,
  provisionIsolatedTenantDatabase,
};
