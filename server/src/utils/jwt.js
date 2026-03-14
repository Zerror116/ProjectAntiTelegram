// server/src/utils/jwt.js
const jwt = require('jsonwebtoken');
require('dotenv').config();
const {
  normalizeKeyVersion,
  buildSecretKeyring,
  resolveSecretCandidates,
  describeKeyring,
} = require('./secretKeyring');

const EXPIRES_IN = String(process.env.JWT_EXPIRES_IN || '7d').trim() || '7d';
const JWT_KEYRING = buildSecretKeyring({
  purpose: 'jwt',
  currentVersion:
    process.env.JWT_SECRET_VERSION || process.env.JWT_KEY_VERSION || 'v1',
  singleSecret: process.env.JWT_SECRET || '',
  keyringString:
    process.env.JWT_SECRET_KEYRING || process.env.JWT_KEYRING || '',
  keyringJson:
    process.env.JWT_SECRETS_JSON || process.env.JWT_KEYS_JSON || '',
  requiredInProduction: true,
  devFallbackSecret: 'dev-jwt-secret',
});

function decodeJwtKid(token) {
  try {
    const decoded = jwt.decode(String(token || ''), { complete: true });
    return normalizeKeyVersion(decoded?.header?.kid || '', '');
  } catch (_) {
    return '';
  }
}

function signJwt(payload, options = {}) {
  const preferredVersion = normalizeKeyVersion(
    options.version || JWT_KEYRING.currentVersion,
    JWT_KEYRING.currentVersion,
  );
  const signingCandidate =
    resolveSecretCandidates(JWT_KEYRING, preferredVersion)[0] || null;
  if (!signingCandidate?.secret) {
    throw new Error('JWT signing key is not configured');
  }
  const expiresIn = String(options.expiresIn || EXPIRES_IN).trim() || EXPIRES_IN;
  return jwt.sign(payload, signingCandidate.secret, {
    expiresIn,
    keyid:
      options.includeKid === false
        ? undefined
        : signingCandidate.version || JWT_KEYRING.currentVersion,
  });
}

function verifyJwt(token) {
  if (!token) return null;
  const tokenKid = decodeJwtKid(token);
  const candidates = resolveSecretCandidates(JWT_KEYRING, tokenKid);
  for (const candidate of candidates) {
    try {
      return jwt.verify(token, candidate.secret);
    } catch (_) {
      // Try next key (supports rotation with grace period).
    }
  }
  try {
    // Last fallback for malformed/legacy tokens when no kid and candidates were empty.
    return jwt.verify(token, JWT_KEYRING.currentSecret);
  } catch (err) {
    return null;
  }
}

function getJwtKeyringMeta() {
  return describeKeyring(JWT_KEYRING);
}

module.exports = { signJwt, verifyJwt, getJwtKeyringMeta };
