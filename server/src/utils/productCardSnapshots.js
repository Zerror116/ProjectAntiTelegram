const { buildPublicMediaVariantUrls } = require('./mediaAssets');

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

function toNumberOrNull(rawValue) {
  const value = Number(rawValue);
  return Number.isFinite(value) ? value : null;
}

function buildProductCardSnapshot(product, context = {}) {
  if (!product || typeof product !== 'object') return null;
  const media = buildPublicMediaVariantUrls(product.image_url || '', context, {
    fieldKey: 'product_image_url',
  });
  const shortDescription = cleanString(product.description).slice(0, 280);
  return {
    id: cleanString(product.id),
    product_code: toNumberOrNull(product.product_code),
    title: cleanString(product.title),
    short_description: shortDescription,
    price: toNumberOrNull(product.price),
    quantity: toNumberOrNull(product.quantity),
    shelf_number: toNumberOrNull(product.shelf_number),
    status: cleanString(product.status),
    image_url: media?.default_url || cleanString(product.image_url) || null,
    image_thumb_url: media?.thumb_url || null,
    image_card_url: media?.card_url || null,
    image_detail_url: media?.detail_url || null,
    image_original_url: media?.original_url || cleanString(product.image_url) || null,
    image_asset_version: media?.asset_version || 1,
    updated_at: product.updated_at || new Date().toISOString(),
  };
}

async function upsertProductCardSnapshot(queryable, product, context = {}) {
  const snapshot = buildProductCardSnapshot(product, context);
  if (!snapshot || !snapshot.id) return null;
  await queryable.query(
    `INSERT INTO product_card_snapshots (product_id, tenant_id, snapshot, media_version, updated_at)
     VALUES ($1::uuid, $2::uuid, $3::jsonb, $4, now())
     ON CONFLICT (product_id) DO UPDATE
     SET tenant_id = EXCLUDED.tenant_id,
         snapshot = EXCLUDED.snapshot,
         media_version = EXCLUDED.media_version,
         updated_at = now()`,
    [
      snapshot.id,
      context.tenantId || null,
      JSON.stringify(snapshot),
      snapshot.image_asset_version || 1,
    ],
  );
  return snapshot;
}

module.exports = {
  buildProductCardSnapshot,
  upsertProductCardSnapshot,
};
