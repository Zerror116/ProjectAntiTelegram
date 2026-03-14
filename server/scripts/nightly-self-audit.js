#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const db = require("../src/db");
const {
  buildSecretKeyring,
  describeKeyring,
} = require("../src/utils/secretKeyring");
const { getJwtKeyringMeta } = require("../src/utils/jwt");

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

function checkSecretKeyrings() {
  const rings = [
    {
      name: "jwt",
      meta: getJwtKeyringMeta(),
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
        IS_PRODUCTION ? "critical" : "warn",
        `secret.${ring.name}.dev_fallback`,
        `Keyring "${ring.name}" uses a development fallback key`,
      );
    }
    if (keyCount < 2) {
      addFinding(
        "warn",
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
    addFinding("warn", "transport.https.disabled_dev", "HTTPS enforcement is disabled");
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
  } finally {
    try {
      await db.platformPool.end();
    } catch (_) {
      // ignore pool close errors
    }
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

async function main() {
  checkSecretKeyrings();
  checkTransportHardening();
  checkDependencyAudit();
  await checkMonitoringBacklog();

  const outputPath = path.resolve(
    process.cwd(),
    process.env.AUDIT_OUTPUT_PATH || "audit/nightly-self-audit.md",
  );
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, buildMarkdownReport(), "utf8");
  console.log(`nightly self-audit report: ${outputPath}`);

  const hasCritical = findings.some((f) => f.level === "critical");
  if (hasCritical) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error("nightly-self-audit failed", err);
  process.exit(1);
});
