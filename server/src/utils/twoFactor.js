const { authenticator } = require("otplib");

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

module.exports = {
  TWO_FACTOR_ISSUER,
  isTwoFactorEligibleRole,
  normalizeTotpCode,
  generateTwoFactorSetup,
  verifyTwoFactorCode,
  encryptTwoFactorSecret,
  decryptTwoFactorSecret,
};
