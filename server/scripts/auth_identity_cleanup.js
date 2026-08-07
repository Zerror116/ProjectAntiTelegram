#!/usr/bin/env node

const db = require("../src/db");
const {
  buildTenantProcessingScopes,
  loadTenantProcessingTargets,
} = require("../src/utils/tenantProcessingScopes");

function parseArgs(argv) {
  return {
    dryRun: argv.includes("--dry-run"),
  };
}

async function cleanupCurrentScope({ dryRun }) {
  const client = await db.connect();
  try {
    await client.query("BEGIN");

    const sessions = await client.query(
      `UPDATE user_sessions s
          SET is_active = false
         FROM users u
        WHERE u.id = s.user_id
          AND s.is_active = true
          AND COALESCE(u.is_active, true) = false`,
    );

    const endpoints = await client.query(
      `UPDATE notification_endpoints e
          SET is_active = false,
              updated_at = now(),
              last_failure_at = COALESCE(last_failure_at, now()),
              last_failure_reason = COALESCE(NULLIF(last_failure_reason, ''), 'user_inactive'),
              last_delivery_state = COALESCE(last_delivery_state, 'disabled')
         FROM users u
        WHERE u.id = e.user_id
          AND e.is_active = true
          AND COALESCE(u.is_active, true) = false`,
    );

    if (dryRun) {
      await client.query("ROLLBACK");
    } else {
      await client.query("COMMIT");
    }

    return {
      sessions_deactivated: sessions.rowCount || 0,
      notification_endpoints_deactivated: endpoints.rowCount || 0,
    };
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const tenantTargets = await loadTenantProcessingTargets({ force: true });
  const scopes = buildTenantProcessingScopes(tenantTargets, {
    includePlatform: true,
  });
  const totals = {
    dry_run: args.dryRun,
    scopes_checked: 0,
    sessions_deactivated: 0,
    notification_endpoints_deactivated: 0,
    unavailable_scopes: 0,
  };

  for (const scope of scopes) {
    totals.scopes_checked += 1;
    try {
      const result = await db.runWithTenantRow(scope || null, () =>
        cleanupCurrentScope(args),
      );
      totals.sessions_deactivated += result.sessions_deactivated;
      totals.notification_endpoints_deactivated +=
        result.notification_endpoints_deactivated;
    } catch (err) {
      totals.unavailable_scopes += 1;
      console.error(
        "[auth_identity_cleanup] scope failed",
        String(err?.message || err).slice(0, 300),
      );
    }
  }

  console.log(JSON.stringify(totals, null, 2));
  if (totals.unavailable_scopes > 0) process.exit(1);
}

main()
  .catch((err) => {
    console.error("[auth_identity_cleanup] fatal", err);
    process.exit(1);
  })
  .finally(async () => {
    try {
      await db.closeAllPools();
    } catch (_) {}
  });
