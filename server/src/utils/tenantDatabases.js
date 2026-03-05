const path = require('path');
const { Pool } = require('pg');

const { ensureDatabaseExists, applyMigrationsToTarget } = require('./bootstrap');
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

async function upsertTenantShadowRow({
  dbUrl,
  tenantId,
  tenantCode,
  tenantName,
  accessKeyHash,
  accessKeyMask,
  status,
  subscriptionExpiresAt,
  createdBy,
  notes,
}) {
  const pool = new Pool({ connectionString: dbUrl });
  try {
    await pool.query('BEGIN');
    await pool.query(
      `INSERT INTO tenants (
         id,
         code,
         name,
         access_key_hash,
         access_key_mask,
         status,
         subscription_expires_at,
         last_payment_confirmed_at,
         created_by,
         notes,
         db_mode,
         db_name,
         db_url,
         created_at,
         updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, now(),
         $8, $9,
         'isolated', current_database(), NULL,
         now(), now()
       )
       ON CONFLICT (id)
       DO UPDATE SET
         code = EXCLUDED.code,
         name = EXCLUDED.name,
         access_key_hash = EXCLUDED.access_key_hash,
         access_key_mask = EXCLUDED.access_key_mask,
         status = EXCLUDED.status,
         subscription_expires_at = EXCLUDED.subscription_expires_at,
         last_payment_confirmed_at = now(),
         notes = EXCLUDED.notes,
         db_mode = 'isolated',
         db_name = current_database(),
         db_url = NULL,
         updated_at = now()`,
      [
        tenantId,
        tenantCode,
        tenantName,
        accessKeyHash,
        accessKeyMask,
        status,
        subscriptionExpiresAt,
        createdBy || null,
        notes || null,
      ],
    );

    const ensured = await ensureSystemChannels(pool, createdBy || null, tenantId);
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
  status = 'active',
  subscriptionExpiresAt,
  createdBy,
  notes,
}) {
  const migrationsDir = path.resolve(__dirname, '../../migrations');
  const dbName = buildTenantDatabaseName(tenantCode || tenantId);
  const dbUrl = buildDatabaseUrlWithName(platformDbUrl, dbName);

  await ensureDatabaseExists(dbUrl);
  await applyMigrationsToTarget(dbUrl, migrationsDir);

  const systemChannels = await upsertTenantShadowRow({
    dbUrl,
    tenantId,
    tenantCode,
    tenantName,
    accessKeyHash,
    accessKeyMask,
    status,
    subscriptionExpiresAt,
    createdBy,
    notes,
  });

  return {
    dbName,
    dbUrl,
    systemChannels,
  };
}

module.exports = {
  sanitizeTenantDbNameFragment,
  buildTenantDatabaseName,
  buildDatabaseUrlWithName,
  provisionIsolatedTenantDatabase,
};
