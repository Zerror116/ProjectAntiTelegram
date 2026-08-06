#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const { Pool } = require("pg");
const db = require("../src/db");
const {
  buildSecretKeyring,
  describeKeyring,
} = require("../src/utils/secretKeyring");
const { getJwtKeyringMeta } = require("../src/utils/jwt");
const { logReleaseCheck } = require("../src/utils/monitoring");
const { downloadsRoot } = require("../src/utils/storagePaths");
const {
  ANDROID_STABLE_RELEASE_FILE,
} = require("../src/utils/androidStableRelease");
const {
  getTenantFeatureSettings,
} = require("../src/utils/tenantFeatureSettings");

const NODE_ENV = String(process.env.NODE_ENV || "development")
  .toLowerCase()
  .trim();
const IS_PRODUCTION = NODE_ENV === "production";
const findings = [];

function addFinding(level, code, message, details = {}) {
  findings.push({
    level: String(level || "info").toLowerCase().trim(),
    code: String(code || "audit").trim(),
    message: String(message || "").trim(),
    details:
      details && typeof details === "object" && !Array.isArray(details)
        ? details
        : {},
  });
}

function parseBooleanEnv(rawValue, fallback = false) {
  if (rawValue === undefined || rawValue === null || rawValue === "") {
    return fallback;
  }
  const normalized = String(rawValue).toLowerCase().trim();
  return ["1", "true", "yes", "on", "y"].includes(normalized);
}

function parseNumberEnv(rawValue, fallback = 0) {
  const parsed = Number(rawValue);
  if (!Number.isFinite(parsed)) return fallback;
  return parsed;
}

function quotePgIdentifier(identifier) {
  return `"${String(identifier || "").replace(/"/g, '""')}"`;
}

function normalizePgSchema(rawValue) {
  return String(rawValue || "")
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 48);
}

function listExpectedMigrationFiles() {
  const migrationsDir = path.resolve(__dirname, "../migrations");
  if (!fs.existsSync(migrationsDir)) return [];
  return fs
    .readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql"))
    .sort();
}

async function readAppliedMigrationFiles(pool, schemaName = "public") {
  const normalizedSchema = normalizePgSchema(schemaName) || "public";
  const tableRef = `${quotePgIdentifier(normalizedSchema)}.schema_migrations`;
  try {
    const result = await pool.query(
      `SELECT filename
       FROM ${tableRef}`,
    );
    return {
      ok: true,
      applied: new Set(
        (result.rows || [])
          .map((row) => String(row.filename || "").trim())
          .filter(Boolean),
      ),
    };
  } catch (err) {
    const code = String(err?.code || "").trim();
    if (code === "42P01" || code === "3F000") {
      return {
        ok: false,
        applied: new Set(),
        reason: code === "3F000" ? "schema_missing" : "schema_migrations_missing",
      };
    }
    throw err;
  }
}

function checkSecretKeyrings() {
  const rings = [
    {
      name: "jwt",
      meta: getJwtKeyringMeta(),
    },
    {
      name: "message_encryption",
      meta: describeKeyring(
        buildSecretKeyring({
          purpose: "message-encryption",
          currentVersion: process.env.APP_MESSAGE_KEY_VERSION || "v1",
          singleSecret:
            process.env.APP_MESSAGE_KEY ||
            process.env.APP_DATA_KEY ||
            process.env.ADDRESS_DATA_KEY ||
            "",
          keyringString: process.env.APP_MESSAGE_KEYRING || "",
          keyringJson: process.env.APP_MESSAGE_KEYS_JSON || "",
          requiredInProduction: true,
          devFallbackSecret: "project-phoenix-local-dev-key-change-me",
        }),
      ),
    },
    {
      name: "chat_media",
      meta: describeKeyring(
        buildSecretKeyring({
          purpose: "chat-media",
          currentVersion:
            process.env.CHAT_MEDIA_TOKEN_SECRET_VERSION ||
            process.env.CHAT_MEDIA_TOKEN_KEY_VERSION ||
            "v1",
          singleSecret:
            process.env.CHAT_MEDIA_TOKEN_SECRET || process.env.JWT_SECRET || "",
          keyringString:
            process.env.CHAT_MEDIA_TOKEN_KEYRING ||
            process.env.CHAT_MEDIA_TOKEN_SECRETS ||
            "",
          keyringJson:
            process.env.CHAT_MEDIA_TOKEN_KEYS_JSON ||
            process.env.CHAT_MEDIA_SECRETS_JSON ||
            "",
          requiredInProduction: false,
          devFallbackSecret: "dev-chat-media-secret",
        }),
      ),
    },
    {
      name: "uploads",
      meta: describeKeyring(
        buildSecretKeyring({
          purpose: "uploads",
          currentVersion:
            process.env.UPLOADS_TOKEN_SECRET_VERSION ||
            process.env.UPLOADS_TOKEN_KEY_VERSION ||
            "v1",
          singleSecret:
            process.env.UPLOADS_TOKEN_SECRET ||
            process.env.CHAT_MEDIA_TOKEN_SECRET ||
            process.env.JWT_SECRET ||
            "",
          keyringString:
            process.env.UPLOADS_TOKEN_KEYRING ||
            process.env.UPLOADS_TOKEN_SECRETS ||
            "",
          keyringJson:
            process.env.UPLOADS_TOKEN_KEYS_JSON ||
            process.env.UPLOADS_SECRETS_JSON ||
            "",
          requiredInProduction: false,
          devFallbackSecret: "dev-uploads-secret",
        }),
      ),
    },
  ];

  for (const ring of rings) {
    const keyCount = Number(ring.meta?.keyCount || 0);
    if (keyCount <= 0) {
      addFinding(
        "critical",
        `secret.${ring.name}.missing`,
        `Keyring "${ring.name}" is empty`,
      );
      continue;
    }
    if (ring.meta?.usesDevFallback === true) {
      addFinding(
        IS_PRODUCTION ? "critical" : "info",
        `secret.${ring.name}.dev_fallback`,
        `Keyring "${ring.name}" uses a development fallback key`,
      );
    }
    if (keyCount < 2) {
      addFinding(
        IS_PRODUCTION ? "warn" : "info",
        `secret.${ring.name}.single_key`,
        `Keyring "${ring.name}" has only one key version (rotation grace is not armed)`,
      );
    } else {
      addFinding(
        "info",
        `secret.${ring.name}.rotation_ready`,
        `Keyring "${ring.name}" has ${keyCount} key versions`,
      );
    }
  }
}

function checkTransportHardening() {
  const enforceHttps = parseBooleanEnv(process.env.ENFORCE_HTTPS, IS_PRODUCTION);
  const trustProxyHops = parseNumberEnv(
    process.env.TRUST_PROXY_HOPS,
    IS_PRODUCTION ? 1 : 0,
  );

  if (IS_PRODUCTION && !enforceHttps) {
    addFinding(
      "critical",
      "transport.https.disabled",
      "ENFORCE_HTTPS is disabled in production",
    );
  } else if (enforceHttps) {
    addFinding("info", "transport.https.enabled", "HTTPS enforcement is enabled");
  } else {
    addFinding("info", "transport.https.disabled_dev", "HTTPS enforcement is disabled in development");
  }

  if (enforceHttps && trustProxyHops <= 0) {
    addFinding(
      "warn",
      "transport.proxy.misconfigured",
      "ENFORCE_HTTPS is enabled while TRUST_PROXY_HOPS is 0 (reverse proxy detection may fail)",
    );
  } else {
    addFinding(
      "info",
      "transport.proxy.config",
      `TRUST_PROXY_HOPS=${trustProxyHops}`,
    );
  }
}

function checkDependencyAudit() {
  const serverDir = path.resolve(__dirname, "..");
  try {
    execSync("npm audit --omit=dev --json", {
      cwd: serverDir,
      stdio: "pipe",
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024,
    });
    addFinding("info", "deps.audit.clean", "npm audit found no production vulnerabilities");
  } catch (err) {
    const stdout = String(err?.stdout || "").trim();
    const stderr = String(err?.stderr || "").trim();
    let critical = 0;
    let high = 0;
    try {
      const parsed = JSON.parse(stdout || "{}");
      critical = Number(parsed?.metadata?.vulnerabilities?.critical || 0);
      high = Number(parsed?.metadata?.vulnerabilities?.high || 0);
    } catch (_) {
      // no-op: keep defaults.
    }

    if (critical > 0) {
      addFinding(
        "critical",
        "deps.audit.critical",
        `npm audit found ${critical} critical vulnerabilities`,
      );
    }
    if (high > 0) {
      addFinding(
        "warn",
        "deps.audit.high",
        `npm audit found ${high} high vulnerabilities`,
      );
    }
    if (critical === 0 && high === 0) {
      addFinding(
        "warn",
        "deps.audit.parse_failed",
        "npm audit failed and vulnerability summary could not be parsed",
        {
          stderr: stderr.slice(0, 500),
        },
      );
    }
  }
}

function runMaintenanceCommand(command, successCode, failureCode, message) {
  const serverDir = path.resolve(__dirname, "..");
  try {
    const stdout = execSync(command, {
      cwd: serverDir,
      stdio: "pipe",
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024,
    });
    addFinding("info", successCode, message, {
      output: String(stdout || "").trim().slice(0, 1000),
    });
  } catch (err) {
    addFinding("warn", failureCode, `${message} failed`, {
      stdout: String(err?.stdout || "").trim().slice(0, 1000),
      stderr: String(err?.stderr || "").trim().slice(0, 1000),
    });
  }
}

async function checkMonitoringBacklog() {
  try {
    const unresolvedCritical = await db.query(
      `SELECT COUNT(*)::int AS count
       FROM monitoring_events
       WHERE resolved = false
         AND level IN ('critical', 'error')
         AND created_at >= now() - interval '24 hours'`,
    );
    const count = Number(unresolvedCritical.rows?.[0]?.count || 0);
    if (count > 0) {
      addFinding(
        "warn",
        "monitoring.unresolved_recent",
        `There are ${count} unresolved monitoring events (error/critical) in the last 24h`,
      );
    } else {
      addFinding(
        "info",
        "monitoring.unresolved_recent",
        "No unresolved error/critical monitoring events in the last 24h",
      );
    }
  } catch (err) {
    addFinding(
      "warn",
      "monitoring.check_unavailable",
      "Monitoring backlog check skipped (database unavailable)",
      {
        error: String(err?.message || err).slice(0, 300),
      },
    );
  }
}

async function checkNotificationQueueHealth() {
  try {
    const queueQ = await db.query(
      `SELECT
         COUNT(*) FILTER (
           WHERE channel = 'push'
             AND queue_name = 'push'
             AND state IN ('queued', 'failed')
             AND COALESCE(next_attempt_at, now()) <= now()
         )::int AS ready_count,
         COUNT(*) FILTER (
           WHERE channel = 'push'
             AND state = 'failed'
             AND updated_at >= now() - interval '24 hours'
         )::int AS failed_last_24h
       FROM notification_deliveries`,
    );
    const endpointQ = await db.query(
      `SELECT COUNT(*)::int AS failing_endpoints
         FROM notification_endpoints
        WHERE is_active = true
          AND COALESCE(consecutive_failures, 0) > 0`,
    );
    const readyCount = Number(queueQ.rows?.[0]?.ready_count || 0) || 0;
    const failedLast24h = Number(queueQ.rows?.[0]?.failed_last_24h || 0) || 0;
    const failingEndpoints =
      Number(endpointQ.rows?.[0]?.failing_endpoints || 0) || 0;

    if (readyCount > 250) {
      addFinding(
        "warn",
        "notifications.queue.backlog",
        `Notification queue backlog is elevated (${readyCount} ready deliveries)`,
      );
    } else {
      addFinding(
        "info",
        "notifications.queue.backlog",
        `Notification queue ready deliveries: ${readyCount}`,
      );
    }

    if (failedLast24h > 0 || failingEndpoints > 0) {
      addFinding(
        "warn",
        "notifications.queue.failures",
        `Notification queue has failures (deliveries_24h=${failedLast24h}, endpoints=${failingEndpoints})`,
      );
    } else {
      addFinding(
        "info",
        "notifications.queue.failures",
        "Notification queue has no active failures",
      );
    }
  } catch (err) {
    addFinding(
      "warn",
      "notifications.queue.unavailable",
      "Notification queue health check skipped",
      {
        error: String(err?.message || err).slice(0, 300),
      },
    );
  }
}

async function checkTenantFeaturePolicy() {
  try {
    const tenantsQ = await db.platformQuery(
      `SELECT id
       FROM tenants
       ORDER BY created_at`,
    );
    const totals = {
      tenants_checked: 0,
      phone_access_approval_enabled: 0,
      group_switcher_disabled: 0,
      qr_existing_client_join_disabled: 0,
      client_cancel_anytime_disabled: 0,
    };

    for (const row of tenantsQ.rows || []) {
      const tenantId = String(row.id || "").trim();
      if (!tenantId) continue;
      totals.tenants_checked += 1;
      const settings = await getTenantFeatureSettings(tenantId);
      if (
        settings.phone_access_approval_enabled !== false ||
        settings.client?.phone_access_approval_enabled !== false
      ) {
        totals.phone_access_approval_enabled += 1;
      }
      if (
        settings.client_group_switcher_enabled !== true ||
        settings.client?.group_switcher_enabled !== true
      ) {
        totals.group_switcher_disabled += 1;
      }
      if (
        settings.qr_existing_client_join_enabled !== true ||
        settings.client?.qr_existing_client_join_enabled !== true
      ) {
        totals.qr_existing_client_join_disabled += 1;
      }
      if (
        settings.client_cancel_anytime_enabled !== true ||
        settings.delivery?.client_cancel_anytime_enabled !== true
      ) {
        totals.client_cancel_anytime_disabled += 1;
      }
    }

    if (totals.phone_access_approval_enabled > 0) {
      addFinding(
        "critical",
        "tenant_features.phone_access_enabled",
        "Phone access approval is enabled for at least one tenant",
        totals,
      );
      return;
    }

    const driftCount =
      totals.group_switcher_disabled +
      totals.qr_existing_client_join_disabled +
      totals.client_cancel_anytime_disabled;
    if (driftCount > 0) {
      addFinding(
        "warn",
        "tenant_features.policy_drift",
        "Tenant feature settings drift from current platform defaults",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "tenant_features.policy_ok",
      "Tenant feature settings match current platform policy",
      totals,
    );
  } catch (err) {
    addFinding(
      "warn",
      "tenant_features.check_unavailable",
      "Tenant feature policy check skipped",
      {
        error: String(err?.message || err).slice(0, 300),
      },
    );
  }
}

async function checkTenantMigrationDrift() {
  const expected = listExpectedMigrationFiles();
  if (expected.length === 0) {
    addFinding(
      "warn",
      "tenant_migrations.no_migration_files",
      "Migration drift check skipped because no migration files were found",
    );
    return;
  }

  const totals = {
    expected_migrations: expected.length,
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    pending_targets: 0,
    unavailable_targets: 0,
    max_pending_migrations: 0,
    pending_migration_files: [],
  };
  const pendingFileNames = new Set();

  async function inspectTarget({ pool, schemaName, mode }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    const applied = await readAppliedMigrationFiles(pool, schemaName);
    if (!applied.ok) {
      totals.unavailable_targets += 1;
    }
    const missing = expected.filter((file) => !applied.applied.has(file));
    if (missing.length > 0) {
      totals.pending_targets += 1;
      totals.max_pending_migrations = Math.max(
        totals.max_pending_migrations,
        missing.length,
      );
      for (const file of missing) pendingFileNames.add(file);
    }
  }

  try {
    await inspectTarget({
      pool: db.platformPool,
      schemaName: "public",
      mode: "platform",
    });

    const tenantsQ = await db.platformQuery(
      `SELECT db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated") {
        const dbUrl = String(tenant?.db_url || "").trim();
        if (!dbUrl) {
          totals.targets_checked += 1;
          totals.isolated_targets += 1;
          totals.unavailable_targets += 1;
          continue;
        }
        const pool = new Pool({ connectionString: dbUrl });
        try {
          await inspectTarget({ pool, schemaName: "public", mode });
        } finally {
          await pool.end();
        }
        continue;
      }

      if (mode === "schema_isolated") {
        const schemaName = normalizePgSchema(tenant?.db_schema || "");
        if (!schemaName) {
          totals.targets_checked += 1;
          totals.schema_isolated_targets += 1;
          totals.unavailable_targets += 1;
          continue;
        }
        await inspectTarget({
          pool: db.platformPool,
          schemaName,
          mode,
        });
      }
    }

    totals.pending_migration_files = Array.from(pendingFileNames)
      .sort()
      .slice(0, 30);

    if (totals.pending_targets > 0 || totals.unavailable_targets > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "tenant_migrations.drift",
        "One or more database targets are missing expected migrations",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "tenant_migrations.synced",
      "Platform and tenant database targets have all expected migrations",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "tenant_migrations.check_failed",
      "Tenant migration drift check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
      },
    );
  }
}

async function loadExpectedTenantIndexUsers(tenant) {
  return await db.runWithTenantRow(tenant, async () => {
    const tenantId = String(tenant?.id || "").trim();
    const allowLegacyNullTenantRows =
      db.isIsolatedTenantRow(tenant) || db.isSchemaIsolatedTenantRow(tenant);
    const q = await db.query(
      `SELECT DISTINCT ON (lower(email))
              id,
              lower(email) AS email,
              lower(trim(COALESCE(role, 'client'))) AS role,
              COALESCE(is_active, true) AS is_active
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

async function checkTenantUserIndexDrift() {
  const totals = {
    tenants_checked: 0,
    expected_users: 0,
    indexed_rows: 0,
    drift_tenants: 0,
    missing_index_rows: 0,
    stale_index_rows: 0,
    mismatched_index_rows: 0,
    orphan_index_rows: 0,
  };

  try {
    const orphanQ = await db.platformQuery(
      `SELECT COUNT(*)::int AS count
       FROM tenant_user_index tui
       LEFT JOIN tenants t ON t.id = tui.tenant_id
       WHERE t.id IS NULL
          OR COALESCE(t.is_deleted, false) = true`,
    );
    totals.orphan_index_rows = Number(orphanQ.rows?.[0]?.count || 0) || 0;

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_name,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const tenantId = String(tenant?.id || "").trim();
      if (!tenantId) continue;
      totals.tenants_checked += 1;

      const expectedUsers = await loadExpectedTenantIndexUsers(tenant);
      const indexedQ = await db.platformQuery(
        `SELECT user_id,
                lower(email) AS email,
                lower(trim(COALESCE(role, 'client'))) AS role,
                COALESCE(is_active, true) AS is_active
         FROM tenant_user_index
         WHERE tenant_id = $1::uuid`,
        [tenantId],
      );

      totals.expected_users += expectedUsers.length;
      totals.indexed_rows += indexedQ.rowCount || 0;

      const expectedByUserId = new Map();
      for (const user of expectedUsers) {
        const userId = String(user?.id || "").trim();
        if (!userId) continue;
        expectedByUserId.set(userId, {
          email: String(user?.email || "").trim().toLowerCase(),
          role: String(user?.role || "client").trim().toLowerCase() || "client",
          isActive: user.is_active === true,
        });
      }

      const indexedByUserId = new Map();
      for (const row of indexedQ.rows || []) {
        const userId = String(row?.user_id || "").trim();
        if (!userId) continue;
        indexedByUserId.set(userId, {
          email: String(row?.email || "").trim().toLowerCase(),
          role: String(row?.role || "client").trim().toLowerCase() || "client",
          isActive: row.is_active === true,
        });
      }

      let tenantHasDrift = false;
      for (const [userId, expected] of expectedByUserId.entries()) {
        const indexed = indexedByUserId.get(userId);
        if (!indexed) {
          totals.missing_index_rows += 1;
          tenantHasDrift = true;
          continue;
        }
        if (
          indexed.email !== expected.email ||
          indexed.role !== expected.role ||
          indexed.isActive !== expected.isActive
        ) {
          totals.mismatched_index_rows += 1;
          tenantHasDrift = true;
        }
      }

      for (const userId of indexedByUserId.keys()) {
        if (!expectedByUserId.has(userId)) {
          totals.stale_index_rows += 1;
          tenantHasDrift = true;
        }
      }

      if (tenantHasDrift) totals.drift_tenants += 1;
    }

    const driftCount =
      totals.missing_index_rows +
      totals.stale_index_rows +
      totals.mismatched_index_rows +
      totals.orphan_index_rows;
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "tenant_user_index.drift",
        "Tenant user index differs from tenant database users",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "tenant_user_index.synced",
      "Tenant user index matches tenant database users",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "tenant_user_index.check_failed",
      "Tenant user index drift check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        tenants_checked: totals.tenants_checked,
      },
    );
  }
}

function checkBackupFreshness() {
  try {
    if (!IS_PRODUCTION && !process.env.FENIX_BACKUP_ROOT) {
      addFinding(
        "info",
        "backup.skipped_dev",
        "Backup freshness check skipped outside production",
      );
      return;
    }
    const backupRoot = process.env.FENIX_BACKUP_ROOT || '/opt/fenix-backups/postgres';
    const targetDir = backupRoot.endsWith('/postgres')
      ? backupRoot
      : path.join(backupRoot, 'postgres');
    if (!fs.existsSync(targetDir)) {
      addFinding(
        "warn",
        "backup.missing_dir",
        `Backup directory not found: ${targetDir}`,
      );
      return;
    }
    const files = fs
      .readdirSync(targetDir)
      .map((name) => path.join(targetDir, name))
      .filter((filePath) => {
        try {
          return fs.statSync(filePath).isFile();
        } catch (_) {
          return false;
        }
      })
      .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);
    if (files.length === 0) {
      addFinding("warn", "backup.empty", "No postgres backups found");
      return;
    }
    const newest = files[0];
    const ageHours = Math.round((Date.now() - fs.statSync(newest).mtimeMs) / (60 * 60 * 1000));
    if (ageHours > 30) {
      addFinding(
        "warn",
        "backup.stale",
        `Latest postgres backup is stale (${ageHours}h old)`,
        { latest_backup: newest },
      );
      return;
    }
    addFinding(
      "info",
      "backup.fresh",
      `Latest postgres backup age=${ageHours}h`,
      { latest_backup: newest },
    );
  } catch (err) {
    addFinding(
      "warn",
      "backup.check_failed",
      "Backup freshness check failed",
      {
        error: String(err?.message || err).slice(0, 300),
      },
    );
  }
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (err) {
    return { __parse_error: String(err?.message || err) };
  }
}

function toSafeFileName(rawValue) {
  const candidate = String(rawValue || "").trim();
  if (!candidate) return "";
  const safeName = path.basename(candidate);
  if (!safeName || safeName === "." || safeName === "..") return "";
  return safeName;
}

function checkAndroidReleaseConfig() {
  try {
    const releasePath = path.join(downloadsRoot, ANDROID_STABLE_RELEASE_FILE);
    if (fs.existsSync(releasePath)) {
      const parsed = readJsonFile(releasePath);
      if (parsed.__parse_error) {
        addFinding(
          "warn",
          "android.release.invalid_json",
          "Android stable release JSON is invalid",
          {
            release_file: releasePath,
            error: parsed.__parse_error.slice(0, 300),
          },
        );
        return;
      }

      const apkFile = toSafeFileName(parsed.apk_file);
      const version = String(parsed.version || "").trim();
      const build = Number.parseInt(String(parsed.build || "").trim(), 10);
      if (!apkFile || !version || !Number.isFinite(build) || build <= 0) {
        addFinding(
          "warn",
          "android.release.incomplete_json",
          "Android stable release JSON is missing required fields",
          {
            release_file: releasePath,
            has_apk_file: Boolean(apkFile),
            has_version: Boolean(version),
            build: Number.isFinite(build) ? build : null,
          },
        );
        return;
      }

      const apkPath = path.join(downloadsRoot, apkFile);
      if (!fs.existsSync(apkPath)) {
        addFinding(
          "warn",
          "android.release.missing_apk",
          "Android stable release APK from release JSON is missing",
          {
            release_file: releasePath,
            apk_file: apkFile,
          },
        );
        return;
      }

      const stat = fs.statSync(apkPath);
      addFinding(
        "info",
        "android.release.ok",
        `Android stable release is configured (${version}+${build})`,
        {
          release_file: releasePath,
          apk_file: apkFile,
          apk_size: stat.size,
        },
      );
      return;
    }

    const defaultFile = toSafeFileName(process.env.APP_UPDATE_ANDROID_DEFAULT_FILE);
    if (defaultFile) {
      const defaultPath = path.join(downloadsRoot, defaultFile);
      if (!fs.existsSync(defaultPath)) {
        addFinding(
          "warn",
          "android.release.default_missing",
          "APP_UPDATE_ANDROID_DEFAULT_FILE points to a missing APK",
          { apk_file: defaultFile },
        );
        return;
      }
      addFinding(
        "info",
        "android.release.default_ok",
        "Android default APK file is configured",
        {
          apk_file: defaultFile,
          apk_size: fs.statSync(defaultPath).size,
        },
      );
      return;
    }

    const androidUpdatesEnabled = parseBooleanEnv(
      process.env.APP_UPDATE_ANDROID_ENABLED,
      IS_PRODUCTION,
    );
    addFinding(
      androidUpdatesEnabled ? "warn" : "info",
      "android.release.not_configured",
      androidUpdatesEnabled
        ? "Android updates are enabled but no release JSON or default APK is configured"
        : "Android release check skipped because updates are disabled",
    );
  } catch (err) {
    addFinding(
      "warn",
      "android.release.check_failed",
      "Android release configuration check failed",
      {
        error: String(err?.message || err).slice(0, 300),
      },
    );
  }
}

function buildMarkdownReport() {
  const now = new Date();
  const critical = findings.filter((f) => f.level === "critical").length;
  const warn = findings.filter((f) => f.level === "warn").length;
  const info = findings.filter((f) => f.level === "info").length;

  const lines = [];
  lines.push(`# Nightly Self-Audit`);
  lines.push("");
  lines.push(`- Generated at: ${now.toISOString()}`);
  lines.push(`- Environment: ${NODE_ENV || "unknown"}`);
  lines.push(`- Findings: critical=${critical}, warn=${warn}, info=${info}`);
  lines.push("");
  lines.push(`## Findings`);
  lines.push("");
  for (const finding of findings) {
    lines.push(
      `- [${finding.level.toUpperCase()}] ${finding.code}: ${finding.message}`,
    );
  }
  lines.push("");
  lines.push(`## Details`);
  lines.push("");
  for (const finding of findings) {
    if (!finding.details || Object.keys(finding.details).length === 0) continue;
    lines.push(`### ${finding.code}`);
    lines.push("```json");
    lines.push(JSON.stringify(finding.details, null, 2));
    lines.push("```");
    lines.push("");
  }
  return lines.join("\n");
}

function buildAuditSummary() {
  const critical = findings.filter((f) => f.level === "critical").length;
  const warn = findings.filter((f) => f.level === "warn").length;
  const info = findings.filter((f) => f.level === "info").length;
  return { critical, warn, info };
}

async function main() {
  checkSecretKeyrings();
  checkTransportHardening();
  checkDependencyAudit();
  runMaintenanceCommand(
    "node scripts/media_assets_sanitize.js",
    "media.sanitize.ok",
    "media.sanitize.failed",
    "Nightly media sanitation",
  );
  runMaintenanceCommand(
    "node scripts/perf_budget_smoke.js",
    "perf.budget.ok",
    "perf.budget.failed",
    "Performance budget smoke",
  );
  await checkMonitoringBacklog();
  await checkNotificationQueueHealth();
  await checkTenantFeaturePolicy();
  await checkTenantMigrationDrift();
  await checkTenantUserIndexDrift();
  checkBackupFreshness();
  checkAndroidReleaseConfig();

  const summary = buildAuditSummary();

  const outputPath = path.resolve(
    process.cwd(),
    process.env.AUDIT_OUTPUT_PATH || "audit/nightly-self-audit.md",
  );
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, buildMarkdownReport(), "utf8");
  console.log(`nightly self-audit report: ${outputPath}`);

  await logReleaseCheck({
    queryable: db,
    scope: "nightly_audit",
    status: summary.critical > 0 ? "fail" : summary.warn > 0 ? "warn" : "pass",
    title: "Nightly self-audit",
    target: process.env.PUBLIC_BASE_URL || process.env.API_PUBLIC_BASE_URL || "local",
    summary: `critical=${summary.critical}, warn=${summary.warn}, info=${summary.info}`,
    details: {
      output_path: outputPath,
      findings,
      environment: NODE_ENV || "unknown",
    },
  });

  const hasCritical = findings.some((f) => f.level === "critical");
  if (hasCritical) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error("nightly-self-audit failed", err);
  process.exit(1);
}).finally(async () => {
  try {
    await db.platformPool.end();
  } catch (_) {
    // ignore pool close errors
  }
});
