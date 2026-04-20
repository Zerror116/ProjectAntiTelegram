#!/usr/bin/env node

const fs = require('fs');
const db = require('../src/db');
const {
  normalizePublicUploadRef,
  absoluteUploadPathFromCanonical,
  refreshMediaAssetCache,
} = require('../src/utils/mediaAssets');
const { registerPublicImageUpload } = require('../src/utils/publicMediaRegistration');
const { upsertProductCardSnapshot } = require('../src/utils/productCardSnapshots');

async function loadCandidates() {
  const [products, users, chats, claims] = await Promise.all([
    db.query(`SELECT id, image_url, title, description, price, quantity, shelf_number, product_code, status, updated_at FROM products WHERE COALESCE(BTRIM(image_url), '') <> ''`),
    db.query(`SELECT id, avatar_url FROM users WHERE COALESCE(BTRIM(avatar_url), '') <> ''`),
    db.query(`SELECT id, settings FROM chats WHERE COALESCE(BTRIM(settings->>'avatar_url'), '') <> ''`),
    db.query(`SELECT id, image_url FROM customer_claims WHERE COALESCE(BTRIM(image_url), '') <> ''`),
  ]);
  return {
    product_image: products.rows.map((row) => ({ ownerKind: 'product_image', ownerId: row.id, rawUrl: row.image_url, row })),
    user_avatar: users.rows.map((row) => ({ ownerKind: 'user_avatar', ownerId: row.id, rawUrl: row.avatar_url, row })),
    channel_avatar: chats.rows.map((row) => ({ ownerKind: 'channel_avatar', ownerId: row.id, rawUrl: row.settings?.avatar_url, row })),
    claim_image: claims.rows.map((row) => ({ ownerKind: 'claim_image', ownerId: row.id, rawUrl: row.image_url, row })),
  };
}

async function main() {
  const grouped = await loadCandidates();
  const summary = {};

  for (const [kind, entries] of Object.entries(grouped)) {
    summary[kind] = { total: entries.length, registered: 0, missing: 0, skipped: 0 };
    for (const entry of entries) {
      const ref = normalizePublicUploadRef(entry.rawUrl);
      if (!ref) {
        summary[kind].skipped += 1;
        continue;
      }
      const absolutePath = absoluteUploadPathFromCanonical(ref.canonicalPath);
      if (!absolutePath || !fs.existsSync(absolutePath)) {
        summary[kind].missing += 1;
        continue;
      }
      await registerPublicImageUpload({
        queryable: db,
        ownerKind: entry.ownerKind,
        ownerId: entry.ownerId,
        rawUrl: entry.rawUrl,
      });
      if (entry.ownerKind === 'product_image') {
        await upsertProductCardSnapshot(db, entry.row, {});
      }
      summary[kind].registered += 1;
    }
  }

  await refreshMediaAssetCache();
  console.log(JSON.stringify(summary, null, 2));
}

main()
  .then(() => {
    process.exitCode = 0;
  })
  .catch((err) => {
    console.error('[media_assets_backfill] failed', err);
    process.exitCode = 1;
  })
  .finally(async () => {
    try {
      await db.pool.end();
    } catch (_) {}
    setImmediate(() => process.exit(process.exitCode || 0));
  });
