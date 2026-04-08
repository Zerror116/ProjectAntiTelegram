const crypto = require('crypto');

const DEV_MANIFEST_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIDmnQDrGw3qsjeLXkSIMfOjVGmLbcRk77USmDcTIAvrH
-----END PRIVATE KEY-----`;

const DEV_MANIFEST_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA3q2i6PehgDQjJGDh632o6N43lDFbQUpSbOnaerrTgmk=
-----END PUBLIC KEY-----`;

function cleanPem(rawValue) {
  const normalized = String(rawValue || '').trim();
  if (!normalized) return '';
  return normalized.replace(/\\n/g, '\n').trim();
}

function stableJson(value) {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableJson(item)).join(',')}]`;
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value)
      .filter((key) => value[key] !== undefined)
      .sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(',')}}`;
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number') {
    return Number.isFinite(value) ? String(value) : 'null';
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return JSON.stringify(String(value));
}

function getManifestSigningConfig() {
  const privateKey = cleanPem(process.env.APP_UPDATE_MANIFEST_PRIVATE_KEY);
  const publicKey = cleanPem(process.env.APP_UPDATE_MANIFEST_PUBLIC_KEY);
  const keyId = String(process.env.APP_UPDATE_MANIFEST_KEY_ID || 'dev-ed25519')
    .trim() || 'dev-ed25519';

  if (privateKey && publicKey) {
    return {
      privateKey,
      publicKey,
      keyId,
      usesDevFallback: false,
      algorithm: 'ed25519',
    };
  }

  if (process.env.NODE_ENV === 'production') {
    throw new Error(
      'APP_UPDATE_MANIFEST_PRIVATE_KEY and APP_UPDATE_MANIFEST_PUBLIC_KEY must be configured in production',
    );
  }

  return {
    privateKey: DEV_MANIFEST_PRIVATE_KEY,
    publicKey: DEV_MANIFEST_PUBLIC_KEY,
    keyId,
    usesDevFallback: true,
    algorithm: 'ed25519',
  };
}

function signManifestPayload(payload) {
  const config = getManifestSigningConfig();
  const canonical = stableJson(payload);
  const signature = crypto.sign(null, Buffer.from(canonical, 'utf8'), config.privateKey);
  return {
    keyId: config.keyId,
    algorithm: config.algorithm,
    signature: signature.toString('base64'),
    canonical,
    publicKey: config.publicKey,
    usesDevFallback: config.usesDevFallback,
  };
}

module.exports = {
  DEV_MANIFEST_PUBLIC_KEY,
  getManifestSigningConfig,
  signManifestPayload,
  stableJson,
};
