#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const db = require("../src/db");
const { uploadsRoot } = require("../src/utils/storagePaths");
const {
  cleanString,
  buildManifestEntry,
  summaryFromManifest,
} = require("../src/utils/uploadRecovery");

function parseArgs(argv) {
  const args = {
    output: path.resolve(process.cwd(), "tmp/uploads-recovery-manifest.json"),
    missingOnly: false,
    pretty: true,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--output") {
      args.output = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--missing-only") {
      args.missingOnly = true;
      continue;
    }
    if (token === "--compact") {
      args.pretty = false;
      continue;
    }
    if (token === "-h" || token === "--help") {
      console.log(`Usage: node server/scripts/uploads_recovery_audit.js [--output FILE] [--missing-only] [--compact]`);
      process.exit(0);
    }
  }
  return args;
}

function productLikeMessageKindExpression() {
  return `(
    COALESCE(NULLIF(BTRIM(meta->>'product_id'), ''), '') <> ''
    OR COALESCE(NULLIF(BTRIM(meta->>'product_code'), ''), '') <> ''
    OR COALESCE(NULLIF(BTRIM(meta->>'shelf_number'), ''), '') <> ''
    OR COALESCE(NULLIF(BTRIM(meta->>'product_shelf_number'), ''), '') <> ''
    OR lower(COALESCE(meta->>'kind', '')) IN ('catalog_product', 'catalog', 'reserved_order', 'reserved_orders')
  )`;
}

async function queryRows(sql, label) {
  try {
    const result = await db.platformQuery(sql);
    return result.rows || [];
  } catch (err) {
    console.error(`[uploads_recovery_audit] skipped ${label}: ${err.message}`);
    return [];
  }
}

function pushEntry(entries, skipped, payload) {
  const entry = buildManifestEntry(payload);
  if (!entry) {
    skipped.push({
      kind: cleanString(payload.kind),
      record_id: cleanString(payload.recordId),
      field: cleanString(payload.field),
      original_url: cleanString(payload.originalUrl),
      reason: "unsupported_or_external_url",
    });
    return;
  }
  entries.push(entry);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const entries = [];
  const skipped = [];

  const productRows = await queryRows(
    `SELECT id::text AS record_id,
            image_url AS original_url
     FROM products
     WHERE COALESCE(BTRIM(image_url), '') <> ''`,
    "products.image_url",
  );
  for (const row of productRows) {
    pushEntry(entries, skipped, {
      kind: "product_image",
      recordId: row.record_id,
      field: "image_url",
      originalUrl: row.original_url,
    });
  }

  const userAvatarRows = await queryRows(
    `SELECT id::text AS record_id,
            avatar_url AS original_url
     FROM users
     WHERE COALESCE(BTRIM(avatar_url), '') <> ''`,
    "users.avatar_url",
  );
  for (const row of userAvatarRows) {
    pushEntry(entries, skipped, {
      kind: "user_avatar",
      recordId: row.record_id,
      field: "avatar_url",
      originalUrl: row.original_url,
    });
  }

  const chatAvatarRows = await queryRows(
    `SELECT id::text AS record_id,
            settings->>'avatar_url' AS original_url
     FROM chats
     WHERE COALESCE(BTRIM(settings->>'avatar_url'), '') <> ''`,
    "chats.settings.avatar_url",
  );
  for (const row of chatAvatarRows) {
    pushEntry(entries, skipped, {
      kind: "chat_avatar",
      recordId: row.record_id,
      field: "settings.avatar_url",
      originalUrl: row.original_url,
    });
  }

  const claimRows = await queryRows(
    `SELECT id::text AS record_id,
            image_url AS original_url
     FROM customer_claims
     WHERE COALESCE(BTRIM(image_url), '') <> ''`,
    "customer_claims.image_url",
  );
  for (const row of claimRows) {
    pushEntry(entries, skipped, {
      kind: "claim_image",
      recordId: row.record_id,
      field: "image_url",
      originalUrl: row.original_url,
    });
  }

  const attachmentStorageRows = await queryRows(
    `SELECT id::text AS record_id,
            attachment_type,
            storage_url AS original_url
     FROM message_attachments
     WHERE COALESCE(BTRIM(storage_url), '') <> ''
       AND NOT (
         processing_state = 'failed'
         AND COALESCE(extra_meta->>'recovery_missing', '') = 'true'
       )`,
    "message_attachments.storage_url",
  );
  for (const row of attachmentStorageRows) {
    pushEntry(entries, skipped, {
      kind: "attachment_storage",
      recordId: row.record_id,
      field: "storage_url",
      originalUrl: row.original_url,
      extra: {
        attachment_type: cleanString(row.attachment_type).toLowerCase(),
      },
    });
  }

  const attachmentPreviewRows = await queryRows(
    `SELECT id::text AS record_id,
            attachment_type,
            preview_image_url AS original_url
     FROM message_attachments
     WHERE COALESCE(BTRIM(preview_image_url), '') <> ''
       AND NOT (
         processing_state = 'failed'
         AND COALESCE(extra_meta->>'recovery_missing', '') = 'true'
       )`,
    "message_attachments.preview_image_url",
  );
  for (const row of attachmentPreviewRows) {
    pushEntry(entries, skipped, {
      kind: "attachment_preview",
      recordId: row.record_id,
      field: "preview_image_url",
      originalUrl: row.original_url,
      extra: {
        attachment_type: cleanString(row.attachment_type).toLowerCase(),
      },
    });
  }

  const messageProductImageRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'product_image_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'product_image_url'), '') <> ''`,
    "messages.meta.product_image_url",
  );
  for (const row of messageProductImageRows) {
    pushEntry(entries, skipped, {
      kind: "message_product_image",
      recordId: row.record_id,
      field: "meta.product_image_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
      },
    });
  }

  const messageImageRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'image_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind,
            CASE WHEN ${productLikeMessageKindExpression()} THEN true ELSE false END AS is_product_like
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'image_url'), '') <> ''`,
    "messages.meta.image_url",
  );
  for (const row of messageImageRows) {
    pushEntry(entries, skipped, {
      kind: row.is_product_like ? "message_product_image" : "message_chat_image",
      recordId: row.record_id,
      field: "meta.image_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
        is_product_like: row.is_product_like === true,
      },
    });
  }

  const messagePreviewRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'preview_image_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'preview_image_url'), '') <> ''`,
    "messages.meta.preview_image_url",
  );
  for (const row of messagePreviewRows) {
    pushEntry(entries, skipped, {
      kind: "message_preview_image",
      recordId: row.record_id,
      field: "meta.preview_image_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
      },
    });
  }

  const messageVideoPreviewRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'video_preview_image_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'video_preview_image_url'), '') <> ''`,
    "messages.meta.video_preview_image_url",
  );
  for (const row of messageVideoPreviewRows) {
    pushEntry(entries, skipped, {
      kind: "message_video_preview_image",
      recordId: row.record_id,
      field: "meta.video_preview_image_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
      },
    });
  }

  const messageVoiceRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'voice_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'voice_url'), '') <> ''`,
    "messages.meta.voice_url",
  );
  for (const row of messageVoiceRows) {
    pushEntry(entries, skipped, {
      kind: "message_voice_media",
      recordId: row.record_id,
      field: "meta.voice_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
      },
    });
  }

  const messageVideoRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'video_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'video_url'), '') <> ''`,
    "messages.meta.video_url",
  );
  for (const row of messageVideoRows) {
    pushEntry(entries, skipped, {
      kind: "message_video_media",
      recordId: row.record_id,
      field: "meta.video_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
      },
    });
  }

  const messageFileRows = await queryRows(
    `SELECT id::text AS record_id,
            meta->>'file_url' AS original_url,
            lower(COALESCE(meta->>'kind', '')) AS message_kind
     FROM messages
     WHERE COALESCE(BTRIM(meta->>'file_url'), '') <> ''`,
    "messages.meta.file_url",
  );
  for (const row of messageFileRows) {
    pushEntry(entries, skipped, {
      kind: "message_file_media",
      recordId: row.record_id,
      field: "meta.file_url",
      originalUrl: row.original_url,
      extra: {
        message_kind: cleanString(row.message_kind),
      },
    });
  }

  const deduped = [];
  const seen = new Set();
  for (const entry of entries) {
    const key = [entry.kind, entry.record_id, entry.field, entry.original_url].join("|");
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(entry);
  }

  const filtered = args.missingOnly
    ? deduped.filter((entry) => entry.status === "missing")
    : deduped;
  const summary = summaryFromManifest(filtered);
  const payload = {
    generated_at: new Date().toISOString(),
    uploads_root: uploadsRoot,
    missing_only: args.missingOnly,
    entry_count: filtered.length,
    skipped_count: skipped.length,
    summary,
    entries: filtered,
    skipped,
  };

  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(
    args.output,
    JSON.stringify(payload, null, args.pretty ? 2 : 0),
  );

  console.log(`[uploads_recovery_audit] wrote ${filtered.length} entries -> ${args.output}`);
  console.log(JSON.stringify(summary, null, 2));
  if (skipped.length > 0) {
    console.log(`[uploads_recovery_audit] skipped unsupported/external urls: ${skipped.length}`);
  }
}

main()
  .catch((err) => {
    console.error("[uploads_recovery_audit] fatal", err);
    process.exit(1);
  })
  .finally(async () => {
    try {
      await db.platformPool.end();
    } catch (_) {}
  });
