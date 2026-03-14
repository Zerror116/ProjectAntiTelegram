const DEFAULT_KEY_VERSION = "v1";

function normalizeKeyVersion(raw, fallback = DEFAULT_KEY_VERSION) {
  const normalized = String(raw || "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9._-]/g, "");
  if (normalized) return normalized;
  if (fallback === null || fallback === undefined) return "";
  const fallbackNormalized = String(fallback || "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9._-]/g, "");
  if (!fallbackNormalized && String(fallback) === "") return "";
  return fallbackNormalized || DEFAULT_KEY_VERSION;
}

function parseKeyringJson(raw) {
  const source = String(raw || "").trim();
  if (!source) return {};
  try {
    const parsed = JSON.parse(source);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {};
    }
    return parsed;
  } catch (_) {
    return {};
  }
}

function parseKeyringString(raw) {
  const source = String(raw || "").trim();
  if (!source) return {};
  const out = {};
  for (const chunk of source.split(/[,\n;]/)) {
    const pair = String(chunk || "").trim();
    if (!pair) continue;
    const sep = pair.indexOf(":");
    if (sep <= 0) continue;
    const version = normalizeKeyVersion(pair.slice(0, sep));
    const secret = pair.slice(sep + 1).trim();
    if (!secret) continue;
    out[version] = secret;
  }
  return out;
}

function buildSecretKeyring({
  purpose = "secret",
  currentVersion = DEFAULT_KEY_VERSION,
  singleSecret = "",
  keyringString = "",
  keyringJson = "",
  requiredInProduction = false,
  devFallbackSecret = "",
} = {}) {
  const source = new Map();
  const normalizedCurrentVersion = normalizeKeyVersion(
    currentVersion,
    DEFAULT_KEY_VERSION,
  );

  const addSecret = (versionRaw, secretRaw) => {
    const version = normalizeKeyVersion(versionRaw, normalizedCurrentVersion);
    const secret = String(secretRaw || "").trim();
    if (!secret) return;
    source.set(version, secret);
  };

  const parsedJson = parseKeyringJson(keyringJson);
  for (const [version, secret] of Object.entries(parsedJson)) {
    addSecret(version, secret);
  }

  const parsedString = parseKeyringString(keyringString);
  for (const [version, secret] of Object.entries(parsedString)) {
    addSecret(version, secret);
  }

  addSecret(normalizedCurrentVersion, singleSecret);

  let usedDevFallback = false;
  if (source.size === 0) {
    const fallbackSecret = String(
      devFallbackSecret || `dev-${purpose}-secret`,
    ).trim();
    if (fallbackSecret) {
      usedDevFallback = true;
      source.set(normalizedCurrentVersion, fallbackSecret);
    }
  }

  if (source.size === 0 && requiredInProduction) {
    throw new Error(`No secret configured for ${purpose}`);
  }

  if (
    requiredInProduction &&
    process.env.NODE_ENV === "production" &&
    usedDevFallback
  ) {
    throw new Error(
      `${purpose} secret is not configured in production (dev fallback is forbidden)`,
    );
  }

  const existingCurrentSecret = source.get(normalizedCurrentVersion);
  const firstSecret = source.values().next().value || "";
  const resolvedCurrentSecret = existingCurrentSecret || firstSecret;
  if (resolvedCurrentSecret && !existingCurrentSecret) {
    source.set(normalizedCurrentVersion, resolvedCurrentSecret);
  }

  const entries = Array.from(source.entries()).map(([version, secret]) => ({
    version,
    secret,
  }));
  const byVersion = new Map(entries.map((entry) => [entry.version, entry.secret]));

  return {
    purpose,
    currentVersion: normalizedCurrentVersion,
    currentSecret: resolvedCurrentSecret || "",
    entries,
    byVersion,
    usedDevFallback,
  };
}

function resolveSecretCandidates(keyring, preferredVersion = "") {
  const ring = keyring || {};
  const byVersion =
    ring.byVersion instanceof Map ? ring.byVersion : new Map(ring.entries || []);
  const visited = new Set();
  const ordered = [];

  const pushByVersion = (versionRaw) => {
    const raw = String(versionRaw || "").trim();
    if (!raw) return;
    const version = normalizeKeyVersion(raw, "");
    if (!version) return;
    const secret = byVersion.get(version);
    if (!secret) return;
    const dedupeKey = `${version}:${secret}`;
    if (visited.has(dedupeKey)) return;
    visited.add(dedupeKey);
    ordered.push({ version, secret });
  };

  pushByVersion(preferredVersion);
  pushByVersion(ring.currentVersion);

  for (const [version, secret] of byVersion.entries()) {
    const dedupeKey = `${version}:${secret}`;
    if (visited.has(dedupeKey)) continue;
    visited.add(dedupeKey);
    ordered.push({ version, secret });
  }

  return ordered;
}

function describeKeyring(keyring) {
  const entries = Array.isArray(keyring?.entries) ? keyring.entries : [];
  return {
    currentVersion: normalizeKeyVersion(keyring?.currentVersion),
    versions: entries.map((entry) => entry.version),
    keyCount: entries.length,
    usesDevFallback: keyring?.usedDevFallback === true,
  };
}

module.exports = {
  DEFAULT_KEY_VERSION,
  normalizeKeyVersion,
  parseKeyringJson,
  parseKeyringString,
  buildSecretKeyring,
  resolveSecretCandidates,
  describeKeyring,
};
