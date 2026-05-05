#!/usr/bin/env node

const path = require('path');

const db = require('../src/db');
const { applyMigrationsToTarget } = require('../src/utils/bootstrap');

function parseArgs(argv = process.argv.slice(2)) {
  const result = {
    tenantCode: '',
  };
  for (const arg of argv) {
    if (arg.startsWith('--tenant-code=')) {
      result.tenantCode = db.normalizeTenantCode(arg.slice('--tenant-code='.length));
    }
  }
  return result;
}

async function loadTenantTargets(tenantCode = '') {
  const params = [];
  const where = [
    `COALESCE(is_deleted, false) = false`,
    `db_mode IN ('isolated', 'schema_isolated')`,
  ];
  if (tenantCode) {
    params.push(tenantCode);
    where.push(`lower(code) = $${params.length}`);
  }
  const result = await db.platformQuery(
    `SELECT id,
            code,
            name,
            db_mode,
            db_url,
            db_name,
            db_schema
     FROM tenants
     WHERE ${where.join(' AND ')}
     ORDER BY created_at ASC, id ASC`,
    params,
  );
  return result.rows;
}

async function migrateTenantRow(tenantRow, migrationsDir) {
  const mode = String(tenantRow?.db_mode || '').toLowerCase().trim();
  const tenantCode = String(tenantRow?.code || '').trim();
  if (mode === 'isolated') {
    const dbUrl = String(tenantRow?.db_url || '').trim();
    if (!dbUrl) {
      throw new Error(`Tenant ${tenantCode}: db_url is empty for isolated mode`);
    }
    return applyMigrationsToTarget(dbUrl, migrationsDir);
  }
  if (mode === 'schema_isolated') {
    const schemaName = String(tenantRow?.db_schema || '').trim();
    if (!schemaName) {
      throw new Error(`Tenant ${tenantCode}: db_schema is empty for schema_isolated mode`);
    }
    return applyMigrationsToTarget(
      process.env.DATABASE_URL ||
        'postgresql://projectphoenix:projectphoenix@localhost:5432/projectphoenix',
      migrationsDir,
      { schemaName },
    );
  }
  throw new Error(`Tenant ${tenantCode}: unsupported db_mode ${mode || 'unknown'}`);
}

async function main() {
  const { tenantCode } = parseArgs();
  const migrationsDir = path.resolve(__dirname, '../migrations');
  const tenants = await loadTenantTargets(tenantCode);

  if (tenants.length === 0) {
    console.log(
      JSON.stringify(
        {
          ok: true,
          message: tenantCode
            ? `No tenant matches code ${tenantCode}`
            : 'No isolated tenants found',
          tenants_checked: 0,
          tenants_with_changes: 0,
          results: [],
        },
        null,
        2,
      ),
    );
    return;
  }

  const results = [];
  let tenantsWithChanges = 0;
  for (const tenant of tenants) {
    const result = await migrateTenantRow(tenant, migrationsDir);
    const applied = Array.isArray(result?.applied) ? result.applied : [];
    if (applied.length > 0) tenantsWithChanges += 1;
    results.push({
      tenant_id: tenant.id,
      tenant_code: tenant.code,
      tenant_name: tenant.name,
      db_mode: tenant.db_mode,
      db_name: tenant.db_name || null,
      db_schema: tenant.db_schema || null,
      applied,
      message: result?.message || 'ok',
    });
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        tenants_checked: tenants.length,
        tenants_with_changes: tenantsWithChanges,
        results,
      },
      null,
      2,
    ),
  );
}

main().catch((err) => {
  console.error(
    JSON.stringify(
      {
        ok: false,
        error: String(err?.message || err || 'unknown_error'),
      },
      null,
      2,
    ),
  );
  process.exit(1);
});
