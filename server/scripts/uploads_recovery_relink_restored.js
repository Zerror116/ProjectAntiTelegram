#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const db = require("../src/db");
const { cleanString, fileExists } = require("../src/utils/uploadRecovery");

function parseArgs(argv) {
  const args = {
    manifest: "",
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
      console.log("Usage: node server/scripts/uploads_recovery_relink_restored.js --manifest FILE [--output FILE] [--dry-run]");
      process.exit(0);
    }
  }
  if (!args.manifest) throw new Error("--manifest is required");
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
  return value && typeof value === "object" ? JSON.parse(JSON.stringify(value)) : {};
}

function fieldKey(entry) {
  const field = cleanString(entry.field);
  if (field.startsWith("meta.")) return field.slice(5);
  if (field.startsWith("settings.")) return field.slice(9);
  return field;
}

async function relinkMessageMeta(client, entries, dryRun) {
  const grouped = new Map();
  for (const entry of entries) {
    const id = cleanString(entry.record_id);
    if (!id) continue;
    const current = grouped.get(id) || [];
    current.push(entry);
    grouped.set(id, current);
  }
  let changed = 0;
  for (const [messageId, list] of grouped.entries()) {
    const current = await client.query(`SELECT meta FROM messages WHERE id = $1 LIMIT 1`, [messageId]);
    if (current.rowCount === 0) continue;
    const meta = current.rows[0]?.meta && typeof current.rows[0].meta === "object" ? jsonClone(current.rows[0].meta) : {};
    let dirty = false;
    for (const entry of list) {
      if (!fileExists(cleanString(entry.expected_path))) continue;
      const key = fieldKey(entry);
      if (!key) continue;
      meta[key] = cleanString(entry.original_url);
      if (["image_url", "preview_image_url", "video_preview_image_url", "voice_url", "video_url", "file_url", "product_image_url"].includes(key)) {
        meta.attachment_processing_state = "ready";
      }
      delete meta.recovery_missing;
      delete meta.recovery_missing_at;
      delete meta.recovery_placeholder_kind;
      dirty = true;
    }
    if (!dirty) continue;
    changed += 1;
    if (!dryRun) {
      await client.query(`UPDATE messages SET meta = $2::jsonb WHERE id = $1`, [messageId, JSON.stringify(meta)]);
    }
  }
  return changed;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifest = loadManifest(args.manifest);
  const entries = (manifest.entries || []).filter((entry) => fileExists(cleanString(entry.expected_path)));
  const stats = {
    product_images: 0,
    user_avatars: 0,
    chat_avatars: 0,
    claim_images: 0,
    attachment_rows: 0,
    message_meta_rows: 0,
  };

  const client = await db.platformConnect();
  try {
    await client.query("BEGIN");

    for (const entry of entries) {
      const kind = cleanString(entry.kind);
      const recordId = cleanString(entry.record_id);
      const originalUrl = cleanString(entry.original_url);
      if (!recordId || !originalUrl) continue;

      if (kind === "product_image") {
        const result = await client.query(`UPDATE products SET image_url = $2, updated_at = now() WHERE id = $1`, [recordId, originalUrl]);
        stats.product_images += result.rowCount;
        continue;
      }
      if (kind === "user_avatar") {
        const result = await client.query(`UPDATE users SET avatar_url = $2, updated_at = now() WHERE id = $1`, [recordId, originalUrl]);
        stats.user_avatars += result.rowCount;
        continue;
      }
      if (kind === "chat_avatar") {
        const result = await client.query(`UPDATE chats SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{avatar_url}', to_jsonb($2::text), true), updated_at = now() WHERE id = $1`, [recordId, originalUrl]);
        stats.chat_avatars += result.rowCount;
        continue;
      }
      if (kind === "claim_image") {
        const result = await client.query(`UPDATE customer_claims SET image_url = $2, updated_at = now() WHERE id = $1`, [recordId, originalUrl]);
        stats.claim_images += result.rowCount;
        continue;
      }
    }

    const attachmentStorage = entries.filter((entry) => cleanString(entry.kind) === 'attachment_storage');
    const attachmentPreview = entries.filter((entry) => cleanString(entry.kind) === 'attachment_preview');
    const attachmentMap = new Map();
    for (const entry of [...attachmentStorage, ...attachmentPreview]) {
      const id = cleanString(entry.record_id);
      if (!id) continue;
      const payload = attachmentMap.get(id) || {};
      if (cleanString(entry.kind) === 'attachment_storage') payload.storage_url = cleanString(entry.original_url);
      if (cleanString(entry.kind) === 'attachment_preview') payload.preview_image_url = cleanString(entry.original_url);
      attachmentMap.set(id, payload);
    }
    for (const [attachmentId, payload] of attachmentMap.entries()) {
      stats.attachment_rows += 1;
      if (!args.dryRun) {
        await client.query(
          `UPDATE message_attachments
           SET storage_url = COALESCE($2, storage_url),
               preview_image_url = COALESCE($3, preview_image_url),
               processing_state = 'ready',
               extra_meta = COALESCE(extra_meta, '{}'::jsonb) - 'recovery_missing' - 'recovery_missing_at' - 'recovery_placeholder_kind'
           WHERE id = $1`,
          [attachmentId, payload.storage_url || null, payload.preview_image_url || null],
        );
      }
    }

    stats.message_meta_rows = await relinkMessageMeta(
      client,
      entries.filter((entry) => cleanString(entry.field).startsWith('meta.')),
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
  manifest.relink_run = {
    dry_run: args.dryRun,
    relinked: stats,
  };
  fs.writeFileSync(args.output, JSON.stringify(manifest, null, 2));
  console.log(`[uploads_recovery_relink_restored] dry_run=${args.dryRun} wrote ${args.output}`);
  console.log(JSON.stringify(stats, null, 2));
}

main()
  .catch((err) => {
    console.error('[uploads_recovery_relink_restored] fatal', err);
    process.exit(1);
  })
  .finally(async () => {
    try { await db.platformPool.end(); } catch (_) {}
  });
