const crypto = require("crypto");
const path = require("path");
const {
  normalizeKeyVersion,
  buildSecretKeyring,
  resolveSecretCandidates,
} = require("./secretKeyring");

const SIGNED_UPLOAD_KINDS = new Set(["products", "channels", "users", "claims"]);
const SIGNED_UPLOAD_KEYRING = buildSecretKeyring({
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
    process.env.UPLOADS_TOKEN_KEYRING || process.env.UPLOADS_TOKEN_SECRETS || "",
  keyringJson:
    process.env.UPLOADS_TOKEN_KEYS_JSON || process.env.UPLOADS_SECRETS_JSON || "",
  requiredInProduction: true,
  devFallbackSecret: "dev-uploads-secret",
});
const SIGNED_UPLOAD_TOKEN_TTL_SECONDS = Math.max(
  30,
  Number(process.env.UPLOADS_TOKEN_TTL_SECONDS || 15 * 60),
);

function signUploadAccess(canonicalPath, expUnixSeconds, secret) {
  return crypto
    .createHmac("sha256", String(secret || SIGNED_UPLOAD_KEYRING.currentSecret || ""))
    .update(`${canonicalPath}:${expUnixSeconds}`)
    .digest("hex");
}

function secureEqualHex(a, b) {
  const left = Buffer.from(String(a || ""), "utf8");
  const right = Buffer.from(String(b || ""), "utf8");
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

function normalizeUploadRef(rawValue) {
  const raw = String(rawValue || "").trim();
  if (!raw) return null;

  const match = raw.match(
    /^(https?:\/\/[^/?#\s]+)?\/uploads\/(products|channels|users|claims)\/([^?#\s]+)(?:\?[^#\s]*)?(?:#.*)?$/i,
  );
  if (!match) return null;

  const origin = String(match[1] || "").trim();
  const kind = String(match[2] || "")
    .toLowerCase()
    .trim();
  if (!SIGNED_UPLOAD_KINDS.has(kind)) return null;

  const decoded = decodeURIComponent(String(match[3] || "").trim());
  const filename = path.basename(decoded);
  if (
    filename !== decoded ||
    !/^[A-Za-z0-9._-]+$/.test(filename) ||
    filename.startsWith(".")
  ) {
    return null;
  }

  return {
    origin,
    kind,
    filename,
    canonicalPath: `/uploads/${kind}/${filename}`,
  };
}

function resolveOrigin(req, baseUrl) {
  const normalizedBase = String(baseUrl || "").trim();
  if (normalizedBase) {
    try {
      return new URL(normalizedBase).origin;
    } catch (_) {}
  }
  if (!req) return "";
  try {
    return `${req.protocol}://${req.get("host")}`;
  } catch (_) {
    return "";
  }
}

function buildSignedUploadUrl(rawValue, { req, baseUrl } = {}) {
  const ref = normalizeUploadRef(rawValue);
  if (!ref) return rawValue;
  const exp = Math.floor(Date.now() / 1000) + SIGNED_UPLOAD_TOKEN_TTL_SECONDS;
  const signingCandidate =
    resolveSecretCandidates(
      SIGNED_UPLOAD_KEYRING,
      SIGNED_UPLOAD_KEYRING.currentVersion,
    )[0] || null;
  const keyVersion = signingCandidate?.version || SIGNED_UPLOAD_KEYRING.currentVersion;
  const sig = signUploadAccess(
    ref.canonicalPath,
    exp,
    signingCandidate?.secret || SIGNED_UPLOAD_KEYRING.currentSecret,
  );
  // Prefer runtime/public origin over origin captured in stored URL.
  // This prevents legacy absolute links (for example, sslip.io/dev hosts)
  // from leaking to clients when service is now served via production domain.
  const origin = resolveOrigin(req, baseUrl) || ref.origin;
  if (!origin) {
    return `${ref.canonicalPath}?exp=${exp}&kid=${encodeURIComponent(keyVersion)}&sig=${sig}`;
  }
  return `${origin}${ref.canonicalPath}?exp=${exp}&kid=${encodeURIComponent(keyVersion)}&sig=${sig}`;
}

function isPlainObject(value) {
  if (value == null || typeof value !== "object") return false;
  if (Array.isArray(value)) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

function rewriteSignedUploadsInPayload(payload, context = {}) {
  const req =
    context && typeof context === "object" && !Array.isArray(context)
      ? context.req || null
      : null;
  const baseUrl =
    context && typeof context === "object" && !Array.isArray(context)
      ? context.baseUrl || ""
      : "";
  const seen = new WeakSet();

  const walk = (value) => {
    if (value == null) return value;
    if (typeof value === "string") {
      return buildSignedUploadUrl(value, { req, baseUrl });
    }
    if (typeof value !== "object") return value;
    if (Buffer.isBuffer(value)) return value;
    if (value instanceof Date) return value;
    if (!Array.isArray(value) && !isPlainObject(value)) return value;

    if (seen.has(value)) return value;
    seen.add(value);

    if (Array.isArray(value)) {
      return value.map(walk);
    }

    const out = {};
    for (const [key, entry] of Object.entries(value)) {
      out[key] = walk(entry);
    }
    return out;
  };

  return walk(payload);
}

function verifySignedUploadRequest(kind, filename, expRaw, sigRaw, kidRaw) {
  const safeKind = String(kind || "")
    .toLowerCase()
    .trim();
  if (!SIGNED_UPLOAD_KINDS.has(safeKind)) {
    return { ok: false, error: "Unsupported upload kind" };
  }

  const safeName = path.basename(String(filename || "").trim());
  if (
    !safeName ||
    safeName !== String(filename || "").trim() ||
    !/^[A-Za-z0-9._-]+$/.test(safeName) ||
    safeName.startsWith(".")
  ) {
    return { ok: false, error: "Invalid filename" };
  }

  const exp = Number(expRaw);
  if (!Number.isFinite(exp)) {
    return { ok: false, error: "Invalid exp" };
  }
  const now = Math.floor(Date.now() / 1000);
  if (exp < now) {
    return { ok: false, error: "Expired token" };
  }
  // Small hard ceiling to reduce replay window abuse for forged large exp.
  if (exp > now + 24 * 60 * 60) {
    return { ok: false, error: "exp too far in future" };
  }

  const sig = String(sigRaw || "").trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sig)) {
    return { ok: false, error: "Invalid sig" };
  }

  const canonicalPath = `/uploads/${safeKind}/${safeName}`;
  const requestedKeyVersion = normalizeKeyVersion(kidRaw, "");
  const candidates = resolveSecretCandidates(
    SIGNED_UPLOAD_KEYRING,
    requestedKeyVersion,
  );
  let matchedVersion = "";
  let signatureValid = false;
  for (const candidate of candidates) {
    const expected = signUploadAccess(canonicalPath, exp, candidate.secret);
    if (!secureEqualHex(expected, sig)) continue;
    signatureValid = true;
    matchedVersion = candidate.version;
    break;
  }
  if (!signatureValid) {
    return { ok: false, error: "Signature mismatch" };
  }

  return {
    ok: true,
    canonicalPath,
    kind: safeKind,
    filename: safeName,
    keyVersion: matchedVersion || requestedKeyVersion || null,
  };
}

function signedUploadGuard(kind) {
  return (req, res, next) => {
    const rel = String(req.path || "").replace(/^\/+/, "");
    const filename = decodeURIComponent(rel.split("/")[0] || "");
    const checked = verifySignedUploadRequest(
      kind,
      filename,
      req.query?.exp,
      req.query?.sig,
      req.query?.kid || req.query?.kv,
    );
    if (!checked.ok) {
      return res.status(403).json({ ok: false, error: "Доступ к файлу запрещен" });
    }
    return next();
  };
}

module.exports = {
  SIGNED_UPLOAD_KINDS,
  buildSignedUploadUrl,
  rewriteSignedUploadsInPayload,
  signedUploadGuard,
  verifySignedUploadRequest,
};
