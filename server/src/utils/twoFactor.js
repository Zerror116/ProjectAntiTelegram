const { authenticator } = require("otplib");
const crypto = require("crypto");

const {
  encryptMessageText,
  decryptMessageText,
} = require("./messageCrypto");

const TWO_FACTOR_ISSUER = String(
  process.env.TWO_FACTOR_ISSUER || "ProjectAntiTelegram",
).trim();

authenticator.options = {
  step: 30,
  window: 1,
};

const BACKUP_CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const BACKUP_CODE_SIZE = 8;
const DEFAULT_BACKUP_CODE_COUNT = 10;

function normalizeRole(raw) {
  return String(raw || "")
    .toLowerCase()
    .trim();
}

function isTwoFactorEligibleRole(user) {
  const role = normalizeRole(user?.role);
  const baseRole = normalizeRole(user?.base_role || role);
  return (
    role === "admin" ||
    role === "tenant" ||
    role === "creator" ||
    baseRole === "admin" ||
    baseRole === "tenant" ||
    baseRole === "creator"
  );
}

function normalizeTotpCode(raw) {
  return String(raw || "").replace(/\s+/g, "").trim();
}

function generateTwoFactorSetup({ accountName }) {
  const safeAccount = String(accountName || "").trim() || "user";
  const secret = authenticator.generateSecret();
  return {
    secret,
    issuer: TWO_FACTOR_ISSUER,
    otpauthUrl: authenticator.keyuri(safeAccount, TWO_FACTOR_ISSUER, secret),
  };
}

function verifyTwoFactorCode(secret, token) {
  const safeSecret = String(secret || "").trim();
  const normalizedToken = normalizeTotpCode(token);
  if (!safeSecret || !normalizedToken) return false;
  try {
    return authenticator.check(normalizedToken, safeSecret);
  } catch (_) {
    return false;
  }
}

function encryptTwoFactorSecret(secret) {
  return encryptMessageText(String(secret || "").trim(), { force: true });
}

function decryptTwoFactorSecret(secretCipher) {
  return decryptMessageText(secretCipher);
}

function normalizeBackupCode(raw) {
  return String(raw || "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .trim();
}

function formatBackupCode(raw) {
  const normalized = normalizeBackupCode(raw);
  if (normalized.length <= 4) return normalized;
  return `${normalized.slice(0, 4)}-${normalized.slice(4)}`;
}

function createBackupCodeRaw(size = BACKUP_CODE_SIZE) {
  let output = "";
  const safeSize = Math.max(6, Math.min(Number(size) || BACKUP_CODE_SIZE, 16));
  while (output.length < safeSize) {
    const bytes = crypto.randomBytes(safeSize);
    for (const byte of bytes) {
      output += BACKUP_CODE_ALPHABET[byte % BACKUP_CODE_ALPHABET.length];
      if (output.length >= safeSize) break;
    }
  }
  return output.slice(0, safeSize);
}

function hashBackupCode(raw) {
  const normalized = normalizeBackupCode(raw);
  if (!normalized) return "";
  return crypto.createHash("sha256").update(normalized, "utf8").digest("hex");
}

function generateBackupCodes({
  count = DEFAULT_BACKUP_CODE_COUNT,
  size = BACKUP_CODE_SIZE,
} = {}) {
  const safeCount = Math.max(1, Math.min(Number(count) || DEFAULT_BACKUP_CODE_COUNT, 30));
  const plain = [];
  const hashes = [];
  const uniq = new Set();

  while (plain.length < safeCount) {
    const raw = createBackupCodeRaw(size);
    const normalized = normalizeBackupCode(raw);
    if (!normalized || uniq.has(normalized)) continue;
    uniq.add(normalized);
    plain.push(formatBackupCode(normalized));
    hashes.push(hashBackupCode(normalized));
  }

  return { plain, hashes };
}

module.exports = {
  TWO_FACTOR_ISSUER,
  isTwoFactorEligibleRole,
  normalizeTotpCode,
  generateTwoFactorSetup,
  verifyTwoFactorCode,
  encryptTwoFactorSecret,
  decryptTwoFactorSecret,
  normalizeBackupCode,
  hashBackupCode,
  generateBackupCodes,
};
