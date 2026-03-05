const crypto = require('crypto');

const ENCRYPTION_VERSION = 'aes-256-gcm-v1';
const RAW_KEY =
  process.env.APP_DATA_KEY ||
  process.env.ADDRESS_DATA_KEY ||
  'project-phoenix-local-dev-key-change-me';
const KEY = crypto.createHash('sha256').update(String(RAW_KEY)).digest();

function normalizePlainText(value) {
  const text = String(value || '').trim();
  return text.length > 0 ? text : '';
}

function encryptText(value) {
  const text = normalizePlainText(value);
  if (!text) {
    return {
      ciphertext: null,
      iv: null,
      tag: null,
      version: ENCRYPTION_VERSION,
      encryptedAt: null,
    };
  }

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', KEY, iv);
  const encrypted = Buffer.concat([
    cipher.update(Buffer.from(text, 'utf8')),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();

  return {
    ciphertext: encrypted.toString('base64'),
    iv: iv.toString('base64'),
    tag: tag.toString('base64'),
    version: ENCRYPTION_VERSION,
    encryptedAt: new Date().toISOString(),
  };
}

function decryptText(parts) {
  try {
    const ciphertext = String(parts?.ciphertext || '').trim();
    const iv = String(parts?.iv || '').trim();
    const tag = String(parts?.tag || '').trim();
    if (!ciphertext || !iv || !tag) return null;

    const decipher = crypto.createDecipheriv(
      'aes-256-gcm',
      KEY,
      Buffer.from(iv, 'base64'),
    );
    decipher.setAuthTag(Buffer.from(tag, 'base64'));

    const decrypted = Buffer.concat([
      decipher.update(Buffer.from(ciphertext, 'base64')),
      decipher.final(),
    ]);
    const text = decrypted.toString('utf8').trim();
    return text || null;
  } catch (_) {
    return null;
  }
}

function readEncryptedText(row, prefix = 'address') {
  const ciphertext = row?.[`${prefix}_ciphertext`];
  const iv = row?.[`${prefix}_iv`];
  const tag = row?.[`${prefix}_tag`];
  const decrypted = decryptText({ ciphertext, iv, tag });
  if (decrypted) return decrypted;

  const fallback = String(row?.[`${prefix}_text`] || '').trim();
  return fallback || '';
}

function writeEncryptedTextParams(value) {
  const encrypted = encryptText(value);
  return {
    text: null,
    ciphertext: encrypted.ciphertext,
    iv: encrypted.iv,
    tag: encrypted.tag,
    version: encrypted.version,
    encryptedAt: encrypted.encryptedAt,
  };
}

module.exports = {
  ENCRYPTION_VERSION,
  encryptText,
  decryptText,
  readEncryptedText,
  writeEncryptedTextParams,
};
