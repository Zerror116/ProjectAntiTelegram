const {
  PUBLIC_UPLOAD_KINDS,
  buildPublicMediaUrl,
  rewritePublicMediaPayload,
} = require('./mediaAssets');

function buildSignedUploadUrl(rawValue, { req, baseUrl } = {}) {
  return buildPublicMediaUrl(rawValue, { req, baseUrl });
}

function rewriteSignedUploadsInPayload(payload, context = {}) {
  return rewritePublicMediaPayload(payload, context);
}

function verifySignedUploadRequest(kind, filename) {
  const safeKind = String(kind || '').toLowerCase().trim();
  const safeFilename = String(filename || '').trim();
  if (!PUBLIC_UPLOAD_KINDS.has(safeKind)) {
    return { ok: false, error: 'Unsupported upload kind' };
  }
  if (!safeFilename) {
    return { ok: false, error: 'Invalid filename' };
  }
  return {
    ok: true,
    kind: safeKind,
    filename: safeFilename,
    canonicalPath: `/uploads/${safeKind}/${safeFilename}`,
    keyVersion: null,
  };
}

function signedUploadGuard(_kind) {
  return (_req, _res, next) => next();
}

module.exports = {
  SIGNED_UPLOAD_KINDS: PUBLIC_UPLOAD_KINDS,
  buildSignedUploadUrl,
  rewriteSignedUploadsInPayload,
  signedUploadGuard,
  verifySignedUploadRequest,
};
