#!/usr/bin/env node

/* eslint-disable no-console */

const db = require("../src/db");

function parseArgs(argv = process.argv.slice(2)) {
  const result = {
    tenantCode: "",
    prune: true,
  };
  for (const arg of argv) {
    if (arg.startsWith("--tenant-code=")) {
      result.tenantCode = db.normalizeTenantCode(
        arg.slice("--tenant-code=".length),
      );
    } else if (arg === "--no-prune") {
      result.prune = false;
    }
  }
  return result;
}

async function loadTenants(tenantCode = "") {
  const params = [];
  const where = [`COALESCE(is_deleted, false) = false`];
  if (tenantCode) {
    params.push(tenantCode);
    where.push(`lower(code) = $${params.length}`);
  }
  const q = await db.platformQuery(
    `SELECT id,
            code,
            name,
            status,
            db_mode,
            db_url,
            db_name,
            db_schema
     FROM tenants
     WHERE ${where.join(" AND ")}
     ORDER BY created_at ASC, id ASC`,
    params,
  );
  return q.rows || [];
}

async function loadTenantUsers(tenant) {
  return await db.runWithTenantRow(tenant, async () => {
    const tenantId = String(tenant?.id || "").trim();
    const allowLegacyNullTenantRows =
      db.isIsolatedTenantRow(tenant) || db.isSchemaIsolatedTenantRow(tenant);
    const q = await db.query(
      `SELECT DISTINCT ON (lower(email))
              id,
              lower(email) AS email,
              lower(trim(COALESCE(role, 'client'))) AS role,
              COALESCE(is_active, true) AS is_active,
              created_at
       FROM users
       WHERE NULLIF(BTRIM(email), '') IS NOT NULL
         AND (
           tenant_id = $1::uuid
           OR ($2::boolean = true AND tenant_id IS NULL)
         )
       ORDER BY lower(email),
                COALESCE(is_active, true) DESC,
                created_at DESC,
                id ASC`,
      [tenantId, allowLegacyNullTenantRows],
    );
    return q.rows || [];
  });
}

async function syncTenant(tenant, { prune = true } = {}) {
  const tenantId = String(tenant?.id || "").trim();
  const users = await loadTenantUsers(tenant);
  let upserted = 0;
  const client = await db.platformConnect();
  let pruned = 0;
  try {
    await client.query("BEGIN");
    if (prune) {
      const pruneQ = await client.query(
        `DELETE FROM tenant_user_index
         WHERE tenant_id = $1::uuid`,
        [tenantId],
      );
      pruned = pruneQ.rowCount || 0;
    }
    for (const user of users) {
      const userId = String(user?.id || "").trim();
      const email = String(user?.email || "").trim().toLowerCase();
      if (!tenantId || !userId || !email) continue;
      const role =
        String(user?.role || "client").trim().toLowerCase() || "client";
      await client.query(
        `INSERT INTO tenant_user_index (
           tenant_id,
           user_id,
           email,
           role,
           is_active,
           created_at,
           updated_at
         )
         VALUES ($1::uuid, $2::uuid, $3, $4, $5, COALESCE($6::timestamptz, now()), now())`,
        [
          tenantId,
          userId,
          email,
          role,
          user.is_active === true,
          user.created_at || null,
        ],
      );
      upserted += 1;
    }
    await client.query("COMMIT");
  } catch (err) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {}
    throw err;
  } finally {
    client.release();
  }

  return {
    tenant_id: tenantId,
    tenant_code: tenant.code,
    users_seen: users.length,
    upserted,
    pruned,
  };
}

async function main() {
  const options = parseArgs();
  const tenants = await loadTenants(options.tenantCode);
  const results = [];
  for (const tenant of tenants) {
    results.push(await syncTenant(tenant, options));
  }
  console.log(
    JSON.stringify(
      {
        ok: true,
        tenants_checked: tenants.length,
        results,
      },
      null,
      2,
    ),
  );
}

main()
  .catch((err) => {
    console.error(
      JSON.stringify(
        {
          ok: false,
          error: String(err?.message || err || "unknown_error"),
        },
        null,
        2,
      ),
    );
    process.exitCode = 1;
  })
  .finally(async () => {
    try {
      await db.platformPool.end();
    } catch (_) {}
  });
