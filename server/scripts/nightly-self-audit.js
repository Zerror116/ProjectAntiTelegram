#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execFileSync, execSync } = require("child_process");
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

const SHARED_SCHEMA_CONTRACT = [
  {
    table: "users",
    columns: [
      "id",
      "email",
      "password_hash",
      "role",
      "is_active",
      "tenant_id",
      "created_at",
    ],
  },
  {
    table: "phones",
    columns: ["id", "user_id", "phone", "status", "created_at"],
  },
  {
    table: "user_sessions",
    columns: [
      "id",
      "user_id",
      "session_public_id",
      "refresh_token_hash",
      "is_active",
      "expires_at",
    ],
  },
  {
    table: "auth_email_tokens",
    columns: [
      "id",
      "user_id",
      "tenant_id",
      "email",
      "kind",
      "token_hash",
      "expires_at",
      "used_at",
      "created_at",
    ],
  },
  {
    table: "notification_endpoints",
    columns: ["id", "tenant_id", "user_id", "platform", "transport", "is_active"],
  },
  {
    table: "chats",
    columns: ["id", "tenant_id", "title", "type", "settings", "updated_at"],
  },
  {
    table: "chat_members",
    columns: ["id", "chat_id", "user_id", "joined_at"],
  },
  {
    table: "messages",
    columns: ["id", "chat_id", "sender_id", "text", "meta", "created_at"],
  },
  {
    table: "products",
    columns: [
      "id",
      "title",
      "description",
      "price",
      "quantity",
      "image_url",
      "status",
      "manual_shelf_label",
      "shelf_floor",
      "pickup_only",
      "is_bulky",
      "deleted_at",
    ],
  },
  {
    table: "product_publication_queue",
    columns: [
      "id",
      "product_id",
      "channel_id",
      "status",
      "is_sent",
      "publish_batch_id",
      "publish_status",
      "publish_started_at",
      "publish_finished_at",
      "pickup_only",
      "is_bulky",
    ],
  },
  {
    table: "channel_publication_batches",
    columns: [
      "id",
      "channel_id",
      "status",
      "total_count",
      "published_count",
      "failed_count",
      "next_publish_at",
      "updated_at",
    ],
  },
  {
    table: "cart_items",
    columns: ["id", "user_id", "product_id", "quantity", "status", "updated_at"],
  },
  {
    table: "reservations",
    columns: [
      "id",
      "user_id",
      "product_id",
      "cart_item_id",
      "quantity",
      "is_fulfilled",
      "is_sent",
    ],
  },
  {
    table: "delivery_batches",
    columns: ["id", "delivery_date", "status", "threshold_amount", "updated_at"],
  },
  {
    table: "delivery_batch_customers",
    columns: [
      "id",
      "batch_id",
      "user_id",
      "processed_sum",
      "delivery_status",
      "assembly_status",
    ],
  },
  {
    table: "delivery_batch_items",
    columns: [
      "id",
      "batch_id",
      "batch_customer_id",
      "cart_item_id",
      "user_id",
      "product_id",
      "quantity",
      "assembly_status",
      "is_bulky",
    ],
  },
  {
    table: "tenant_feature_settings",
    columns: ["tenant_id", "settings", "updated_at"],
  },
];

const PLATFORM_SCHEMA_CONTRACT = [
  {
    table: "tenants",
    columns: [
      "id",
      "code",
      "name",
      "status",
      "subscription_expires_at",
      "db_mode",
      "db_url",
      "db_schema",
      "is_deleted",
    ],
  },
  {
    table: "tenant_user_index",
    columns: [
      "tenant_id",
      "user_id",
      "email",
      "role",
      "is_active",
      "updated_at",
    ],
  },
];

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

function checkUploadRecoveryHealth() {
  const serverDir = path.resolve(__dirname, "..");
  const outputPath = path.resolve(
    serverDir,
    "audit/uploads-recovery-summary.json",
  );
  try {
    execFileSync(
      "node",
      [
        "scripts/uploads_recovery_audit.js",
        "--missing-only",
        "--summary-only",
        "--output",
        outputPath,
      ],
      {
        cwd: serverDir,
        stdio: "pipe",
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
      },
    );
    const parsed = readJsonFile(outputPath);
    if (parsed.__parse_error) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "uploads.recovery.invalid_summary",
        "Uploads recovery summary JSON could not be parsed",
        {
          error: parsed.__parse_error.slice(0, 300),
        },
      );
      return;
    }

    const summary = parsed.summary || {};
    const details = {
      scopes_checked: Number(parsed.scopes_checked || 0) || 0,
      entries_checked: (Array.isArray(parsed.scopes) ? parsed.scopes : [])
        .reduce((sum, row) => sum + (Number(row?.entries || 0) || 0), 0),
      missing: Number(summary.missing || 0) || 0,
      skipped: Number(parsed.skipped_count || 0) || 0,
      by_kind: summary.by_kind || {},
    };

    if (details.missing > 0 || details.skipped > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "uploads.recovery.missing_refs",
        "One or more upload references are missing across database targets",
        details,
      );
      return;
    }

    addFinding(
      "info",
      "uploads.recovery.healthy",
      "Upload references are present across database targets",
      details,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "uploads.recovery.check_failed",
      "Uploads recovery health check failed",
      {
        error: String(err?.message || err).slice(0, 300),
      },
    );
  }
}

async function checkMonitoringBacklog() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    unresolved_recent: 0,
  };

  async function readTargetStats() {
    return await db.query(
      `SELECT COUNT(*)::int AS unresolved_recent
       FROM monitoring_events
       WHERE resolved = false
         AND level IN ('critical', 'error')
         AND created_at >= now() - interval '24 hours'`,
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      totals.unresolved_recent +=
        Number(q.rows?.[0]?.unresolved_recent || 0) || 0;
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND COALESCE(status, 'active') = 'active'
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    if (totals.unavailable_targets > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "monitoring.unavailable_targets",
        "Monitoring backlog check could not inspect every database target",
        totals,
      );
      return;
    }

    if (totals.unresolved_recent > 0) {
      addFinding(
        "warn",
        "monitoring.unresolved_recent",
        `There are ${totals.unresolved_recent} unresolved monitoring events (error/critical) in the last 24h`,
        totals,
      );
    } else {
      addFinding(
        "info",
        "monitoring.unresolved_recent",
        "No unresolved error/critical monitoring events in the last 24h",
        totals,
      );
    }
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "monitoring.check_failed",
      "Monitoring backlog check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
      },
    );
  }
}

async function checkNotificationQueueHealth() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    ready_count: 0,
    stale_processing_count: 0,
    failed_last_24h: 0,
    failing_endpoints: 0,
  };

  async function readTargetStats() {
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
             AND queue_name = 'push'
             AND state IN ('queued', 'failed')
             AND processing_started_at IS NOT NULL
             AND processing_started_at < now() - interval '5 minutes'
         )::int AS stale_processing_count,
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
    return {
      ready_count: Number(queueQ.rows?.[0]?.ready_count || 0) || 0,
      stale_processing_count:
        Number(queueQ.rows?.[0]?.stale_processing_count || 0) || 0,
      failed_last_24h: Number(queueQ.rows?.[0]?.failed_last_24h || 0) || 0,
      failing_endpoints:
        Number(endpointQ.rows?.[0]?.failing_endpoints || 0) || 0,
    };
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const stats = await run(readTargetStats);
      totals.ready_count += Number(stats.ready_count || 0) || 0;
      totals.stale_processing_count +=
        Number(stats.stale_processing_count || 0) || 0;
      totals.failed_last_24h += Number(stats.failed_last_24h || 0) || 0;
      totals.failing_endpoints += Number(stats.failing_endpoints || 0) || 0;
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND COALESCE(status, 'active') = 'active'
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    if (totals.unavailable_targets > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "notifications.queue.unavailable",
        "Notification queue health check could not inspect every database target",
        totals,
      );
      return;
    }

    if (totals.ready_count > 250 || totals.stale_processing_count > 0) {
      addFinding(
        "warn",
        "notifications.queue.backlog",
        `Notification queue backlog is elevated (ready=${totals.ready_count}, stale_processing=${totals.stale_processing_count})`,
        totals,
      );
    } else {
      addFinding(
        "info",
        "notifications.queue.backlog",
        `Notification queue ready deliveries: ${totals.ready_count}`,
        totals,
      );
    }

    if (totals.failed_last_24h > 0 || totals.failing_endpoints > 0) {
      addFinding(
        "warn",
        "notifications.queue.failures",
        `Notification queue has failures (deliveries_24h=${totals.failed_last_24h}, endpoints=${totals.failing_endpoints})`,
        totals,
      );
    } else {
      addFinding(
        "info",
        "notifications.queue.failures",
        "Notification queue has no active failures",
        totals,
      );
    }
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "notifications.queue.check_failed",
      "Notification queue health check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
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

async function checkAuthSessionHealth() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    active_sessions: 0,
    active_sessions_with_expiry: 0,
    active_expired_sessions: 0,
    active_refresh_sessions: 0,
    active_refresh_without_public_id: 0,
    active_sessions_missing_user_id: 0,
    auth_session_auto_expiry_env_enabled: parseBooleanEnv(
      process.env.AUTH_SESSION_AUTO_EXPIRY_ENABLED,
      false,
    )
      ? 1
      : 0,
  };

  async function readTargetStats() {
    return await db.query(
      `SELECT
         COUNT(*) FILTER (WHERE is_active = true)::int AS active_sessions,
         COUNT(*) FILTER (
           WHERE is_active = true
             AND expires_at IS NOT NULL
         )::int AS active_sessions_with_expiry,
         COUNT(*) FILTER (
           WHERE is_active = true
             AND expires_at IS NOT NULL
             AND expires_at <= now()
         )::int AS active_expired_sessions,
         COUNT(*) FILTER (
           WHERE is_active = true
             AND refresh_token_hash IS NOT NULL
         )::int AS active_refresh_sessions,
         COUNT(*) FILTER (
           WHERE is_active = true
             AND refresh_token_hash IS NOT NULL
             AND NULLIF(BTRIM(session_public_id), '') IS NULL
         )::int AS active_refresh_without_public_id,
         COUNT(*) FILTER (
           WHERE is_active = true
             AND user_id IS NULL
         )::int AS active_sessions_missing_user_id
       FROM user_sessions`,
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      const row = q.rows?.[0] || {};
      totals.active_sessions += Number(row.active_sessions || 0) || 0;
      totals.active_sessions_with_expiry +=
        Number(row.active_sessions_with_expiry || 0) || 0;
      totals.active_expired_sessions +=
        Number(row.active_expired_sessions || 0) || 0;
      totals.active_refresh_sessions +=
        Number(row.active_refresh_sessions || 0) || 0;
      totals.active_refresh_without_public_id +=
        Number(row.active_refresh_without_public_id || 0) || 0;
      totals.active_sessions_missing_user_id +=
        Number(row.active_sessions_missing_user_id || 0) || 0;
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    const driftCount =
      totals.auth_session_auto_expiry_env_enabled +
      totals.unavailable_targets +
      totals.active_sessions_with_expiry +
      totals.active_refresh_without_public_id +
      totals.active_sessions_missing_user_id;
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "auth_sessions.policy_drift",
        "Auth session state differs from persistent-session policy",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "auth_sessions.healthy",
      "Auth sessions match persistent-session policy across database targets",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "auth_sessions.check_failed",
      "Auth session health check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
      },
    );
  }
}

async function checkAuthIdentityIntegrity() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    duplicate_active_email_groups: 0,
    duplicate_active_email_users: 0,
    duplicate_active_phone_groups: 0,
    duplicate_active_phone_users: 0,
    active_email_groups_without_valid_password: 0,
    active_email_users_without_valid_password: 0,
    active_users_missing_password_hash: 0,
    active_client_users_missing_password_hash: 0,
    active_staff_users_missing_password_hash: 0,
    active_missing_password_users_with_active_session: 0,
    active_missing_password_users_with_active_endpoint: 0,
    active_missing_password_users_indexed: 0,
    active_missing_password_users_with_phone: 0,
    active_users_invalid_password_hash: 0,
    phone_rows_without_user: 0,
    active_sessions_for_inactive_users: 0,
    active_notification_endpoints_for_inactive_users: 0,
    pending_phone_requests_without_active_owner: 0,
    pending_phone_requests_without_active_requester: 0,
  };

  const numericFields = [
    "duplicate_active_email_groups",
    "duplicate_active_email_users",
    "duplicate_active_phone_groups",
    "duplicate_active_phone_users",
    "active_email_groups_without_valid_password",
    "active_email_users_without_valid_password",
    "active_users_missing_password_hash",
    "active_client_users_missing_password_hash",
    "active_staff_users_missing_password_hash",
    "active_missing_password_users_with_active_session",
    "active_missing_password_users_with_active_endpoint",
    "active_missing_password_users_indexed",
    "active_missing_password_users_with_phone",
    "active_users_invalid_password_hash",
    "phone_rows_without_user",
    "active_sessions_for_inactive_users",
    "active_notification_endpoints_for_inactive_users",
    "pending_phone_requests_without_active_owner",
    "pending_phone_requests_without_active_requester",
  ];
  const hardDriftFields = [
    "duplicate_active_email_groups",
    "duplicate_active_email_users",
    "active_users_invalid_password_hash",
    "phone_rows_without_user",
    "active_sessions_for_inactive_users",
    "active_notification_endpoints_for_inactive_users",
  ];

  async function readTargetStats() {
    return await db.query(
      `WITH active_users AS (
         SELECT u.id,
                COALESCE(u.tenant_id, '00000000-0000-0000-0000-000000000000'::uuid) AS tenant_scope,
                lower(NULLIF(BTRIM(u.email), '')) AS email_key,
                COALESCE(NULLIF(BTRIM(lower(u.role)), ''), 'client') AS role_key,
                COALESCE(u.password_hash, '') AS password_hash,
                EXISTS (
                  SELECT 1
                    FROM user_sessions s
                   WHERE s.user_id = u.id
                     AND s.is_active = true
                ) AS has_active_session,
                EXISTS (
                  SELECT 1
                    FROM notification_endpoints e
                   WHERE e.user_id = u.id
                     AND e.is_active = true
                ) AS has_active_endpoint,
                EXISTS (
                  SELECT 1
                    FROM tenant_user_index tui
                   WHERE tui.user_id = u.id
                     AND tui.is_active = true
                ) AS indexed_active,
                EXISTS (
                  SELECT 1
                    FROM phones p
                   WHERE p.user_id = u.id
                     AND NULLIF(BTRIM(p.phone), '') IS NOT NULL
                ) AS has_phone
           FROM users u
          WHERE COALESCE(u.is_active, true) = true
       ),
       duplicate_email_groups AS (
         SELECT tenant_scope,
                email_key,
                COUNT(*)::int AS user_count
           FROM active_users
          WHERE email_key IS NOT NULL
          GROUP BY tenant_scope, email_key
         HAVING COUNT(*) > 1
       ),
       credential_email_groups AS (
         SELECT tenant_scope,
                email_key,
                COUNT(*)::int AS user_count,
                COUNT(*) FILTER (
                  WHERE password_hash ~ '^\\$2[aby]\\$[0-9]{2}\\$.{53}$'
                )::int AS valid_password_count,
                COUNT(*) FILTER (
                  WHERE NULLIF(BTRIM(password_hash), '') IS NULL
                )::int AS missing_password_count,
                COUNT(*) FILTER (
                  WHERE NULLIF(BTRIM(password_hash), '') IS NOT NULL
                    AND password_hash !~ '^\\$2[aby]\\$[0-9]{2}\\$.{53}$'
                )::int AS invalid_password_count
           FROM active_users
          WHERE email_key IS NOT NULL
          GROUP BY tenant_scope, email_key
       ),
       phone_rows AS (
         SELECT p.id,
                p.user_id,
                COALESCE(u.tenant_id, '00000000-0000-0000-0000-000000000000'::uuid) AS tenant_scope,
                u.id IS NOT NULL AS has_user,
                COALESCE(u.is_active, false) AS user_is_active,
                RIGHT(regexp_replace(COALESCE(p.phone, ''), '[^0-9]', '', 'g'), 10) AS phone_core10
           FROM phones p
           LEFT JOIN users u ON u.id = p.user_id
       ),
       duplicate_phone_groups AS (
         SELECT tenant_scope,
                phone_core10,
                COUNT(DISTINCT user_id)::int AS user_count
           FROM phone_rows
          WHERE has_user = true
            AND user_is_active = true
            AND length(phone_core10) = 10
          GROUP BY tenant_scope, phone_core10
         HAVING COUNT(DISTINCT user_id) > 1
       )
       SELECT
         COALESCE((SELECT COUNT(*)::int FROM duplicate_email_groups), 0)::int AS duplicate_active_email_groups,
         COALESCE((SELECT SUM(user_count)::int FROM duplicate_email_groups), 0)::int AS duplicate_active_email_users,
         COALESCE((SELECT COUNT(*)::int FROM duplicate_phone_groups), 0)::int AS duplicate_active_phone_groups,
         COALESCE((SELECT SUM(user_count)::int FROM duplicate_phone_groups), 0)::int AS duplicate_active_phone_users,
         COALESCE((SELECT COUNT(*)::int FROM credential_email_groups WHERE valid_password_count = 0), 0)::int AS active_email_groups_without_valid_password,
         COALESCE((SELECT SUM(user_count)::int FROM credential_email_groups WHERE valid_password_count = 0), 0)::int AS active_email_users_without_valid_password,
         COALESCE((SELECT SUM(missing_password_count)::int FROM credential_email_groups), 0)::int AS active_users_missing_password_hash,
         (
           SELECT COUNT(*)::int
             FROM active_users
            WHERE email_key IS NOT NULL
              AND NULLIF(BTRIM(password_hash), '') IS NULL
              AND role_key = 'client'
         ) AS active_client_users_missing_password_hash,
         (
           SELECT COUNT(*)::int
             FROM active_users
            WHERE email_key IS NOT NULL
              AND NULLIF(BTRIM(password_hash), '') IS NULL
              AND role_key IN ('worker', 'admin', 'tenant', 'creator')
         ) AS active_staff_users_missing_password_hash,
         (
           SELECT COUNT(*)::int
             FROM active_users
            WHERE email_key IS NOT NULL
              AND NULLIF(BTRIM(password_hash), '') IS NULL
              AND has_active_session = true
         ) AS active_missing_password_users_with_active_session,
         (
           SELECT COUNT(*)::int
             FROM active_users
            WHERE email_key IS NOT NULL
              AND NULLIF(BTRIM(password_hash), '') IS NULL
              AND has_active_endpoint = true
         ) AS active_missing_password_users_with_active_endpoint,
         (
           SELECT COUNT(*)::int
             FROM active_users
            WHERE email_key IS NOT NULL
              AND NULLIF(BTRIM(password_hash), '') IS NULL
              AND indexed_active = true
         ) AS active_missing_password_users_indexed,
         (
           SELECT COUNT(*)::int
             FROM active_users
            WHERE email_key IS NOT NULL
              AND NULLIF(BTRIM(password_hash), '') IS NULL
              AND has_phone = true
         ) AS active_missing_password_users_with_phone,
         COALESCE((SELECT SUM(invalid_password_count)::int FROM credential_email_groups), 0)::int AS active_users_invalid_password_hash,
         COALESCE((SELECT COUNT(*)::int FROM phone_rows WHERE has_user = false), 0)::int AS phone_rows_without_user,
         (
           SELECT COUNT(*)::int
             FROM user_sessions s
             JOIN users u ON u.id = s.user_id
            WHERE s.is_active = true
              AND COALESCE(u.is_active, true) = false
         ) AS active_sessions_for_inactive_users,
         (
           SELECT COUNT(*)::int
             FROM notification_endpoints e
             JOIN users u ON u.id = e.user_id
            WHERE e.is_active = true
              AND COALESCE(u.is_active, true) = false
         ) AS active_notification_endpoints_for_inactive_users,
         (
           SELECT COUNT(*)::int
             FROM phone_registration_requests r
             LEFT JOIN users owner_user ON owner_user.id = r.owner_user_id
            WHERE r.status = 'pending'
              AND (
                owner_user.id IS NULL
                OR COALESCE(owner_user.is_active, true) = false
              )
         ) AS pending_phone_requests_without_active_owner,
         (
           SELECT COUNT(*)::int
             FROM phone_registration_requests r
             LEFT JOIN users requester_user ON requester_user.id = r.requester_user_id
            WHERE r.status = 'pending'
              AND (
                requester_user.id IS NULL
                OR COALESCE(requester_user.is_active, true) = false
              )
         ) AS pending_phone_requests_without_active_requester`,
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      const row = q.rows?.[0] || {};
      for (const field of numericFields) {
        totals[field] += Number(row[field] || 0) || 0;
      }
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    const driftCount =
      totals.unavailable_targets +
      hardDriftFields.reduce((sum, field) => sum + totals[field], 0);
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "auth_identity.integrity_drift",
        "Auth identity data has hard duplicate or stale active references",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "auth_identity.healthy",
      "Auth identity hard references are healthy across database targets",
      totals,
    );
    if (totals.active_users_missing_password_hash > 0) {
      addFinding(
        "info",
        "auth_identity.credentials_recovery_needed",
        "Some active email users have no password hash and must use password setup or recovery flow",
        {
          targets_checked: totals.targets_checked,
          active_users_missing_password_hash:
            totals.active_users_missing_password_hash,
          active_client_users_missing_password_hash:
            totals.active_client_users_missing_password_hash,
          active_staff_users_missing_password_hash:
            totals.active_staff_users_missing_password_hash,
          active_missing_password_users_with_active_session:
            totals.active_missing_password_users_with_active_session,
          active_missing_password_users_with_active_endpoint:
            totals.active_missing_password_users_with_active_endpoint,
          active_missing_password_users_indexed:
            totals.active_missing_password_users_indexed,
          active_missing_password_users_with_phone:
            totals.active_missing_password_users_with_phone,
        },
      );
    }
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "auth_identity.check_failed",
      "Auth identity integrity check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
      },
    );
  }
}

async function checkAuthEmailTokenIntegrity() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    unused_tokens: 0,
    unexpired_unused_tokens: 0,
    expired_unused_tokens: 0,
    unexpired_tokens_missing_user: 0,
    unexpired_tokens_inactive_user: 0,
    unexpired_tokens_invalid_email: 0,
    unexpired_tokens_email_mismatch: 0,
    unexpired_tokens_invalid_hash: 0,
    unexpired_tokens_unknown_kind: 0,
    unexpired_tokens_tenant_mismatch: 0,
    duplicate_unexpired_user_kind_groups: 0,
    duplicate_unexpired_user_kind_tokens: 0,
  };

  const numericFields = [
    "unused_tokens",
    "unexpired_unused_tokens",
    "expired_unused_tokens",
    "unexpired_tokens_missing_user",
    "unexpired_tokens_inactive_user",
    "unexpired_tokens_invalid_email",
    "unexpired_tokens_email_mismatch",
    "unexpired_tokens_invalid_hash",
    "unexpired_tokens_unknown_kind",
    "unexpired_tokens_tenant_mismatch",
    "duplicate_unexpired_user_kind_groups",
    "duplicate_unexpired_user_kind_tokens",
  ];
  const hardDriftFields = [
    "unexpired_tokens_missing_user",
    "unexpired_tokens_inactive_user",
    "unexpired_tokens_invalid_email",
    "unexpired_tokens_email_mismatch",
    "unexpired_tokens_invalid_hash",
    "unexpired_tokens_unknown_kind",
    "unexpired_tokens_tenant_mismatch",
    "duplicate_unexpired_user_kind_groups",
    "duplicate_unexpired_user_kind_tokens",
  ];

  async function readTargetStats() {
    return await db.query(
      `WITH unused_tokens AS (
         SELECT t.id,
                t.user_id,
                t.tenant_id,
                lower(NULLIF(BTRIM(t.email), '')) AS token_email,
                COALESCE(t.kind, '') AS kind,
                COALESCE(t.token_hash, '') AS token_hash,
                t.expires_at,
                u.id AS existing_user_id,
                lower(NULLIF(BTRIM(u.email), '')) AS user_email,
                u.tenant_id AS user_tenant_id,
                COALESCE(u.is_active, true) AS user_is_active
           FROM auth_email_tokens t
           LEFT JOIN users u ON u.id = t.user_id
          WHERE t.used_at IS NULL
       ),
       unexpired_tokens AS (
         SELECT *
           FROM unused_tokens
          WHERE expires_at > now()
       ),
       duplicate_user_kind AS (
         SELECT user_id,
                kind,
                COUNT(*)::int AS token_count
           FROM unexpired_tokens
          WHERE user_id IS NOT NULL
            AND kind IN ('password_reset', 'magic_login')
          GROUP BY user_id, kind
         HAVING COUNT(*) > 1
       )
       SELECT
         (SELECT COUNT(*)::int FROM unused_tokens) AS unused_tokens,
         (SELECT COUNT(*)::int FROM unexpired_tokens) AS unexpired_unused_tokens,
         (
           SELECT COUNT(*)::int
             FROM unused_tokens
            WHERE expires_at <= now()
         ) AS expired_unused_tokens,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE existing_user_id IS NULL
         ) AS unexpired_tokens_missing_user,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE existing_user_id IS NOT NULL
              AND user_is_active = false
         ) AS unexpired_tokens_inactive_user,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE token_email IS NULL
               OR token_email !~ '^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$'
         ) AS unexpired_tokens_invalid_email,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE existing_user_id IS NOT NULL
              AND token_email IS DISTINCT FROM user_email
         ) AS unexpired_tokens_email_mismatch,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE token_hash !~ '^[0-9a-f]{64}$'
         ) AS unexpired_tokens_invalid_hash,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE kind NOT IN ('password_reset', 'magic_login')
         ) AS unexpired_tokens_unknown_kind,
         (
           SELECT COUNT(*)::int
             FROM unexpired_tokens
            WHERE existing_user_id IS NOT NULL
              AND tenant_id IS DISTINCT FROM user_tenant_id
         ) AS unexpired_tokens_tenant_mismatch,
         COALESCE((SELECT COUNT(*)::int FROM duplicate_user_kind), 0)::int AS duplicate_unexpired_user_kind_groups,
         COALESCE((SELECT SUM(token_count)::int FROM duplicate_user_kind), 0)::int AS duplicate_unexpired_user_kind_tokens`,
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      const row = q.rows?.[0] || {};
      for (const field of numericFields) {
        totals[field] += Number(row[field] || 0) || 0;
      }
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    const driftCount =
      totals.unavailable_targets +
      hardDriftFields.reduce((sum, field) => sum + totals[field], 0);
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "auth_email_tokens.integrity_drift",
        "Auth email recovery tokens have stale or inconsistent active references",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "auth_email_tokens.healthy",
      "Auth email recovery tokens are consistent across database targets",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "auth_email_tokens.check_failed",
      "Auth email recovery token integrity check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
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
        const pool = db.createPool(dbUrl, {
          maintenance: true,
          max: 1,
          label: "nightly-audit-tenant",
        });
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

async function checkDatabaseSchemaContract() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    required_columns_checked: 0,
    missing_tables: 0,
    missing_columns: 0,
    targets_with_schema_drift: 0,
    missing_contract_items: [],
  };
  const missingItems = new Set();

  async function readTargetStats(contracts, schemaName) {
    return await db.query(
      `WITH required AS (
         SELECT lower(entry->>'table') AS table_name,
                lower(column_name) AS column_name
           FROM jsonb_array_elements($1::jsonb) AS entry
           CROSS JOIN LATERAL jsonb_array_elements_text(entry->'columns') AS column_name
       ),
       required_tables AS (
         SELECT DISTINCT table_name
           FROM required
       ),
       present_tables AS (
         SELECT lower(table_name) AS table_name
           FROM information_schema.tables
          WHERE table_schema = $2
            AND table_type = 'BASE TABLE'
       ),
       present_columns AS (
         SELECT lower(table_name) AS table_name,
                lower(column_name) AS column_name
           FROM information_schema.columns
          WHERE table_schema = $2
       ),
       table_drift AS (
         SELECT rt.table_name
           FROM required_tables rt
           LEFT JOIN present_tables pt ON pt.table_name = rt.table_name
          WHERE pt.table_name IS NULL
       ),
       column_drift AS (
         SELECT r.table_name,
                r.column_name
           FROM required r
           JOIN present_tables pt ON pt.table_name = r.table_name
           LEFT JOIN present_columns pc
             ON pc.table_name = r.table_name
            AND pc.column_name = r.column_name
          WHERE pc.column_name IS NULL
       ),
       missing_items AS (
         SELECT table_name AS item
           FROM table_drift
         UNION
         SELECT table_name || '.' || column_name AS item
           FROM column_drift
       )
       SELECT
         (SELECT COUNT(*)::int FROM required) AS required_columns_checked,
         (SELECT COUNT(*)::int FROM table_drift) AS missing_tables,
         (SELECT COUNT(*)::int FROM column_drift) AS missing_columns,
         ARRAY(
           SELECT item
             FROM missing_items
            ORDER BY item
            LIMIT 30
         ) AS missing_contract_items`,
      [JSON.stringify(contracts), schemaName],
    );
  }

  async function inspectTarget({ mode, schemaName, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    const contracts =
      mode === "platform"
        ? SHARED_SCHEMA_CONTRACT.concat(PLATFORM_SCHEMA_CONTRACT)
        : SHARED_SCHEMA_CONTRACT;

    try {
      const q = await run(() => readTargetStats(contracts, schemaName));
      const row = q.rows?.[0] || {};
      const missingTables = Number(row.missing_tables || 0) || 0;
      const missingColumns = Number(row.missing_columns || 0) || 0;
      totals.required_columns_checked +=
        Number(row.required_columns_checked || 0) || 0;
      totals.missing_tables += missingTables;
      totals.missing_columns += missingColumns;
      if (missingTables > 0 || missingColumns > 0) {
        totals.targets_with_schema_drift += 1;
      }
      for (const item of row.missing_contract_items || []) {
        if (item) missingItems.add(String(item));
      }
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      schemaName: "public",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
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
          mode,
          schemaName,
          run: (fn) => db.runWithTenantRow(tenant, fn),
        });
        continue;
      }

      await inspectTarget({
        mode,
        schemaName: "public",
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    totals.missing_contract_items = Array.from(missingItems).sort().slice(0, 30);
    const driftCount =
      totals.unavailable_targets +
      totals.missing_tables +
      totals.missing_columns;
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "schema.contract_drift",
        "One or more database targets are missing required runtime tables or columns",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "schema.contract_healthy",
      "Required runtime tables and columns are present across database targets",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "schema.contract_check_failed",
      "Database schema contract check failed",
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

async function checkProductCartIntegrity() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    active_cart_deleted_products: 0,
    active_cart_missing_products: 0,
    active_reservation_deleted_products: 0,
    active_reservation_missing_products: 0,
    active_queue_deleted_products: 0,
    active_queue_missing_products: 0,
    active_publication_batch_deleted_products: 0,
    active_delivery_deleted_products: 0,
    active_delivery_missing_products: 0,
    visible_deleted_product_messages: 0,
    visible_missing_product_messages: 0,
    invalid_product_amounts: 0,
  };

  const numericFields = [
    "active_cart_deleted_products",
    "active_cart_missing_products",
    "active_reservation_deleted_products",
    "active_reservation_missing_products",
    "active_queue_deleted_products",
    "active_queue_missing_products",
    "active_publication_batch_deleted_products",
    "active_delivery_deleted_products",
    "active_delivery_missing_products",
    "visible_deleted_product_messages",
    "visible_missing_product_messages",
    "invalid_product_amounts",
  ];

  async function readTargetStats() {
    return await db.query(
      `WITH deleted_products AS (
         SELECT id
         FROM products
         WHERE status = 'deleted'
            OR deleted_at IS NOT NULL
       )
       SELECT
         (
           SELECT COUNT(*)::int
           FROM cart_items ci
           JOIN deleted_products dp ON dp.id = ci.product_id
           WHERE ci.status NOT IN ('cancelled', 'delivered')
         ) AS active_cart_deleted_products,
         (
           SELECT COUNT(*)::int
           FROM cart_items ci
           LEFT JOIN products p ON p.id = ci.product_id
           WHERE p.id IS NULL
             AND ci.status NOT IN ('cancelled', 'delivered')
         ) AS active_cart_missing_products,
         (
           SELECT COUNT(*)::int
           FROM reservations r
           JOIN deleted_products dp ON dp.id = r.product_id
           WHERE COALESCE(r.is_fulfilled, false) = false
         ) AS active_reservation_deleted_products,
         (
           SELECT COUNT(*)::int
           FROM reservations r
           LEFT JOIN products p ON p.id = r.product_id
           WHERE p.id IS NULL
             AND COALESCE(r.is_fulfilled, false) = false
         ) AS active_reservation_missing_products,
         (
           SELECT COUNT(*)::int
           FROM product_publication_queue q
           JOIN deleted_products dp ON dp.id = q.product_id
           WHERE COALESCE(q.status, 'pending') <> 'deleted'
             AND (
               q.status = 'pending'
               OR COALESCE(q.publish_status, 'pending') IN ('pending', 'queued', 'publishing', 'failed')
             )
         ) AS active_queue_deleted_products,
         (
           SELECT COUNT(*)::int
           FROM product_publication_queue q
           LEFT JOIN products p ON p.id = q.product_id
           WHERE p.id IS NULL
             AND COALESCE(q.status, 'pending') <> 'deleted'
             AND (
               q.status = 'pending'
               OR COALESCE(q.publish_status, 'pending') IN ('pending', 'queued', 'publishing', 'failed')
             )
         ) AS active_queue_missing_products,
         (
           SELECT COUNT(*)::int
           FROM channel_publication_batches b
           JOIN deleted_products dp ON dp.id = b.current_product_id
           WHERE b.status IN ('queued', 'running')
         ) AS active_publication_batch_deleted_products,
         (
           SELECT COUNT(*)::int
           FROM delivery_batch_items i
           JOIN delivery_batches b ON b.id = i.batch_id
           JOIN deleted_products dp ON dp.id = i.product_id
           WHERE b.status IN ('calling', 'couriers_assigned', 'handed_off')
             AND COALESCE(i.assembly_status, 'pending') <> 'removed'
         ) AS active_delivery_deleted_products,
         (
           SELECT COUNT(*)::int
           FROM delivery_batch_items i
           JOIN delivery_batches b ON b.id = i.batch_id
           LEFT JOIN products p ON p.id = i.product_id
           WHERE p.id IS NULL
             AND b.status IN ('calling', 'couriers_assigned', 'handed_off')
             AND COALESCE(i.assembly_status, 'pending') <> 'removed'
         ) AS active_delivery_missing_products,
         (
           SELECT COUNT(*)::int
           FROM messages m
           JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
           WHERE COALESCE(m.meta->>'kind', '') IN ('catalog_product', 'reserved_order_item')
             AND (p.status = 'deleted' OR p.deleted_at IS NOT NULL)
             AND lower(COALESCE(m.meta->>'hidden_for_all', 'false')) NOT IN ('true', '1', 'yes', 'on')
             AND lower(COALESCE(m.meta->>'client_cancelled', 'false')) NOT IN ('true', '1', 'yes', 'on')
         ) AS visible_deleted_product_messages,
         (
           SELECT COUNT(*)::int
           FROM messages m
           WHERE COALESCE(m.meta->>'kind', '') IN ('catalog_product', 'reserved_order_item')
             AND NULLIF(BTRIM(COALESCE(m.meta->>'product_id', '')), '') IS NOT NULL
             AND lower(COALESCE(m.meta->>'hidden_for_all', 'false')) NOT IN ('true', '1', 'yes', 'on')
             AND lower(COALESCE(m.meta->>'client_cancelled', 'false')) NOT IN ('true', '1', 'yes', 'on')
             AND NOT EXISTS (
               SELECT 1
               FROM products p
               WHERE p.id::text = COALESCE(m.meta->>'product_id', '')
             )
         ) AS visible_missing_product_messages,
         (
           SELECT COUNT(*)::int
           FROM products p
           WHERE COALESCE(p.status, '') <> 'deleted'
             AND (
               COALESCE(p.quantity, 0) < 0
               OR COALESCE(p.price, 0) < 0
             )
         ) AS invalid_product_amounts`,
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      const row = q.rows?.[0] || {};
      for (const field of numericFields) {
        totals[field] += Number(row[field] || 0) || 0;
      }
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    const driftCount =
      totals.unavailable_targets +
      numericFields.reduce((sum, field) => sum + totals[field], 0);
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "products.integrity_drift",
        "Product, cart, reservation, delivery or channel state has inconsistent active references",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "products.integrity_healthy",
      "Product, cart, reservation, delivery and channel state are consistent across database targets",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "products.integrity_check_failed",
      "Product/cart integrity check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
      },
    );
  }
}

async function checkPublicationPipelineHealth() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    due_pending_queue_items: 0,
    failed_queue_items: 0,
    queued_queue_items_without_active_batch: 0,
    publishing_queue_items_without_active_batch: 0,
    stale_queued_queue_items: 0,
    stale_publishing_queue_items: 0,
    due_active_batches: 0,
    stale_active_batches: 0,
    active_batches_without_active_items: 0,
    active_batch_counter_drift: 0,
    oldest_stuck_queue_created_at: null,
    oldest_stuck_batch_updated_at: null,
  };

  const numericFields = [
    "due_pending_queue_items",
    "failed_queue_items",
    "queued_queue_items_without_active_batch",
    "publishing_queue_items_without_active_batch",
    "stale_queued_queue_items",
    "stale_publishing_queue_items",
    "due_active_batches",
    "stale_active_batches",
    "active_batches_without_active_items",
    "active_batch_counter_drift",
  ];
  const blockingFields = [
    "queued_queue_items_without_active_batch",
    "publishing_queue_items_without_active_batch",
    "stale_queued_queue_items",
    "stale_publishing_queue_items",
    "stale_active_batches",
    "active_batches_without_active_items",
    "active_batch_counter_drift",
  ];

  function minDateIso(currentValue, nextValue) {
    if (!nextValue) return currentValue || null;
    const nextDate = new Date(nextValue);
    if (!Number.isFinite(nextDate.getTime())) return currentValue || null;
    if (!currentValue) return nextDate.toISOString();
    const currentDate = new Date(currentValue);
    if (!Number.isFinite(currentDate.getTime())) return nextDate.toISOString();
    return nextDate < currentDate ? nextDate.toISOString() : currentValue;
  }

  async function readTargetStats() {
    return await db.query(
      `WITH active_queue AS (
         SELECT q.id,
                q.publish_batch_id,
                COALESCE(q.publish_status, 'pending') AS publish_status,
                q.publish_started_at,
                q.publish_finished_at,
                q.created_at AS queue_created_at,
                b.status AS batch_status,
                b.next_publish_at AS batch_next_publish_at,
                b.updated_at AS batch_updated_at,
                b.created_at AS batch_created_at
           FROM product_publication_queue q
           LEFT JOIN channel_publication_batches b ON b.id = q.publish_batch_id
          WHERE q.status = 'pending'
            AND COALESCE(q.is_sent, false) = false
            AND COALESCE(q.publish_status, 'pending') IN ('pending', 'queued', 'publishing', 'failed')
       ),
       active_batches AS (
         SELECT b.id,
                b.status,
                b.next_publish_at,
                b.updated_at,
                b.created_at,
                b.total_count,
                b.published_count,
                b.failed_count
           FROM channel_publication_batches b
          WHERE b.status IN ('queued', 'running')
       ),
       active_batch_queue_counts AS (
         SELECT b.id,
                COUNT(q.id)::int AS queue_count,
                COUNT(q.id) FILTER (
                  WHERE q.status = 'pending'
                    AND COALESCE(q.is_sent, false) = false
                    AND COALESCE(q.publish_status, 'pending') IN ('queued', 'publishing')
                )::int AS active_queue_count
           FROM active_batches b
           LEFT JOIN product_publication_queue q ON q.publish_batch_id = b.id
          GROUP BY b.id
       ),
       stuck_queue AS (
         SELECT queue_created_at
           FROM active_queue
          WHERE (
              publish_status = 'queued'
              AND (batch_status IS NULL OR batch_status NOT IN ('queued', 'running'))
            )
             OR (
              publish_status = 'publishing'
              AND (batch_status IS NULL OR batch_status NOT IN ('queued', 'running'))
            )
             OR (
              publish_status = 'queued'
              AND batch_status IN ('queued', 'running')
              AND COALESCE(batch_next_publish_at, batch_updated_at, batch_created_at, queue_created_at)
                    <= now() - ($1::text)::interval
            )
             OR (
              publish_status = 'publishing'
              AND COALESCE(publish_started_at, queue_created_at)
                    <= now() - ($2::text)::interval
            )
       ),
       stuck_batches AS (
         SELECT b.updated_at
           FROM active_batches b
           LEFT JOIN active_batch_queue_counts c ON c.id = b.id
          WHERE COALESCE(b.next_publish_at, b.updated_at, b.created_at)
                  <= now() - ($1::text)::interval
             OR COALESCE(c.active_queue_count, 0) = 0
             OR COALESCE(b.total_count, 0) < 1
             OR COALESCE(b.total_count, 0) < COALESCE(b.published_count, 0) + COALESCE(b.failed_count, 0)
             OR COALESCE(b.total_count, 0) <> COALESCE(c.queue_count, 0)
       )
       SELECT
         (
           SELECT COUNT(*)::int
             FROM active_queue
            WHERE publish_status = 'pending'
              AND queue_created_at <= now() - interval '24 hours'
         ) AS due_pending_queue_items,
         (
           SELECT COUNT(*)::int
             FROM active_queue
            WHERE publish_status = 'failed'
         ) AS failed_queue_items,
         (
           SELECT COUNT(*)::int
             FROM active_queue
            WHERE publish_status = 'queued'
              AND (batch_status IS NULL OR batch_status NOT IN ('queued', 'running'))
         ) AS queued_queue_items_without_active_batch,
         (
           SELECT COUNT(*)::int
             FROM active_queue
            WHERE publish_status = 'publishing'
              AND (batch_status IS NULL OR batch_status NOT IN ('queued', 'running'))
         ) AS publishing_queue_items_without_active_batch,
         (
           SELECT COUNT(*)::int
             FROM active_queue
            WHERE publish_status = 'queued'
              AND batch_status IN ('queued', 'running')
              AND COALESCE(batch_next_publish_at, batch_updated_at, batch_created_at, queue_created_at)
                    <= now() - ($1::text)::interval
         ) AS stale_queued_queue_items,
         (
           SELECT COUNT(*)::int
             FROM active_queue
            WHERE publish_status = 'publishing'
              AND COALESCE(publish_started_at, queue_created_at)
                    <= now() - ($2::text)::interval
         ) AS stale_publishing_queue_items,
         (
           SELECT COUNT(*)::int
             FROM active_batches
            WHERE COALESCE(next_publish_at, updated_at, created_at) <= now()
         ) AS due_active_batches,
         (
           SELECT COUNT(*)::int
             FROM active_batches
            WHERE COALESCE(next_publish_at, updated_at, created_at)
                    <= now() - ($1::text)::interval
         ) AS stale_active_batches,
         (
           SELECT COUNT(*)::int
             FROM active_batch_queue_counts
            WHERE active_queue_count = 0
         ) AS active_batches_without_active_items,
         (
           SELECT COUNT(*)::int
             FROM active_batches b
             LEFT JOIN active_batch_queue_counts c ON c.id = b.id
            WHERE COALESCE(b.total_count, 0) < 1
               OR COALESCE(b.total_count, 0) < COALESCE(b.published_count, 0) + COALESCE(b.failed_count, 0)
               OR COALESCE(b.total_count, 0) <> COALESCE(c.queue_count, 0)
         ) AS active_batch_counter_drift,
         (SELECT MIN(queue_created_at) FROM stuck_queue) AS oldest_stuck_queue_created_at,
         (SELECT MIN(updated_at) FROM stuck_batches) AS oldest_stuck_batch_updated_at`,
      ["15 minutes", "5 minutes"],
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      const row = q.rows?.[0] || {};
      for (const field of numericFields) {
        totals[field] += Number(row[field] || 0) || 0;
      }
      totals.oldest_stuck_queue_created_at = minDateIso(
        totals.oldest_stuck_queue_created_at,
        row.oldest_stuck_queue_created_at,
      );
      totals.oldest_stuck_batch_updated_at = minDateIso(
        totals.oldest_stuck_batch_updated_at,
        row.oldest_stuck_batch_updated_at,
      );
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    const driftCount =
      totals.unavailable_targets +
      blockingFields.reduce((sum, field) => sum + totals[field], 0);
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "publication.pipeline_stalled",
        "Product publication pipeline has stuck queue items or active batches across database targets",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "publication.pipeline_healthy",
      "Product publication pipeline has no stuck queue items or active batches across database targets",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "publication.pipeline_check_failed",
      "Product publication pipeline health check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
      },
    );
  }
}

async function checkChatRecencyIntegrity() {
  const totals = {
    targets_checked: 0,
    platform_targets: 0,
    isolated_targets: 0,
    schema_isolated_targets: 0,
    unavailable_targets: 0,
    stale_chat_count: 0,
    stale_channel_count: 0,
    stale_main_channel_count: 0,
    stale_system_channel_count: 0,
    newest_message_at: null,
    oldest_stale_chat_updated_at: null,
  };

  const numericFields = [
    "stale_chat_count",
    "stale_channel_count",
    "stale_main_channel_count",
    "stale_system_channel_count",
  ];

  function maxDateIso(currentValue, nextValue) {
    if (!nextValue) return currentValue || null;
    const nextDate = new Date(nextValue);
    if (!Number.isFinite(nextDate.getTime())) return currentValue || null;
    if (!currentValue) return nextDate.toISOString();
    const currentDate = new Date(currentValue);
    if (!Number.isFinite(currentDate.getTime())) return nextDate.toISOString();
    return nextDate > currentDate ? nextDate.toISOString() : currentValue;
  }

  function minDateIso(currentValue, nextValue) {
    if (!nextValue) return currentValue || null;
    const nextDate = new Date(nextValue);
    if (!Number.isFinite(nextDate.getTime())) return currentValue || null;
    if (!currentValue) return nextDate.toISOString();
    const currentDate = new Date(currentValue);
    if (!Number.isFinite(currentDate.getTime())) return nextDate.toISOString();
    return nextDate < currentDate ? nextDate.toISOString() : currentValue;
  }

  async function readTargetStats() {
    return await db.query(
      `WITH latest_visible_messages AS (
         SELECT c.id AS chat_id,
                lower(COALESCE(c.type, '')) AS chat_type,
                lower(COALESCE(c.settings->>'system_key', c.settings->>'kind', '')) AS system_key,
                c.updated_at AS chat_updated_at,
                latest.created_at AS latest_message_at
           FROM chats c
           JOIN LATERAL (
             SELECT m.created_at
               FROM messages m
              WHERE m.chat_id = c.id
                AND lower(COALESCE(m.meta->>'hidden_for_all', 'false')) NOT IN ('true', '1', 'yes', 'on')
              ORDER BY m.created_at DESC, m.id DESC
              LIMIT 1
           ) latest ON true
       ),
       stale_chats AS (
         SELECT *
           FROM latest_visible_messages
          WHERE chat_updated_at IS NULL
             OR latest_message_at > chat_updated_at + interval '2 seconds'
       )
       SELECT
         COUNT(*)::int AS stale_chat_count,
         COUNT(*) FILTER (WHERE chat_type = 'channel')::int AS stale_channel_count,
         COUNT(*) FILTER (WHERE system_key = 'main_channel')::int AS stale_main_channel_count,
         COUNT(*) FILTER (WHERE system_key <> '')::int AS stale_system_channel_count,
         MAX(latest_message_at) AS newest_message_at,
         MIN(chat_updated_at) AS oldest_stale_chat_updated_at
       FROM stale_chats`,
    );
  }

  async function inspectTarget({ mode, run }) {
    totals.targets_checked += 1;
    if (mode === "platform") totals.platform_targets += 1;
    if (mode === "isolated") totals.isolated_targets += 1;
    if (mode === "schema_isolated") totals.schema_isolated_targets += 1;

    try {
      const q = await run(readTargetStats);
      const row = q.rows?.[0] || {};
      for (const field of numericFields) {
        totals[field] += Number(row[field] || 0) || 0;
      }
      totals.newest_message_at = maxDateIso(
        totals.newest_message_at,
        row.newest_message_at,
      );
      totals.oldest_stale_chat_updated_at = minDateIso(
        totals.oldest_stale_chat_updated_at,
        row.oldest_stale_chat_updated_at,
      );
    } catch (err) {
      const code = String(err?.code || "").trim();
      if (code === "42P01" || code === "42703" || code === "3F000") {
        totals.unavailable_targets += 1;
        return;
      }
      throw err;
    }
  }

  try {
    await inspectTarget({
      mode: "platform",
      run: (fn) => db.runWithPlatform(fn),
    });

    const tenantsQ = await db.platformQuery(
      `SELECT id,
              db_mode,
              db_url,
              db_schema
       FROM tenants
       WHERE COALESCE(is_deleted, false) = false
         AND db_mode IN ('isolated', 'schema_isolated')
       ORDER BY created_at`,
    );

    for (const tenant of tenantsQ.rows || []) {
      const mode = String(tenant?.db_mode || "").toLowerCase().trim();
      if (mode === "isolated" && !String(tenant?.db_url || "").trim()) {
        totals.targets_checked += 1;
        totals.isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }
      if (
        mode === "schema_isolated" &&
        !String(tenant?.db_schema || "").trim()
      ) {
        totals.targets_checked += 1;
        totals.schema_isolated_targets += 1;
        totals.unavailable_targets += 1;
        continue;
      }

      await inspectTarget({
        mode,
        run: (fn) => db.runWithTenantRow(tenant, fn),
      });
    }

    const driftCount =
      totals.unavailable_targets +
      numericFields.reduce((sum, field) => sum + totals[field], 0);
    if (driftCount > 0) {
      addFinding(
        IS_PRODUCTION ? "critical" : "warn",
        "chats.recency_drift",
        "One or more chats have an older updated_at than their latest visible message",
        totals,
      );
      return;
    }

    addFinding(
      "info",
      "chats.recency_healthy",
      "Chat recency is consistent with latest visible messages across database targets",
      totals,
    );
  } catch (err) {
    addFinding(
      IS_PRODUCTION ? "critical" : "warn",
      "chats.recency_check_failed",
      "Chat recency integrity check failed",
      {
        error: String(err?.message || err).slice(0, 300),
        targets_checked: totals.targets_checked,
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
  checkUploadRecoveryHealth();
  await checkMonitoringBacklog();
  await checkNotificationQueueHealth();
  await checkTenantFeaturePolicy();
  await checkAuthSessionHealth();
  await checkAuthIdentityIntegrity();
  await checkAuthEmailTokenIntegrity();
  await checkTenantMigrationDrift();
  await checkDatabaseSchemaContract();
  await checkTenantUserIndexDrift();
  await checkProductCartIntegrity();
  await checkPublicationPipelineHealth();
  await checkChatRecencyIntegrity();
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
