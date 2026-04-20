#!/usr/bin/env node

const db = require('../src/db');
const {
  normalizePublicUploadRef,
  absoluteUploadPathFromCanonical,
  refreshMediaAssetCache,
} = require('../src/utils/mediaAssets');
const { ensurePlaceholderAssets } = require('../src/utils/uploadRecovery');
const { registerPublicImageUpload } = require('../src/utils/publicMediaRegistration');
const { upsertProductCardSnapshot } = require('../src/utils/productCardSnapshots');

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

async function main() {
  const publicBaseUrl = cleanString(process.env.PUBLIC_BASE_URL || process.env.API_PUBLIC_BASE_URL || 'http://localhost:3001');
  const placeholders = ensurePlaceholderAssets(publicBaseUrl);
  const stats = {
    product_images_placeholder: 0,
    claim_images_placeholder: 0,
    user_avatars_cleared: 0,
    channel_avatars_cleared: 0,
    relinked: 0,
  };
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');

    const products = await client.query(`SELECT id, image_url, title, description, price, quantity, shelf_number, product_code, status, updated_at FROM products WHERE COALESCE(BTRIM(image_url), '') <> ''`);
    for (const row of products.rows) {
      const ref = normalizePublicUploadRef(row.image_url);
      if (ref && absoluteUploadPathFromCanonical(ref.canonicalPath)) {
        const filePath = absoluteUploadPathFromCanonical(ref.canonicalPath);
        if (filePath && require('fs').existsSync(filePath)) {
          await registerPublicImageUpload({ queryable: client, ownerKind: 'product_image', ownerId: row.id, rawUrl: row.image_url });
          await upsertProductCardSnapshot(client, row, {});
          stats.relinked += 1;
          continue;
        }
      }
      await client.query(`UPDATE products SET image_url = $2, updated_at = now() WHERE id = $1`, [row.id, placeholders.product_placeholder_url]);
      await registerPublicImageUpload({ queryable: client, ownerKind: 'product_image', ownerId: row.id, rawUrl: placeholders.product_placeholder_url });
      await upsertProductCardSnapshot(client, { ...row, image_url: placeholders.product_placeholder_url }, {});
      stats.product_images_placeholder += 1;
    }

    const claims = await client.query(`SELECT id, image_url FROM customer_claims WHERE COALESCE(BTRIM(image_url), '') <> ''`);
    for (const row of claims.rows) {
      const ref = normalizePublicUploadRef(row.image_url);
      if (ref && absoluteUploadPathFromCanonical(ref.canonicalPath)) {
        const filePath = absoluteUploadPathFromCanonical(ref.canonicalPath);
        if (filePath && require('fs').existsSync(filePath)) {
          await registerPublicImageUpload({ queryable: client, ownerKind: 'claim_image', ownerId: row.id, rawUrl: row.image_url });
          stats.relinked += 1;
          continue;
        }
      }
      await client.query(`UPDATE customer_claims SET image_url = $2, updated_at = now() WHERE id = $1`, [row.id, placeholders.public_media_placeholder_url]);
      await registerPublicImageUpload({ queryable: client, ownerKind: 'claim_image', ownerId: row.id, rawUrl: placeholders.public_media_placeholder_url });
      stats.claim_images_placeholder += 1;
    }

    const users = await client.query(`SELECT id, avatar_url FROM users WHERE COALESCE(BTRIM(avatar_url), '') <> ''`);
    for (const row of users.rows) {
      const ref = normalizePublicUploadRef(row.avatar_url);
      const filePath = ref ? absoluteUploadPathFromCanonical(ref.canonicalPath) : null;
      if (filePath && require('fs').existsSync(filePath)) {
        await registerPublicImageUpload({ queryable: client, ownerKind: 'user_avatar', ownerId: row.id, rawUrl: row.avatar_url });
        stats.relinked += 1;
        continue;
      }
      await client.query(`UPDATE users SET avatar_url = NULL, updated_at = now() WHERE id = $1`, [row.id]);
      stats.user_avatars_cleared += 1;
    }

    const chats = await client.query(`SELECT id, settings FROM chats WHERE COALESCE(BTRIM(settings->>'avatar_url'), '') <> ''`);
    for (const row of chats.rows) {
      const avatarUrl = cleanString(row.settings?.avatar_url);
      const ref = normalizePublicUploadRef(avatarUrl);
      const filePath = ref ? absoluteUploadPathFromCanonical(ref.canonicalPath) : null;
      if (filePath && require('fs').existsSync(filePath)) {
        await registerPublicImageUpload({ queryable: client, ownerKind: 'channel_avatar', ownerId: row.id, rawUrl: avatarUrl });
        stats.relinked += 1;
        continue;
      }
      await client.query(`UPDATE chats SET settings = settings - 'avatar_url', updated_at = now() WHERE id = $1`, [row.id]);
      stats.channel_avatars_cleared += 1;
    }

    await client.query('COMMIT');
    await refreshMediaAssetCache(client);
    console.log(JSON.stringify(stats, null, 2));
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    throw err;
  } finally {
    client.release();
  }
}

main()
  .catch((err) => {
    console.error('[media_assets_sanitize] failed', err);
    process.exitCode = 1;
  })
  .finally(async () => {
    try {
      await db.pool.end();
    } catch (_) {}
    setImmediate(() => process.exit(process.exitCode || 0));
  });
