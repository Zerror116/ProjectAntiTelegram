const crypto = require("crypto");

const MESSAGE_ENCRYPTION_PREFIX = "encmsg";
const DEFAULT_KEY_VERSION = "v1";
const DEFAULT_DEV_KEY = "project-phoenix-local-dev-key-change-me";
const UNREADABLE_ENCRYPTED_PLACEHOLDER = "[Зашифрованное сообщение]";
const FALLBACK_RAW_KEY =
  process.env.APP_MESSAGE_KEY ||
  process.env.APP_DATA_KEY ||
  process.env.ADDRESS_DATA_KEY ||
  DEFAULT_DEV_KEY;

function normalizeKeyVersion(raw) {
  const normalized = String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "");
  return normalized || DEFAULT_KEY_VERSION;
}

function hashKey(raw) {
  return crypto.createHash("sha256").update(String(raw || "")).digest();
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
  for (const chunk of source.split(",")) {
    const pair = chunk.trim();
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

function buildKeyring() {
  const keyring = new Map();
  const currentVersion = normalizeKeyVersion(process.env.APP_MESSAGE_KEY_VERSION);
  const addKey = (versionRaw, secretRaw) => {
    const version = normalizeKeyVersion(versionRaw);
    const secret = String(secretRaw || "").trim();
    if (!secret) return;
    keyring.set(version, hashKey(secret));
  };

  const jsonSource = parseKeyringJson(process.env.APP_MESSAGE_KEYS_JSON);
  for (const [version, secret] of Object.entries(jsonSource)) {
    addKey(version, secret);
  }
  const stringSource = parseKeyringString(process.env.APP_MESSAGE_KEYRING);
  for (const [version, secret] of Object.entries(stringSource)) {
    addKey(version, secret);
  }

  if (!keyring.has(currentVersion)) {
    addKey(currentVersion, FALLBACK_RAW_KEY);
  }

  if (keyring.size === 0) {
    addKey(DEFAULT_KEY_VERSION, FALLBACK_RAW_KEY);
  }

  return { keyring, currentVersion };
}

const { keyring: KEYRING, currentVersion: CURRENT_KEY_VERSION } = buildKeyring();
const MESSAGE_ENCRYPTION_VERSION =
  `${MESSAGE_ENCRYPTION_PREFIX}:${CURRENT_KEY_VERSION}`;

if (
  process.env.NODE_ENV === "production" &&
  FALLBACK_RAW_KEY === DEFAULT_DEV_KEY
) {
  throw new Error(
    "APP_MESSAGE_KEY (or APP_DATA_KEY/ADDRESS_DATA_KEY) must be configured in production.",
  );
}

function normalizeMessageText(value) {
  if (value == null) return "";
  return String(value);
}

function parseEncryptedMessage(value) {
  const raw = normalizeMessageText(value).trim();
  if (!raw || !raw.startsWith(`${MESSAGE_ENCRYPTION_PREFIX}:`)) return null;
  const parts = raw.split(":");
  if (parts.length < 5) return null;
  const version = normalizeKeyVersion(parts[1]);
  const ivBase64 = parts[2];
  const tagBase64 = parts[3];
  const ciphertextBase64 = parts.slice(4).join(":");
  if (!version || !ivBase64 || !tagBase64 || !ciphertextBase64) return null;
  return { version, ivBase64, tagBase64, ciphertextBase64 };
}

function isEncryptedMessageText(value) {
  return parseEncryptedMessage(value) !== null;
}

function getEncryptedMessageVersion(value) {
  return parseEncryptedMessage(value)?.version || null;
}

function getCurrentMessageKeyVersion() {
  return CURRENT_KEY_VERSION;
}

function listMessageKeyVersions() {
  return Array.from(KEYRING.keys());
}

function resolveKey(versionRaw) {
  const version = normalizeKeyVersion(versionRaw);
  return KEYRING.get(version) || null;
}

function encryptMessageText(value, options = {}) {
  const plainText = normalizeMessageText(value);
  if (!plainText) return "";
  const force = options.force === true;
  if (!force && isEncryptedMessageText(plainText)) return plainText;

  const targetVersion = normalizeKeyVersion(
    options.version || CURRENT_KEY_VERSION,
  );
  const key = resolveKey(targetVersion);
  if (!key) {
    throw new Error(
      `No encryption key configured for message key version "${targetVersion}"`,
    );
  }

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([
    cipher.update(Buffer.from(plainText, "utf8")),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return `${MESSAGE_ENCRYPTION_PREFIX}:${targetVersion}:${iv.toString("base64")}:${tag.toString("base64")}:${encrypted.toString("base64")}`;
}

function decryptMessageText(value) {
  const raw = normalizeMessageText(value);
  if (!raw) return "";
  const parsed = parseEncryptedMessage(raw);
  if (!parsed) return raw;

  const key = resolveKey(parsed.version);
  if (!key) return UNREADABLE_ENCRYPTED_PLACEHOLDER;

  try {
    const decipher = crypto.createDecipheriv(
      "aes-256-gcm",
      key,
      Buffer.from(parsed.ivBase64, "base64"),
    );
    decipher.setAuthTag(Buffer.from(parsed.tagBase64, "base64"));
    const decrypted = Buffer.concat([
      decipher.update(Buffer.from(parsed.ciphertextBase64, "base64")),
      decipher.final(),
    ]);
    return decrypted.toString("utf8");
  } catch (_) {
    return UNREADABLE_ENCRYPTED_PLACEHOLDER;
  }
}

function decryptMessageRow(row, key = "text") {
  if (!row || typeof row !== "object") return row;
  const next = { ...row };
  next[key] = decryptMessageText(next[key]);
  return next;
}

function decryptMessageRows(rows, key = "text") {
  if (!Array.isArray(rows)) return [];
  return rows.map((row) => decryptMessageRow(row, key));
}

module.exports = {
  MESSAGE_ENCRYPTION_PREFIX,
  MESSAGE_ENCRYPTION_VERSION,
  getCurrentMessageKeyVersion,
  getEncryptedMessageVersion,
  listMessageKeyVersions,
  isEncryptedMessageText,
  encryptMessageText,
  decryptMessageText,
  decryptMessageRow,
  decryptMessageRows,
};
