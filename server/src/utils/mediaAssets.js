const fs = require('fs');
const path = require('path');
const db = require('../db');
const { uploadsRoot } = require('./storagePaths');

const PUBLIC_UPLOAD_KINDS = new Set(['products', 'channels', 'users', 'claims']);
const DEFAULT_VARIANT_BY_KIND = {
  products: 'card',
  claims: 'card',
  users: 'thumb',
  channels: 'thumb',
};
const PUBLIC_PLACEHOLDER_BY_KIND = {
  products: '/uploads/products/demo-placeholder.png',
  claims: '/uploads/claims/public-media-unavailable.png',
  users: '/uploads/chat_media/images/media-unavailable.png',
  channels: '/uploads/chat_media/images/media-unavailable.png',
};
const PUBLIC_FIELD_HINTS = [
  { pattern: /(^|_)avatar_url$/i, preferredVariant: 'thumb' },
  { pattern: /(^|_)preview_image_url$/i, preferredVariant: 'thumb' },
  { pattern: /(^|_)image_url$/i, preferredVariant: null },
];

const assetByOriginalPath = new Map();
const assetByAnyPath = new Map();
const publicPathExistsCache = new Map();
let cacheLoaded = false;
let cacheLoadPromise = null;

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

function isPlainObject(value) {
  if (value == null || typeof value !== 'object' || Array.isArray(value)) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

function normalizePublicUploadRef(rawValue) {
  const raw = cleanString(rawValue);
  if (!raw) return null;

  const match = raw.match(
    /^(https?:\/\/[^/?#\s]+)?\/uploads\/(products|channels|users|claims)\/([^?#\s]+(?:\/[^?#\s]+)*)(?:\?[^#\s]*)?(?:#.*)?$/i,
  );
  if (!match) return null;

  const kind = cleanString(match[2]).toLowerCase();
  if (!PUBLIC_UPLOAD_KINDS.has(kind)) return null;

  const decodedRelative = decodeURIComponent(cleanString(match[3])).replace(/\\/g, '/');
  const parts = decodedRelative.split('/').filter(Boolean);
  if (!parts.length || parts.some((part) => part === '.' || part === '..')) return null;
  const relativePath = parts.join('/');
  const filename = path.basename(relativePath);
  if (!filename || filename.startsWith('.')) return null;

  return {
    kind,
    relativePath,
    filename,
    canonicalPath: `/uploads/${kind}/${relativePath}`,
  };
}

function resolveOrigin(req, baseUrl) {
  const normalizedBase = cleanString(baseUrl);
  if (normalizedBase) {
    try {
      return new URL(normalizedBase).origin;
    } catch (_) {}
  }
  if (!req) return '';
  try {
    return `${req.protocol}://${req.get('host')}`;
  } catch (_) {
    return '';
  }
}

function appendVersion(canonicalPath, version) {
  const safeVersion = Number.isFinite(Number(version)) && Number(version) > 0 ? Number(version) : 1;
  return `${canonicalPath}?v=${safeVersion}`;
}

function absoluteUrlFromCanonical(canonicalPath, { req, baseUrl } = {}) {
  const origin = resolveOrigin(req, baseUrl);
  if (!origin) return canonicalPath;
  return `${origin}${canonicalPath}`;
}

function versionedAbsoluteUrl(canonicalPath, version, context = {}) {
  return absoluteUrlFromCanonical(appendVersion(canonicalPath, version), context);
}

function toOriginalPublicMediaUrl(rawValue, context = {}) {
  const ref = normalizePublicUploadRef(rawValue);
  if (!ref) return rawValue;
  const matched = assetByAnyPath.get(ref.canonicalPath);
  const originalPath = matched?.asset?.original_path || ref.canonicalPath;
  return absoluteUrlFromCanonical(originalPath, context);
}

function canonicalUploadPathFromAbsolute(filePath) {
  const relative = path.relative(uploadsRoot, path.resolve(filePath)).split(path.sep).join('/');
  const normalized = cleanString(relative).replace(/^\/+/, '');
  if (!normalized || normalized.startsWith('..')) return null;
  const kind = cleanString(normalized.split('/')[0]).toLowerCase();
  if (!PUBLIC_UPLOAD_KINDS.has(kind)) return null;
  return `/uploads/${normalized}`;
}

function absoluteUploadPathFromCanonical(canonicalPath) {
  const ref = normalizePublicUploadRef(canonicalPath);
  if (!ref) return null;
  return path.join(uploadsRoot, ref.kind, ...ref.relativePath.split('/'));
}

function absoluteUploadsPathFromAnyCanonical(canonicalPath) {
  const normalized = cleanString(canonicalPath);
  if (!normalized.startsWith('/uploads/')) return null;
  const relative = normalized.slice('/uploads/'.length).split('/').filter(Boolean);
  if (!relative.length || relative.some((part) => part === '.' || part === '..')) {
    return null;
  }
  return path.join(uploadsRoot, ...relative);
}

function publicPathExists(canonicalPath) {
  const normalized = cleanString(canonicalPath).split('?')[0].split('#')[0];
  if (!normalized) return false;
  const cached = publicPathExistsCache.get(normalized);
  if (cached != null) return cached;
  const absolutePath = absoluteUploadsPathFromAnyCanonical(normalized);
  const exists = !!absolutePath && fs.existsSync(absolutePath);
  publicPathExistsCache.set(normalized, exists);
  return exists;
}

function firstExistingPublicPath(paths) {
  for (const rawPath of paths) {
    const candidate = cleanString(rawPath);
    if (!candidate) continue;
    if (publicPathExists(candidate)) return candidate;
  }
  return null;
}

function preferredVariantForField(fieldKey, kind) {
  const key = cleanString(fieldKey).toLowerCase();
  for (const hint of PUBLIC_FIELD_HINTS) {
    if (!hint.pattern.test(key)) continue;
    if (hint.preferredVariant) return hint.preferredVariant;
    break;
  }
  return DEFAULT_VARIANT_BY_KIND[kind] || 'card';
}

function setAssetCacheRow(row) {
  if (!row || typeof row !== 'object') return null;
  const variants = isPlainObject(row.variants) ? row.variants : {};
  const asset = {
    id: row.id,
    owner_kind: cleanString(row.owner_kind),
    owner_id: row.owner_id || null,
    owner_text_id: cleanString(row.owner_text_id) || null,
    slot: cleanString(row.slot) || 'default',
    storage_kind: cleanString(row.storage_kind) || 'public',
    original_path: cleanString(row.original_path),
    original_filename: cleanString(row.original_filename),
    mime_type: cleanString(row.mime_type) || null,
    byte_size: row.byte_size == null ? null : Number(row.byte_size),
    width: row.width == null ? null : Number(row.width),
    height: row.height == null ? null : Number(row.height),
    duration_ms: row.duration_ms == null ? null : Number(row.duration_ms),
    checksum_sha256: cleanString(row.checksum_sha256) || null,
    asset_version: row.asset_version == null ? 1 : Number(row.asset_version) || 1,
    variants,
    placeholder_applied_at: row.placeholder_applied_at || null,
    updated_at: row.updated_at || null,
    last_verified_at: row.last_verified_at || null,
  };

  if (asset.original_path) {
    assetByOriginalPath.set(asset.original_path, asset);
    assetByAnyPath.set(asset.original_path, { asset, variantKey: 'original' });
  }
  for (const [variantKey, variantValue] of Object.entries(variants)) {
    const variantPath = cleanString(variantValue?.path || '');
    if (!variantPath) continue;
    assetByAnyPath.set(variantPath, { asset, variantKey });
  }
  return asset;
}

function clearAssetCache() {
  assetByOriginalPath.clear();
  assetByAnyPath.clear();
  publicPathExistsCache.clear();
  cacheLoaded = false;
}

async function refreshMediaAssetCache(queryable = db) {
  const result = await queryable.query(
    `SELECT id, owner_kind, owner_id, owner_text_id, slot, storage_kind,
            original_path, original_filename, mime_type, byte_size,
            width, height, duration_ms, checksum_sha256, asset_version,
            variants, placeholder_applied_at, updated_at, last_verified_at
     FROM media_assets`,
  );
  assetByOriginalPath.clear();
  assetByAnyPath.clear();
  publicPathExistsCache.clear();
  for (const row of result.rows || []) {
    setAssetCacheRow(row);
  }
  cacheLoaded = true;
}

async function ensureMediaAssetCache(queryable = db) {
  if (cacheLoaded) return;
  if (!cacheLoadPromise) {
    cacheLoadPromise = refreshMediaAssetCache(queryable).finally(() => {
      cacheLoadPromise = null;
    });
  }
  await cacheLoadPromise;
}

function getMediaAssetByPath(rawValue) {
  const ref = normalizePublicUploadRef(rawValue);
  if (!ref) return null;
  return assetByAnyPath.get(ref.canonicalPath) || null;
}

function buildPublicMediaVariantUrls(rawValue, context = {}, { fieldKey = '' } = {}) {
  const ref = normalizePublicUploadRef(rawValue);
  if (!ref) return null;
  const match = getMediaAssetByPath(rawValue);
  const asset = match?.asset || assetByOriginalPath.get(ref.canonicalPath) || null;
  const version = asset?.asset_version || 1;
  const variants = isPlainObject(asset?.variants) ? asset.variants : {};
  const placeholderPath = PUBLIC_PLACEHOLDER_BY_KIND[ref.kind] || PUBLIC_PLACEHOLDER_BY_KIND.products;
  const originalPath = cleanString(asset?.original_path || ref.canonicalPath);
  const thumbPath = cleanString(variants.thumb?.path || '');
  const cardPath = cleanString(variants.card?.path || '');
  const detailPath = cleanString(variants.detail?.path || '');
  if (asset?.placeholder_applied_at) {
    return {
      asset,
      asset_version: version,
      default_url: versionedAbsoluteUrl(placeholderPath, version, context),
      original_url: versionedAbsoluteUrl(placeholderPath, version, context),
      thumb_url: versionedAbsoluteUrl(placeholderPath, version, context),
      card_url: versionedAbsoluteUrl(placeholderPath, version, context),
      detail_url: versionedAbsoluteUrl(placeholderPath, version, context),
    };
  }
  const preferred = preferredVariantForField(fieldKey, ref.kind);
  const preferredDefaultPath =
    (preferred === 'thumb' && thumbPath) ||
    (preferred === 'card' && cardPath) ||
    (preferred === 'detail' && detailPath) ||
    (cardPath && (ref.kind === 'products' || ref.kind === 'claims')) ||
    (thumbPath && (ref.kind === 'users' || ref.kind === 'channels')) ||
    originalPath;
  const defaultPath =
    firstExistingPublicPath([
      preferredDefaultPath,
      cardPath,
      thumbPath,
      detailPath,
      originalPath,
    ]) || placeholderPath;
  const resolvedOriginalPath =
    firstExistingPublicPath([originalPath, detailPath, cardPath, thumbPath]) || placeholderPath;
  const resolvedThumbPath = firstExistingPublicPath([thumbPath, cardPath, originalPath]);
  const resolvedCardPath = firstExistingPublicPath([cardPath, thumbPath, originalPath]);
  const resolvedDetailPath = firstExistingPublicPath([detailPath, originalPath]);

  return {
    asset,
    asset_version: version,
    default_url: versionedAbsoluteUrl(defaultPath, version, context),
    original_url: versionedAbsoluteUrl(resolvedOriginalPath, version, context),
    thumb_url: resolvedThumbPath ? versionedAbsoluteUrl(resolvedThumbPath, version, context) : null,
    card_url: resolvedCardPath ? versionedAbsoluteUrl(resolvedCardPath, version, context) : null,
    detail_url: resolvedDetailPath ? versionedAbsoluteUrl(resolvedDetailPath, version, context) : null,
  };
}

function buildPublicMediaUrl(rawValue, context = {}, options = {}) {
  const urls = buildPublicMediaVariantUrls(rawValue, context, options);
  if (!urls) return rawValue;
  return urls.default_url;
}

function fieldPrefixForUrlKey(key) {
  const normalized = cleanString(key);
  if (!normalized.endsWith('_url')) return null;
  return normalized.slice(0, -4);
}

function augmentObjectWithPublicMedia(obj, context = {}) {
  if (!isPlainObject(obj)) return obj;
  const out = {};
  for (const [key, value] of Object.entries(obj)) {
    if (typeof value === 'string') {
      const urls = buildPublicMediaVariantUrls(value, context, { fieldKey: key });
      if (urls) {
        const prefix = fieldPrefixForUrlKey(key);
        out[key] = urls.default_url;
        if (prefix) {
          out[`${prefix}_original_url`] = urls.original_url;
          if (urls.thumb_url) out[`${prefix}_thumb_url`] = urls.thumb_url;
          if (urls.card_url) out[`${prefix}_card_url`] = urls.card_url;
          if (urls.detail_url) out[`${prefix}_detail_url`] = urls.detail_url;
          out[`${prefix}_asset_version`] = urls.asset_version;
        }
        continue;
      }
    }
    out[key] = value;
  }
  return out;
}

function rewritePublicMediaPayload(payload, context = {}) {
  const seen = new WeakSet();

  const walk = (value) => {
    if (value == null) return value;
    if (typeof value === 'string') {
      return buildPublicMediaUrl(value, context);
    }
    if (typeof value !== 'object') return value;
    if (Buffer.isBuffer(value)) return value;
    if (value instanceof Date) return value;
    if (!Array.isArray(value) && !isPlainObject(value)) return value;
    if (seen.has(value)) return value;
    seen.add(value);

    if (Array.isArray(value)) {
      return value.map((item) => walk(item));
    }

    const out = augmentObjectWithPublicMedia(value, context);
    for (const [key, entry] of Object.entries(out)) {
      if (typeof entry === 'object' && entry !== null) {
        out[key] = walk(entry);
      }
    }
    return out;
  };

  return walk(payload);
}

async function upsertMediaAsset(queryable = db, payload = {}) {
  const ownerKind = cleanString(payload.ownerKind || payload.owner_kind);
  const slot = cleanString(payload.slot) || 'default';
  const storageKind = cleanString(payload.storageKind || payload.storage_kind) || 'public';
  const originalPath = cleanString(payload.originalPath || payload.original_path);
  const originalFilename = cleanString(payload.originalFilename || payload.original_filename || path.basename(originalPath));
  if (!ownerKind || !originalPath) {
    throw new Error('ownerKind and originalPath are required for media asset upsert');
  }
  const ownerId = cleanString(payload.ownerId || payload.owner_id) || null;
  const ownerTextId = cleanString(payload.ownerTextId || payload.owner_text_id) || null;
  const variants = isPlainObject(payload.variants) ? payload.variants : {};

  if (ownerId) {
    await queryable.query(
      `DELETE FROM media_assets
       WHERE owner_kind = $1
         AND owner_id = $2::uuid
         AND slot = $3
         AND original_path <> $4`,
      [ownerKind, ownerId, slot, originalPath],
    );
  } else if (ownerTextId) {
    await queryable.query(
      `DELETE FROM media_assets
       WHERE owner_kind = $1
         AND owner_text_id = $2
         AND slot = $3
         AND original_path <> $4`,
      [ownerKind, ownerTextId, slot, originalPath],
    );
  }

  const result = await queryable.query(
    `INSERT INTO media_assets (
       owner_kind, owner_id, owner_text_id, slot, storage_kind,
       original_path, original_filename, mime_type, byte_size,
       width, height, duration_ms, checksum_sha256, variants,
       placeholder_applied_at, last_verified_at, asset_version, created_at, updated_at
     )
     VALUES (
       $1, $2::uuid, $3, $4, $5,
       $6, $7, $8, $9,
       $10, $11, $12, $13, $14::jsonb,
       $15::timestamptz, now(), 1, now(), now()
     )
     ON CONFLICT (original_path) DO UPDATE
     SET owner_kind = EXCLUDED.owner_kind,
         owner_id = EXCLUDED.owner_id,
         owner_text_id = EXCLUDED.owner_text_id,
         slot = EXCLUDED.slot,
         storage_kind = EXCLUDED.storage_kind,
         original_filename = EXCLUDED.original_filename,
         mime_type = EXCLUDED.mime_type,
         byte_size = EXCLUDED.byte_size,
         width = EXCLUDED.width,
         height = EXCLUDED.height,
         duration_ms = EXCLUDED.duration_ms,
         checksum_sha256 = EXCLUDED.checksum_sha256,
         variants = EXCLUDED.variants,
         placeholder_applied_at = EXCLUDED.placeholder_applied_at,
         last_verified_at = now(),
         asset_version = CASE
           WHEN COALESCE(media_assets.checksum_sha256, '') <> COALESCE(EXCLUDED.checksum_sha256, '')
             OR COALESCE(media_assets.variants, '{}'::jsonb) <> COALESCE(EXCLUDED.variants, '{}'::jsonb)
           THEN media_assets.asset_version + 1
           ELSE media_assets.asset_version
         END,
         updated_at = now()
     RETURNING *`,
    [
      ownerKind,
      ownerId,
      ownerTextId,
      slot,
      storageKind,
      originalPath,
      originalFilename,
      cleanString(payload.mimeType || payload.mime_type) || null,
      payload.byteSize == null ? null : Number(payload.byteSize),
      payload.width == null ? null : Number(payload.width),
      payload.height == null ? null : Number(payload.height),
      payload.durationMs == null ? null : Number(payload.durationMs),
      cleanString(payload.checksumSha256 || payload.checksum_sha256) || null,
      JSON.stringify(variants),
      payload.placeholderAppliedAt || null,
    ],
  );
  const asset = setAssetCacheRow(result.rows[0]);
  cacheLoaded = true;
  return asset;
}

module.exports = {
  PUBLIC_UPLOAD_KINDS,
  normalizePublicUploadRef,
  canonicalUploadPathFromAbsolute,
  absoluteUploadPathFromCanonical,
  buildPublicMediaUrl,
  buildPublicMediaVariantUrls,
  toOriginalPublicMediaUrl,
  rewritePublicMediaPayload,
  refreshMediaAssetCache,
  ensureMediaAssetCache,
  getMediaAssetByPath,
  upsertMediaAsset,
  clearAssetCache,
};
