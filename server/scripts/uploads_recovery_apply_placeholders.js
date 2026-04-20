#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const db = require("../src/db");
const {
  cleanString,
  ensurePlaceholderAssets,
  summaryFromManifest,
} = require("../src/utils/uploadRecovery");

function parseArgs(argv) {
  const args = {
    manifest: "",
    publicBaseUrl: cleanString(process.env.PUBLIC_BASE_URL),
    output: "",
    dryRun: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--manifest") {
      args.manifest = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--public-base-url") {
      args.publicBaseUrl = cleanString(argv[index + 1]);
      index += 1;
      continue;
    }
    if (token === "--output") {
      args.output = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--dry-run") {
      args.dryRun = true;
      continue;
    }
    if (token === "-h" || token === "--help") {
      console.log(
        "Usage: node server/scripts/uploads_recovery_apply_placeholders.js --manifest FILE --public-base-url https://garphoenix.com [--output FILE] [--dry-run]",
      );
      process.exit(0);
    }
  }
  if (!args.manifest) throw new Error("--manifest is required");
  if (!args.publicBaseUrl) {
    throw new Error("--public-base-url is required (or set PUBLIC_BASE_URL)");
  }
  if (!args.output) args.output = args.manifest;
  return args;
}

function loadManifest(filePath) {
  const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (Array.isArray(parsed.entries)) return parsed;
  if (Array.isArray(parsed)) return { entries: parsed };
  throw new Error(`Unsupported manifest format: ${filePath}`);
}

function jsonClone(value) {
  return value && typeof value === "object"
    ? JSON.parse(JSON.stringify(value))
    : {};
}

function fieldKeyFromManifest(entry) {
  const field = cleanString(entry.field);
  if (field.startsWith("meta.")) {
    return field.slice("meta.".length);
  }
  if (field.startsWith("settings.")) {
    return field.slice("settings.".length);
  }
  return field;
}

function mergeRecoveryMeta(meta, extra = {}) {
  const next = jsonClone(meta);
  next.recovery_missing = true;
  next.recovery_placeholder_kind = cleanString(extra.placeholder_kind) || next.recovery_placeholder_kind || "generic";
  next.recovery_missing_at = new Date().toISOString();
  return next;
}

async function applyMessageMetaFallbacks(client, entries, placeholders, dryRun) {
  const grouped = new Map();
  for (const entry of entries) {
    const messageId = cleanString(entry.record_id);
    if (!messageId) continue;
    const current = grouped.get(messageId) || [];
    current.push(entry);
    grouped.set(messageId, current);
  }

  let changed = 0;
  for (const [messageId, messageEntries] of grouped.entries()) {
    const current = await client.query(
      `SELECT meta
       FROM messages
       WHERE id = $1
       LIMIT 1`,
      [messageId],
    );
    if (current.rowCount === 0) continue;
    const meta = current.rows[0]?.meta && typeof current.rows[0].meta === "object"
      ? jsonClone(current.rows[0].meta)
      : {};
    let dirty = false;

    for (const entry of messageEntries) {
      const key = fieldKeyFromManifest(entry);
      if (!key) continue;
      const currentValue = cleanString(meta[key]);
      const originalUrl = cleanString(entry.original_url);
      if (currentValue && currentValue !== originalUrl) {
        continue;
      }
      switch (cleanString(entry.kind)) {
        case "message_product_image":
          meta[key] = placeholders.product_placeholder_url;
          meta.attachment_processing_state = "failed";
          Object.assign(meta, mergeRecoveryMeta(meta, { placeholder_kind: "product" }));
          dirty = true;
          break;
        case "message_chat_image":
        case "message_preview_image":
        case "message_video_preview_image":
          meta[key] = placeholders.media_placeholder_url;
          meta.attachment_processing_state = "failed";
          Object.assign(meta, mergeRecoveryMeta(meta, { placeholder_kind: "media" }));
          dirty = true;
          break;
        case "message_voice_media":
        case "message_video_media":
        case "message_file_media":
          delete meta[key];
          if (key === "video_url") {
            delete meta.video_preview_image_url;
            delete meta.preview_image_url;
          }
          meta.attachment_processing_state = "failed";
          Object.assign(meta, mergeRecoveryMeta(meta, { placeholder_kind: "missing_media" }));
          dirty = true;
          break;
        default:
          break;
      }
    }

    if (!dirty) continue;
    changed += 1;
    if (!dryRun) {
      await client.query(
        `UPDATE messages
         SET meta = $2::jsonb
         WHERE id = $1`,
        [messageId, JSON.stringify(meta)],
      );
    }
  }
  return changed;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifest = loadManifest(args.manifest);
  const unresolved = (manifest.entries || []).filter(
    (entry) => cleanString(entry.status) === "missing",
  );

  const placeholders = ensurePlaceholderAssets(args.publicBaseUrl);
  const client = await db.platformConnect();
  const stats = {
    product_images: 0,
    user_avatars: 0,
    chat_avatars: 0,
    claim_images: 0,
    attachment_rows: 0,
    message_meta_rows: 0,
  };

  try {
    await client.query("BEGIN");

    for (const entry of unresolved) {
      const kind = cleanString(entry.kind);
      const recordId = cleanString(entry.record_id);
      const originalUrl = cleanString(entry.original_url);
      if (!recordId || !originalUrl) continue;

      if (kind === "product_image") {
        const result = await client.query(
          `UPDATE products
           SET image_url = $2,
               updated_at = now()
           WHERE id = $1
             AND COALESCE(BTRIM(image_url), '') = $3`,
          [recordId, placeholders.product_placeholder_url, originalUrl],
        );
        stats.product_images += result.rowCount;
        continue;
      }

      if (kind === "user_avatar") {
        const result = await client.query(
          `UPDATE users
           SET avatar_url = NULL,
               updated_at = now()
           WHERE id = $1
             AND COALESCE(BTRIM(avatar_url), '') = $2`,
          [recordId, originalUrl],
        );
        stats.user_avatars += result.rowCount;
        continue;
      }

      if (kind === "chat_avatar") {
        const result = await client.query(
          `UPDATE chats
           SET settings = settings - 'avatar_url',
               updated_at = now()
           WHERE id = $1
             AND COALESCE(BTRIM(settings->>'avatar_url'), '') = $2`,
          [recordId, originalUrl],
        );
        stats.chat_avatars += result.rowCount;
        continue;
      }

      if (kind === "claim_image") {
        const result = await client.query(
          `UPDATE customer_claims
           SET image_url = NULL,
               updated_at = now()
           WHERE id = $1
             AND COALESCE(BTRIM(image_url), '') = $2`,
          [recordId, originalUrl],
        );
        stats.claim_images += result.rowCount;
        continue;
      }
    }

    const attachmentIds = Array.from(
      new Set(
        unresolved
          .filter((entry) => ["attachment_storage", "attachment_preview"].includes(cleanString(entry.kind)))
          .map((entry) => cleanString(entry.record_id))
          .filter(Boolean),
      ),
    );
    if (attachmentIds.length > 0) {
      const attachmentUpdate = await client.query(
        `UPDATE message_attachments
         SET processing_state = 'failed',
             preview_image_url = NULL,
             extra_meta = COALESCE(extra_meta, '{}'::jsonb)
               || jsonb_build_object(
                    'recovery_missing', true,
                    'recovery_missing_at', now()::text,
                    'recovery_placeholder_kind', 'missing_media'
                  )
         WHERE id = ANY($1::uuid[])`,
        [attachmentIds],
      );
      stats.attachment_rows += attachmentUpdate.rowCount;
    }

    stats.message_meta_rows = await applyMessageMetaFallbacks(
      client,
      unresolved.filter((entry) => cleanString(entry.field).startsWith("meta.")),
      placeholders,
      args.dryRun,
    );

    if (args.dryRun) {
      await client.query("ROLLBACK");
    } else {
      await client.query("COMMIT");
    }
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }

  manifest.generated_at = new Date().toISOString();
  manifest.placeholder_run = {
    dry_run: args.dryRun,
    public_base_url: args.publicBaseUrl,
    placeholders,
    summary_before: summaryFromManifest(manifest.entries || []),
    applied: stats,
  };
  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, JSON.stringify(manifest, null, 2));
  console.log(`[uploads_recovery_apply_placeholders] dry_run=${args.dryRun} wrote ${args.output}`);
  console.log(JSON.stringify(stats, null, 2));
}

main()
  .catch((err) => {
    console.error("[uploads_recovery_apply_placeholders] fatal", err);
    process.exit(1);
  })
  .finally(async () => {
    try {
      await db.platformPool.end();
    } catch (_) {}
  });
