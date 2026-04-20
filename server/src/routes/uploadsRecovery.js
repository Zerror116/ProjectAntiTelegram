const express = require("express");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const multer = require("multer");

const router = express.Router();
const db = require("../db");
const { authMiddleware } = require("../utils/auth");
const {
  cleanString,
  fileExists,
  ensureParentDir,
  applySafePermissions,
} = require("../utils/uploadRecovery");
const { uploadsPath } = require("../utils/storagePaths");

const recoveryTempDir = uploadsPath("recovery_tmp");
fs.mkdirSync(recoveryTempDir, { recursive: true });

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, recoveryTempDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(String(file.originalname || "")).toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : ".bin";
      cb(
        null,
        `recovery-${Date.now()}-${crypto.randomUUID()}${safeExt}`,
      );
    },
  }),
  limits: {
    fileSize: Math.max(
      8 * 1024 * 1024,
      Number(process.env.UPLOADS_RECOVERY_MAX_BYTES || 128 * 1024 * 1024),
    ),
  },
});

function removeUploadedFile(file) {
  if (!file?.path) return;
  fs.unlink(file.path, () => {});
}

function parseUpload(req, res, next) {
  upload.single("file")(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === "LIMIT_FILE_SIZE") {
      return res.status(400).json({
        ok: false,
        error: "Файл слишком большой для recovery upload",
      });
    }
    return res.status(400).json({
      ok: false,
      error: err?.message || "Не удалось принять recovery файл",
    });
  });
}

function buildTaskId(entry) {
  return crypto
    .createHash("sha256")
    .update(
      [
        cleanString(entry.kind),
        cleanString(entry.record_id),
        cleanString(entry.field),
        cleanString(entry.relative_upload_path),
      ].join("::"),
    )
    .digest("hex")
    .slice(0, 32);
}

function expectedExt(entry) {
  return path.extname(cleanString(entry.expected_filename)).toLowerCase();
}

function parseEpochFromFilename(fileName) {
  const match = cleanString(fileName).match(/^(\d{10,})-/);
  if (!match) return null;
  const value = Number(match[1]);
  if (!Number.isFinite(value) || value <= 0) return null;
  return value;
}

function loadRecoveryManifest() {
  const candidates = [
    cleanString(process.env.UPLOADS_RECOVERY_MANIFEST_PATH),
    "/root/uploads-recovery-manifest.after-placeholders.json",
    path.resolve(__dirname, "..", "..", "tmp", "uploads-recovery-manifest.after-placeholders.prod.json"),
    path.resolve(__dirname, "..", "..", "tmp", "uploads-recovery-manifest.after-placeholders.json"),
  ].filter(Boolean);

  for (const candidate of candidates) {
    try {
      if (!fs.existsSync(candidate)) continue;
      const parsed = JSON.parse(fs.readFileSync(candidate, "utf8"));
      const entries = Array.isArray(parsed?.entries)
        ? parsed.entries
        : Array.isArray(parsed)
          ? parsed
          : [];
      return {
        path: candidate,
        entries: entries.filter((entry) => entry && typeof entry === "object"),
      };
    } catch (_) {
      // try next candidate
    }
  }
  return { path: "", entries: [] };
}

async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  await new Promise((resolve, reject) => {
    const stream = fs.createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", resolve);
  });
  return hash.digest("hex");
}

function fieldKey(entry) {
  const field = cleanString(entry.field);
  if (field.startsWith("meta.")) return field.slice(5);
  if (field.startsWith("settings.")) return field.slice(9);
  return field;
}

function cloneJson(value) {
  return value && typeof value === "object" ? JSON.parse(JSON.stringify(value)) : {};
}

function buildEntryTask(entry, extra = {}) {
  const expectedFilename = cleanString(entry.expected_filename);
  const originalFileName = cleanString(extra.original_file_name);
  const checksumSha256 = cleanString(extra.checksum_sha256).toLowerCase();
  let matchMode = "best_effort";
  if (originalFileName && checksumSha256) {
    matchMode = "exact_original_name_sha256";
  } else if (originalFileName) {
    matchMode = "exact_original_name";
  } else if (checksumSha256) {
    matchMode = "checksum_only";
  }
  return {
    id: buildTaskId(entry),
    kind: cleanString(entry.kind),
    record_id: cleanString(entry.record_id),
    field: cleanString(entry.field),
    relative_upload_path: cleanString(entry.relative_upload_path),
    expected_filename: expectedFilename,
    expected_extension: expectedExt(entry),
    original_file_name: originalFileName || null,
    checksum_sha256: checksumSha256 || null,
    original_url: cleanString(entry.original_url),
    expected_path: cleanString(entry.expected_path),
    uploaded_at_epoch_ms: parseEpochFromFilename(expectedFilename),
    match_mode: matchMode,
    hints: {
      ...extra,
      original_file_name: undefined,
      checksum_sha256: undefined,
    },
  };
}

async function loadAuthorizedTaskEntries(user) {
  const manifest = loadRecoveryManifest();
  const unresolved = manifest.entries.filter(
    (entry) => !fileExists(cleanString(entry.expected_path)),
  );
  if (!unresolved.length) {
    return { manifestPath: manifest.path, tasks: [] };
  }

  const userId = cleanString(user?.id);
  if (!userId) {
    return { manifestPath: manifest.path, tasks: [] };
  }

  const isCreator = cleanString(user?.role).toLowerCase() === 'creator';
  if (isCreator) {
    return {
      manifestPath: manifest.path,
      tasks: unresolved
        .map((entry) => buildEntryTask(entry, {}))
        .filter((entry) => entry && typeof entry === 'object'),
    };
  }

  const byKind = new Map();
  for (const entry of unresolved) {
    const kind = cleanString(entry.kind);
    const current = byKind.get(kind) || [];
    current.push(entry);
    byKind.set(kind, current);
  }

  const tasks = [];

  const productEntries = byKind.get("product_image") || [];
  if (productEntries.length > 0) {
    const ids = Array.from(
      new Set(productEntries.map((entry) => cleanString(entry.record_id)).filter(Boolean)),
    );
    if (ids.length > 0) {
      const result = await db.query(
        `SELECT id::text AS record_id,
                title,
                created_at,
                created_by::text AS created_by
         FROM products
         WHERE id = ANY($1::uuid[])
           AND created_by = $2::uuid`,
        [ids, userId],
      );
      const rowsById = new Map(result.rows.map((row) => [cleanString(row.record_id), row]));
      for (const entry of productEntries) {
        const row = rowsById.get(cleanString(entry.record_id));
        if (!row) continue;
        tasks.push(
          buildEntryTask(entry, {
            title: cleanString(row.title),
            record_created_at: row.created_at,
            created_by: cleanString(row.created_by),
          }),
        );
      }
    }
  }

  const userAvatarEntries = byKind.get("user_avatar") || [];
  for (const entry of userAvatarEntries) {
    if (cleanString(entry.record_id) !== userId) continue;
    tasks.push(buildEntryTask(entry, { record_created_at: null, created_by: userId }));
  }

  const chatAvatarEntries = byKind.get("chat_avatar") || [];
  if (chatAvatarEntries.length > 0) {
    const ids = Array.from(
      new Set(chatAvatarEntries.map((entry) => cleanString(entry.record_id)).filter(Boolean)),
    );
    if (ids.length > 0) {
      const result = await db.query(
        `SELECT id::text AS record_id,
                title,
                created_at,
                created_by::text AS created_by
         FROM chats
         WHERE id = ANY($1::uuid[])
           AND created_by = $2::uuid`,
        [ids, userId],
      );
      const rowsById = new Map(result.rows.map((row) => [cleanString(row.record_id), row]));
      for (const entry of chatAvatarEntries) {
        const row = rowsById.get(cleanString(entry.record_id));
        if (!row) continue;
        tasks.push(
          buildEntryTask(entry, {
            title: cleanString(row.title),
            record_created_at: row.created_at,
            created_by: cleanString(row.created_by),
          }),
        );
      }
    }
  }

  const claimEntries = byKind.get("claim_image") || [];
  if (claimEntries.length > 0) {
    const ids = Array.from(
      new Set(claimEntries.map((entry) => cleanString(entry.record_id)).filter(Boolean)),
    );
    if (ids.length > 0) {
      const result = await db.query(
        `SELECT id::text AS record_id,
                title,
                created_at,
                user_id::text AS owner_user_id
         FROM customer_claims
         WHERE id = ANY($1::uuid[])
           AND user_id = $2::uuid`,
        [ids, userId],
      );
      const rowsById = new Map(result.rows.map((row) => [cleanString(row.record_id), row]));
      for (const entry of claimEntries) {
        const row = rowsById.get(cleanString(entry.record_id));
        if (!row) continue;
        tasks.push(
          buildEntryTask(entry, {
            title: cleanString(row.title),
            record_created_at: row.created_at,
            created_by: cleanString(row.owner_user_id),
          }),
        );
      }
    }
  }

  const attachmentEntryGroups = [
    { kind: "attachment_storage", field: "storage_url" },
    { kind: "attachment_preview", field: "preview_image_url" },
  ];
  for (const group of attachmentEntryGroups) {
    const entries = byKind.get(group.kind) || [];
    if (!entries.length) continue;
    const ids = Array.from(
      new Set(entries.map((entry) => cleanString(entry.record_id)).filter(Boolean)),
    );
    if (!ids.length) continue;
    const result = await db.query(
      `SELECT ma.*, 
              ma.id::text AS record_id,
              m.id::text AS message_id,
              m.sender_id::text AS sender_id
       FROM message_attachments ma
       JOIN messages m ON m.id = ma.message_id
       WHERE ma.id = ANY($1::uuid[])
         AND m.sender_id = $2::uuid`,
      [ids, userId],
    );
    const rowsById = new Map(result.rows.map((row) => [cleanString(row.record_id), row]));
    for (const entry of entries) {
      const row = rowsById.get(cleanString(entry.record_id));
      if (!row) continue;
      tasks.push(
        buildEntryTask(entry, {
          attachment_type: cleanString(row.attachment_type),
          original_file_name: cleanString(row.original_file_name),
          checksum_sha256: cleanString(row.checksum_sha256),
          record_created_at: row.created_at,
          message_id: cleanString(row.message_id),
          created_by: cleanString(row.sender_id),
        }),
      );
    }
  }

  const messageKinds = [
    "message_product_image",
    "message_chat_image",
    "message_preview_image",
    "message_video_preview_image",
    "message_voice_media",
    "message_video_media",
    "message_file_media",
  ];
  const messageEntries = messageKinds.flatMap((kind) => byKind.get(kind) || []);
  if (messageEntries.length > 0) {
    const ids = Array.from(
      new Set(messageEntries.map((entry) => cleanString(entry.record_id)).filter(Boolean)),
    );
    if (ids.length > 0) {
      const result = await db.query(
        `SELECT id::text AS record_id,
                lower(COALESCE(meta->>'kind', '')) AS message_kind,
                created_at,
                sender_id::text AS sender_id,
                meta
         FROM messages
         WHERE id = ANY($1::uuid[])
           AND sender_id = $2::uuid`,
        [ids, userId],
      );
      const rowsById = new Map(result.rows.map((row) => [cleanString(row.record_id), row]));
      for (const entry of messageEntries) {
        const row = rowsById.get(cleanString(entry.record_id));
        if (!row) continue;
        const meta = row.meta && typeof row.meta === "object" ? row.meta : {};
        const originalFileName =
          cleanString(meta.file_name) ||
          cleanString(meta.video_file_name) ||
          cleanString(meta.voice_file_name);
        tasks.push(
          buildEntryTask(entry, {
            title: cleanString(meta.product_title) || cleanString(meta.title),
            message_kind: cleanString(row.message_kind),
            record_created_at: row.created_at,
            original_file_name: originalFileName,
            created_by: cleanString(row.sender_id),
          }),
        );
      }
    }
  }

  tasks.sort((a, b) => {
    const aMode = a.match_mode.startsWith("exact") ? 0 : a.match_mode === "checksum_only" ? 1 : 2;
    const bMode = b.match_mode.startsWith("exact") ? 0 : b.match_mode === "checksum_only" ? 1 : 2;
    if (aMode != bMode) return aMode - bMode;
    const aTs = Number(a.uploaded_at_epoch_ms || 0);
    const bTs = Number(b.uploaded_at_epoch_ms || 0);
    return bTs - aTs;
  });

  return { manifestPath: manifest.path, tasks };
}

async function resolveAuthorizedTaskForUser(user, taskId) {
  const loaded = await loadAuthorizedTaskEntries(user);
  const normalizedTaskId = cleanString(taskId);
  const task = loaded.tasks.find((entry) => cleanString(entry.id) === normalizedTaskId);
  return {
    manifestPath: loaded.manifestPath,
    task: task || null,
  };
}

async function relinkSingleRecoveredEntry(client, entry) {
  const kind = cleanString(entry.kind);
  const recordId = cleanString(entry.record_id);
  const originalUrl = cleanString(entry.original_url);
  if (!recordId || !originalUrl) return { relinked: false };

  if (kind === "product_image") {
    const result = await client.query(
      `UPDATE products SET image_url = $2, updated_at = now() WHERE id = $1`,
      [recordId, originalUrl],
    );
    return { relinked: result.rowCount > 0 };
  }
  if (kind === "user_avatar") {
    const result = await client.query(
      `UPDATE users SET avatar_url = $2, updated_at = now() WHERE id = $1`,
      [recordId, originalUrl],
    );
    return { relinked: result.rowCount > 0 };
  }
  if (kind === "chat_avatar") {
    const result = await client.query(
      `UPDATE chats
       SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{avatar_url}', to_jsonb($2::text), true),
           updated_at = now()
       WHERE id = $1`,
      [recordId, originalUrl],
    );
    return { relinked: result.rowCount > 0 };
  }
  if (kind === "claim_image") {
    const result = await client.query(
      `UPDATE customer_claims SET image_url = $2, updated_at = now() WHERE id = $1`,
      [recordId, originalUrl],
    );
    return { relinked: result.rowCount > 0 };
  }
  if (kind === "attachment_storage") {
    const result = await client.query(
      `UPDATE message_attachments
       SET storage_url = $2,
           processing_state = 'ready',
           extra_meta = COALESCE(extra_meta, '{}'::jsonb) - 'recovery_missing' - 'recovery_missing_at' - 'recovery_placeholder_kind'
       WHERE id = $1`,
      [recordId, originalUrl],
    );
    return { relinked: result.rowCount > 0 };
  }
  if (kind === "attachment_preview") {
    const result = await client.query(
      `UPDATE message_attachments
       SET preview_image_url = $2,
           processing_state = 'ready',
           extra_meta = COALESCE(extra_meta, '{}'::jsonb) - 'recovery_missing' - 'recovery_missing_at' - 'recovery_placeholder_kind'
       WHERE id = $1`,
      [recordId, originalUrl],
    );
    return { relinked: result.rowCount > 0 };
  }

  const field = fieldKey(entry);
  if (kind.startsWith("message_") && field) {
    const current = await client.query(
      `SELECT meta FROM messages WHERE id = $1 LIMIT 1`,
      [recordId],
    );
    if (current.rowCount === 0) return { relinked: false };
    const meta =
      current.rows[0]?.meta && typeof current.rows[0].meta === "object"
        ? cloneJson(current.rows[0].meta)
        : {};
    meta[field] = originalUrl;
    meta.attachment_processing_state = "ready";
    delete meta.recovery_missing;
    delete meta.recovery_missing_at;
    delete meta.recovery_placeholder_kind;
    const result = await client.query(
      `UPDATE messages SET meta = $2::jsonb WHERE id = $1`,
      [recordId, JSON.stringify(meta)],
    );
    return { relinked: result.rowCount > 0 };
  }

  return { relinked: false };
}

router.get("/tasks", authMiddleware, async (req, res) => {
  try {
    const limit = Math.max(1, Math.min(1000, Number(req.query.limit || 200) || 200));
    const loaded = await loadAuthorizedTaskEntries(req.user);
    const tasks = loaded.tasks.slice(0, limit);
    return res.json({
      ok: true,
      data: {
        manifest_path: loaded.manifestPath || null,
        total: loaded.tasks.length,
        exact_total: loaded.tasks.filter((task) => String(task.match_mode).startsWith("exact")).length,
        tasks,
      },
    });
  } catch (err) {
    console.error("uploadsRecovery.tasks error", err);
    return res.status(500).json({ ok: false, error: "Не удалось загрузить recovery tasks" });
  }
});

router.post("/upload", authMiddleware, parseUpload, async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ ok: false, error: "Файл обязателен" });
  }
  const taskId = cleanString(req.body?.task_id);
  if (!taskId) {
    removeUploadedFile(req.file);
    return res.status(400).json({ ok: false, error: "task_id обязателен" });
  }

  try {
    const { task } = await resolveAuthorizedTaskForUser(req.user, taskId);
    if (!task) {
      removeUploadedFile(req.file);
      return res.status(404).json({ ok: false, error: "Recovery task не найден" });
    }

    const expectedPath = cleanString(task.expected_path);
    if (!expectedPath) {
      removeUploadedFile(req.file);
      return res.status(400).json({ ok: false, error: "Некорректный recovery task" });
    }

    const expectedExtension = expectedExt(task);
    const uploadedExt = path.extname(String(req.file.originalname || req.file.filename || "")).toLowerCase();
    if (expectedExtension && uploadedExt && expectedExtension !== uploadedExt) {
      removeUploadedFile(req.file);
      return res.status(400).json({
        ok: false,
        error: `Ожидался файл ${expectedExtension}, получен ${uploadedExt}`,
      });
    }

    const expectedSha = cleanString(task.checksum_sha256).toLowerCase();
    const actualSha = await sha256File(req.file.path);
    if (expectedSha && actualSha !== expectedSha) {
      removeUploadedFile(req.file);
      return res.status(409).json({
        ok: false,
        error: "Checksum recovery файла не совпал",
        data: { expected_sha256: expectedSha, actual_sha256: actualSha },
      });
    }

    ensureParentDir(expectedPath);
    fs.copyFileSync(req.file.path, expectedPath);
    applySafePermissions(expectedPath);
    removeUploadedFile(req.file);

    const client = await db.connect();
    try {
      await client.query("BEGIN");
      await relinkSingleRecoveredEntry(client, task);
      await client.query("COMMIT");
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }

    return res.json({
      ok: true,
      data: {
        task_id: task.id,
        relative_upload_path: task.relative_upload_path,
        checksum_sha256: actualSha,
        relinked_to: task.original_url,
      },
    });
  } catch (err) {
    console.error("uploadsRecovery.upload error", err);
    removeUploadedFile(req.file);
    return res.status(500).json({ ok: false, error: "Не удалось восстановить оригинал" });
  }
});

module.exports = router;
