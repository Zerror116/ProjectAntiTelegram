#!/usr/bin/env node
/*
 * Configures tenant-scoped feature flags without hardcoding tenant keys/codes
 * in application source.
 *
 * Example:
 *   TENANT_INVITE_CODE=INV-XXXX-YYYY \
 *   CLIENT_INVITE_CODE=INV-XXXX-YYYY \
 *   CLIENT_CITY_OPTIONS="City 1,City 2" \
 *   node scripts/configure_tenant_feature_settings.js
 */
require("dotenv").config();

const db = require("../src/db");
const {
  generateAccessKey,
  generateTenantCode,
  hashAccessKey,
  maskAccessKey,
  normalizeAccessKey,
  normalizeInviteCode,
} = require("../src/utils/tenants");
const { v4: uuidv4 } = require("uuid");

function clean(value) {
  return String(value || "").trim();
}

function parseBoolean(raw, fallback = false) {
  const value = clean(raw).toLowerCase();
  if (!value) return fallback;
  return ["1", "true", "yes", "on", "да"].includes(value);
}

function parsePositiveInt(raw, fallback) {
  const parsed = Number(clean(raw));
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.floor(parsed);
}

function parseStringList(raw) {
  const unique = new Set();
  clean(raw)
    .split(/[\n,;]+/g)
    .map((item) => item.trim())
    .filter(Boolean)
    .forEach((item) => unique.add(item));
  return Array.from(unique);
}

async function findTenant(client) {
  const tenantId = clean(process.env.TENANT_ID);
  if (tenantId) {
    const q = await client.query("SELECT * FROM tenants WHERE id = $1 LIMIT 1", [
      tenantId,
    ]);
    if (q.rowCount > 0) return q.rows[0];
  }

  const tenantCode = clean(process.env.TENANT_CODE).toLowerCase();
  if (tenantCode) {
    const q = await client.query(
      "SELECT * FROM tenants WHERE lower(code) = $1 LIMIT 1",
      [tenantCode],
    );
    if (q.rowCount > 0) return q.rows[0];
  }

  const inviteCode = normalizeInviteCode(
    process.env.TENANT_INVITE_CODE || process.env.INVITE_CODE,
  );
  if (inviteCode) {
    const q = await client.query(
      `SELECT t.*
       FROM tenant_invites i
       JOIN tenants t ON t.id = i.tenant_id
       WHERE i.code = $1
       LIMIT 1`,
      [inviteCode],
    );
    if (q.rowCount > 0) return q.rows[0];
  }

  const accessKey = normalizeAccessKey(process.env.TENANT_ACCESS_KEY || "");
  if (accessKey) {
    const q = await client.query(
      "SELECT * FROM tenants WHERE access_key_hash = $1 LIMIT 1",
      [hashAccessKey(accessKey)],
    );
    if (q.rowCount > 0) return q.rows[0];
  }

  const tenantName = clean(process.env.TENANT_NAME).toLowerCase();
  if (tenantName) {
    const q = await client.query(
      "SELECT * FROM tenants WHERE lower(name) = $1 LIMIT 1",
      [tenantName],
    );
    if (q.rowCount > 0) return q.rows[0];
  }

  return null;
}

async function createTenantIfRequested(client) {
  if (!parseBoolean(process.env.CREATE_TENANT_IF_MISSING, false)) return null;
  const tenantName = clean(process.env.TENANT_NAME);
  if (!tenantName) {
    throw new Error("TENANT_NAME is required when CREATE_TENANT_IF_MISSING=true.");
  }
  const accessKey = normalizeAccessKey(process.env.TENANT_ACCESS_KEY || generateAccessKey());
  const tenantCode = clean(process.env.TENANT_CODE) || generateTenantCode(tenantName);
  const months = parsePositiveInt(process.env.TENANT_SUBSCRIPTION_MONTHS, 12);
  const inserted = await client.query(
    `INSERT INTO tenants (
       id, code, name, access_key_hash, access_key_mask, access_key_value,
       status, subscription_expires_at, last_payment_confirmed_at,
       notes, db_mode, created_at, updated_at
     )
     VALUES (
       $1, $2, $3, $4, $5, $6,
       'active', now() + make_interval(months => $7::int), now(),
       NULLIF($8, ''), 'shared', now(), now()
     )
     ON CONFLICT (access_key_hash) DO UPDATE
       SET name = EXCLUDED.name,
           status = 'active',
           subscription_expires_at = GREATEST(tenants.subscription_expires_at, EXCLUDED.subscription_expires_at),
           updated_at = now()
     RETURNING *`,
    [
      uuidv4(),
      tenantCode,
      tenantName,
      hashAccessKey(accessKey),
      maskAccessKey(accessKey),
      accessKey,
      months,
      clean(process.env.TENANT_NOTES),
    ],
  );
  return inserted.rows[0] || null;
}

async function main() {
  const client = await db.platformConnect();
  try {
    await client.query("BEGIN");
    let tenant = await findTenant(client);
    if (!tenant?.id) {
      tenant = await createTenantIfRequested(client);
    }
    if (!tenant?.id) {
      throw new Error(
        "Tenant not found. Provide TENANT_ID, TENANT_CODE, TENANT_INVITE_CODE, TENANT_ACCESS_KEY, or TENANT_NAME.",
      );
    }

    const settings = {
      custom_workflows_enabled: parseBoolean(
        process.env.CUSTOM_WORKFLOWS_ENABLED,
        true,
      ),
      publication_interval_ms: parsePositiveInt(
        process.env.PUBLICATION_INTERVAL_MS,
        2000,
      ),
      manual_shelf_enabled: parseBoolean(process.env.MANUAL_SHELF_ENABLED, true),
      pickup_only_enabled: parseBoolean(process.env.PICKUP_ONLY_ENABLED, true),
      cart_delivery_ready_enabled: parseBoolean(
        process.env.CART_DELIVERY_READY_ENABLED,
        true,
      ),
      cart_delivery_ready_min_amount: parsePositiveInt(
        process.env.CART_DELIVERY_READY_MIN_AMOUNT,
        1500,
      ),
      revision_delete_approval_enabled: parseBoolean(
        process.env.REVISION_DELETE_APPROVAL_ENABLED,
        true,
      ),
      defect_stats_enabled: parseBoolean(process.env.DEFECT_STATS_ENABLED, true),
    };

    await client.query(
      `INSERT INTO tenant_feature_settings (tenant_id, settings, created_at, updated_at)
       VALUES ($1, $2::jsonb, now(), now())
       ON CONFLICT (tenant_id) DO UPDATE
         SET settings = tenant_feature_settings.settings || EXCLUDED.settings,
             updated_at = now()`,
      [tenant.id, JSON.stringify(settings)],
    );

    const clientInviteCode = normalizeInviteCode(
      process.env.CLIENT_INVITE_CODE || process.env.TENANT_INVITE_CODE || "",
    );
    const cityOptions = parseStringList(process.env.CLIENT_CITY_OPTIONS || "");
    if (clientInviteCode) {
      const inviteQ = await client.query(
        `INSERT INTO tenant_invites (
           id, tenant_id, code, role, is_active, max_uses, used_count,
           expires_at, created_by, notes, settings, created_at, updated_at
         )
         VALUES (
           $1, $2, $3, 'client', true, NULL, 0,
           NULL, NULL, NULL,
           COALESCE($4::jsonb, '{}'::jsonb),
           now(), now()
         )
         ON CONFLICT (code) DO UPDATE
           SET tenant_id = EXCLUDED.tenant_id,
               role = 'client',
               is_active = true,
               settings = tenant_invites.settings || EXCLUDED.settings,
               updated_at = now()
         RETURNING id, code`,
        [
          uuidv4(),
          tenant.id,
          clientInviteCode,
          cityOptions.length > 0
            ? JSON.stringify({ client_city_options: cityOptions })
            : JSON.stringify({}),
        ],
      );
      if (inviteQ.rowCount === 0) {
        throw new Error(`Client invite not found for tenant: ${clientInviteCode}`);
      }
    }

    await client.query("COMMIT");
    console.log(
      JSON.stringify(
        {
          ok: true,
          tenant_id: tenant.id,
          tenant_code: tenant.code,
          tenant_name: tenant.name,
          configured_settings: settings,
          client_invite_configured: Boolean(clientInviteCode && cityOptions.length),
        },
        null,
        2,
      ),
    );
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    console.error(err?.message || err);
    process.exitCode = 1;
  } finally {
    client.release();
    await db.platformPool.end().catch(() => {});
  }
}

main();
