const fs = require('fs');
const { ensurePublicImageVariants } = require('./publicImagePipeline');
const {
  normalizePublicUploadRef,
  absoluteUploadPathFromCanonical,
  upsertMediaAsset,
} = require('./mediaAssets');

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

async function registerPublicImageUpload({
  queryable,
  ownerKind,
  ownerId = null,
  ownerTextId = null,
  slot = 'default',
  rawUrl,
}) {
  const ref = normalizePublicUploadRef(rawUrl);
  if (!ref) return null;
  const absolutePath = absoluteUploadPathFromCanonical(ref.canonicalPath);
  if (!absolutePath) return null;
  let processed;
  try {
    processed = await ensurePublicImageVariants({
      publicKind: ref.kind,
      sourcePath: absolutePath,
    });
  } catch (error) {
    const stat = await fs.promises.stat(absolutePath);
    processed = {
      original: {
        path: ref.canonicalPath,
        width: null,
        height: null,
        byte_size: stat.size,
        mime_type: null,
        checksum_sha256: null,
      },
      variants: {},
    };
  }
  return upsertMediaAsset(queryable, {
    ownerKind,
    ownerId: cleanString(ownerId) || null,
    ownerTextId: cleanString(ownerTextId) || null,
    slot: cleanString(slot) || 'default',
    storageKind: 'public',
    originalPath: processed.original.path,
    originalFilename: ref.filename,
    mimeType: processed.original.mime_type,
    byteSize: processed.original.byte_size,
    width: processed.original.width,
    height: processed.original.height,
    checksumSha256: processed.original.checksum_sha256,
    variants: processed.variants,
  });
}

module.exports = {
  registerPublicImageUpload,
};
