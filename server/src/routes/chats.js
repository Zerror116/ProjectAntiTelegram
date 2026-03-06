// server/src/routes/chats.js
const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const db = require("../db");
const { authMiddleware: requireAuth } = require("../utils/auth");
const { requireRole } = require("../utils/roles");
const { requireChatPermission } = require("../utils/permissions");
const { resolvePermissionSet, hasPermission } = require("../utils/flexibleRoles");
const { emitToTenant } = require("../utils/socket");

const chatImageUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "chat_media",
  "images",
);
const chatVoiceUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "chat_media",
  "voice",
);
fs.mkdirSync(chatImageUploadsDir, { recursive: true });
fs.mkdirSync(chatVoiceUploadsDir, { recursive: true });

const chatMediaUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, file, cb) => {
      if (file.fieldname === "image") {
        cb(null, chatImageUploadsDir);
        return;
      }
      if (file.fieldname === "voice") {
        cb(null, chatVoiceUploadsDir);
        return;
      }
      cb(new Error("Некорректный тип вложения"));
    },
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      const fallbackExt = file.fieldname === "voice" ? ".m4a" : ".jpg";
      const safeExt = ext && ext.length <= 10 ? ext : fallbackExt;
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: 16 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const mime = String(file.mimetype || "").toLowerCase().trim();
    if (file.fieldname === "image") {
      if (mime.startsWith("image/")) {
        cb(null, true);
        return;
      }
      cb(new Error("Можно загружать только изображения"));
      return;
    }
    if (file.fieldname === "voice") {
      if (mime.startsWith("audio/") || mime === "application/octet-stream") {
        cb(null, true);
        return;
      }
      cb(new Error("Можно загружать только аудиофайлы"));
      return;
    }
    cb(new Error("Некорректный тип вложения"));
  },
});

function uploadChatMedia(req, res, next) {
  chatMediaUpload.fields([
    { name: "image", maxCount: 1 },
    { name: "voice", maxCount: 1 },
  ])(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === "LIMIT_FILE_SIZE") {
      return res.status(400).json({
        ok: false,
        error: "Размер вложения не должен превышать 16MB",
      });
    }
    return res.status(400).json({
      ok: false,
      error: err.message || "Некорректный файл",
    });
  });
}

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function normalizeRole(role) {
  const normalized = String(role || "client")
    .toLowerCase()
    .trim();
  // Арендатор имеет права администратора внутри своего tenant.
  if (normalized === "tenant") return "admin";
  return normalized;
}

function normalizeVisibility(chatType, settings) {
  if (chatType !== "channel") {
    return chatType === "private" ? "private" : "public";
  }
  const visibility = String(settings.visibility || "public")
    .toLowerCase()
    .trim();
  return visibility === "private" ? "private" : "public";
}

function parseBlacklistedUserIds(settings) {
  if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
    return [];
  }
  const raw = Array.isArray(settings.blacklisted_user_ids)
    ? settings.blacklisted_user_ids
    : [];
  const unique = new Set();
  for (const item of raw) {
    const value = String(item || "").trim();
    if (!value) continue;
    unique.add(value);
  }
  return Array.from(unique);
}

function isUserBlacklisted(settings, userId) {
  const userIdText = String(userId || "").trim();
  if (!userIdText) return false;
  return parseBlacklistedUserIds(settings).includes(userIdText);
}

function isBugReportsTitle(title) {
  return (
    String(title || "")
      .toLowerCase()
      .trim() === "баг-репорты"
  );
}

function isAdminOnlyChannel(chat, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  return (
    settings?.admin_only === true ||
    kind === "bug_reports" ||
    isBugReportsTitle(chat?.title)
  );
}

function isReservedOrdersChannel(chat, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  const systemKey = String(settings?.system_key || "")
    .toLowerCase()
    .trim();
  return (
    kind === "reserved_orders" ||
    systemKey === "reserved_orders" ||
    String(chat?.title || "")
      .toLowerCase()
      .trim() === "забронированный товар"
  );
}

async function getChatAccessContext(chatId, userId, tenantId = null) {
  const chatQ = await db.query(
    `SELECT id, title, type, settings, tenant_id
     FROM chats
     WHERE id = $1
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
     LIMIT 1`,
    [chatId, tenantId || null],
  );
  if (chatQ.rowCount === 0) return null;

  const chat = chatQ.rows[0];
  const settings = normalizeSettings(chat.settings);
  const hasMembers =
    (
      await db.query("SELECT 1 FROM chat_members WHERE chat_id = $1 LIMIT 1", [
        chatId,
      ])
    ).rowCount > 0;
  const isMember =
    (
      await db.query(
        "SELECT 1 FROM chat_members WHERE chat_id = $1 AND user_id = $2 LIMIT 1",
        [chatId, userId],
      )
    ).rowCount > 0;

  return {
    chat,
    settings,
    visibility: normalizeVisibility(chat.type, settings),
    hasMembers,
    isMember,
    isBlacklisted: isUserBlacklisted(settings, userId),
  };
}

function canReadChat(context, userRole) {
  if (!context) return false;
  const role = normalizeRole(userRole);

  if (context.chat.type === "channel") {
    if (context.isBlacklisted && !isAdminOrCreator(role)) {
      return false;
    }
    const reservedOrders = isReservedOrdersChannel(
      context.chat,
      context.settings,
    );
    if (reservedOrders && role === "client") {
      return false;
    }

    const adminOnly = isAdminOnlyChannel(context.chat, context.settings);
    if (adminOnly) {
      return role === "admin" || role === "creator";
    }
    if (context.visibility === "public") return true;
    if (context.isMember) return true;
    return role === "worker" || role === "admin" || role === "creator";
  }

  if (context.hasMembers) return context.isMember;
  return true;
}

function canPostChat(context, userRole) {
  if (!context) return false;
  const role = normalizeRole(userRole);

  if (context.chat.type === "channel") {
    if (role === "client") {
      return false;
    }
    if (context.isBlacklisted && !isAdminOrCreator(role)) {
      return false;
    }
    const reservedOrders = isReservedOrdersChannel(
      context.chat,
      context.settings,
    );
    if (reservedOrders && role === "client") {
      return false;
    }

    const adminOnly = isAdminOnlyChannel(context.chat, context.settings);
    if (adminOnly) {
      return role === "admin" || role === "creator";
    }
    // В публичных каналах постит только admin/creator
    if (context.visibility === "public") {
      return role === "admin" || role === "creator";
    }
    // В приватных каналах: worker/admin/creator или участники
    if (role === "worker" || role === "admin" || role === "creator")
      return true;
    return context.isMember;
  }

  if (context.hasMembers) return context.isMember;
  // Открытые публичные чаты доступны только staff.
  // Клиенты пишут в поддержку и в приватные чаты, где они добавлены участниками.
  return role === "worker" || role === "admin" || role === "creator";
}

function isAdminOrCreator(role) {
  const normalized = normalizeRole(role);
  return normalized === "admin" || normalized === "creator";
}

function parseMeta(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function isStaffRole(role) {
  const normalized = normalizeRole(role);
  return (
    normalized === "worker" ||
    normalized === "admin" ||
    normalized === "tenant" ||
    normalized === "creator"
  );
}

function supportTicketIdFromSettings(settings) {
  const raw = String(settings?.support_ticket_id || "").trim();
  return raw || null;
}

function isSupportTicketChatContext(context) {
  if (!context || context.chat?.type === "channel") return false;
  const kind = String(context.settings?.kind || "")
    .toLowerCase()
    .trim();
  return kind === "support_ticket" || context.settings?.support_ticket === true;
}

function isSystemMessage(meta) {
  const kind = String(meta?.kind || "")
    .toLowerCase()
    .trim();
  return kind.length > 0;
}

function toChatMediaUrl(req, file) {
  if (!file || !file.filename) return null;
  if (file.fieldname === "image") {
    return `${req.protocol}://${req.get("host")}/uploads/chat_media/images/${file.filename}`;
  }
  if (file.fieldname === "voice") {
    return `${req.protocol}://${req.get("host")}/uploads/chat_media/voice/${file.filename}`;
  }
  return null;
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function removeUploadedFiles(files) {
  for (const file of files) {
    removeUploadedFile(file);
  }
}

function removeChatMediaByUrl(raw) {
  const url = String(raw || "").trim();
  if (!url) return;

  const mappings = [
    {
      marker: "/uploads/chat_media/images/",
      baseDir: chatImageUploadsDir,
    },
    {
      marker: "/uploads/chat_media/voice/",
      baseDir: chatVoiceUploadsDir,
    },
  ];

  for (const { marker, baseDir } of mappings) {
    const idx = url.indexOf(marker);
    if (idx === -1) continue;
    const filename = url.slice(idx + marker.length).split(/[?#]/)[0].trim();
    if (!filename) return;
    const fullPath = path.join(baseDir, filename);
    if (!fullPath.startsWith(baseDir)) return;
    fs.unlink(fullPath, () => {});
    return;
  }
}

async function getHydratedMessageById(messageId, currentUserId) {
  const result = await db.query(
    `SELECT m.id,
            m.client_msg_id,
            m.chat_id,
            m.sender_id,
            m.text,
            m.meta,
            m.created_at,
            COALESCE((m.sender_id::text = $2::text), false) AS from_me,
            EXISTS(
              SELECT 1
              FROM message_reads mr
              WHERE mr.message_id = m.id
                AND mr.user_id = $2::uuid
            ) AS is_read_by_me,
            EXISTS(
              SELECT 1
              FROM message_reads mr
              WHERE mr.message_id = m.id
                AND mr.user_id <> m.sender_id
            ) AS read_by_others,
            (
              SELECT COUNT(*)
              FROM message_reads mr
              WHERE mr.message_id = m.id
                AND mr.user_id <> m.sender_id
            )::int AS read_count,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
            u.email AS sender_email,
            u.avatar_url AS sender_avatar_url,
            COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
            COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
            COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
     FROM messages m
     LEFT JOIN users u ON u.id = m.sender_id
     WHERE m.id = $1
     LIMIT 1`,
    [messageId, currentUserId ? String(currentUserId) : null],
  );
  return result.rows[0] || null;
}

async function finalizeCreatedMessage(req, chatId, messageId, currentUserId) {
  const responseMessage = await getHydratedMessageById(messageId, currentUserId);
  if (!responseMessage) {
    throw new Error("Не удалось загрузить сообщение");
  }
  const broadcastMessage = await getHydratedMessageById(messageId, null);
  if (!broadcastMessage) {
    throw new Error("Не удалось подготовить событие сообщения");
  }

  await db.query("UPDATE chats SET updated_at = now() WHERE id = $1", [chatId]);

  const io = req.app.get("io");
  if (io) {
    io.to(`chat:${chatId}`).emit("chat:message", {
      chatId,
      message: broadcastMessage,
    });
    emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
  }

  return responseMessage;
}

async function syncSupportTicketOnMessage({
  chatId,
  senderId,
  senderRole,
  tenantId = null,
  supportTicketId = null,
}) {
  const ticketId = String(supportTicketId || "").trim();
  if (!ticketId) return { promptMessageId: null };

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    const ticketRes = await client.query(
      `SELECT id,
              chat_id,
              customer_id,
              assignee_id,
              assigned_role,
              status
       FROM support_tickets
       WHERE id = $1
         AND chat_id = $2
         AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
       LIMIT 1
       FOR UPDATE`,
      [ticketId, chatId, tenantId || null],
    );

    if (ticketRes.rowCount === 0) {
      await client.query("ROLLBACK");
      return { promptMessageId: null };
    }

    const ticket = ticketRes.rows[0];
    const senderIdText = String(senderId || "").trim();
    const senderRoleNormalized = normalizeRole(senderRole);
    const senderIsCustomer = String(ticket.customer_id || "") === senderIdText;
    let promptMessageId = null;

    if (senderIsCustomer) {
      await client.query(
        `UPDATE support_tickets
         SET status = 'open',
             archived_at = NULL,
             archive_reason = NULL,
             resolved_at = NULL,
             resolved_by = NULL,
             last_customer_message_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [ticket.id],
      );
    } else if (isStaffRole(senderRoleNormalized)) {
      const shouldPrompt =
        String(ticket.status || "").toLowerCase().trim() !==
        "waiting_customer";

      await client.query(
        `UPDATE support_tickets
         SET assignee_id = COALESCE(assignee_id, $1::uuid),
             assigned_role = CASE
               WHEN assignee_id IS NULL THEN $2
               ELSE assigned_role
             END,
             status = 'waiting_customer',
             archived_at = NULL,
             archive_reason = NULL,
             resolved_at = NULL,
             resolved_by = NULL,
             last_staff_message_at = now(),
             updated_at = now()
         WHERE id = $3`,
        [
          senderIdText || null,
          senderRoleNormalized || "admin",
          ticket.id,
        ],
      );

      if (shouldPrompt) {
        const promptText =
          "Поддержка ответила на ваш вопрос. Решили проблему?";
        const promptMeta = {
          kind: "support_feedback_prompt",
          support_ticket_id: ticket.id,
          feedback_status: "pending",
        };
        const inserted = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, NULL, $3, $4::jsonb, now())
           RETURNING id`,
          [uuidv4(), chatId, promptText, JSON.stringify(promptMeta)],
        );
        promptMessageId = inserted.rows[0]?.id || null;
      }
    }

    await client.query("COMMIT");
    return { promptMessageId };
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

async function insertMessageWithDedup({
  clientMsgId,
  chatId,
  senderId,
  text,
  metaJson = null,
}) {
  const hasMeta = metaJson != null;
  const insertWithConflictSql = hasMeta
    ? `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, now())
       ON CONFLICT (client_msg_id) WHERE client_msg_id IS NOT NULL DO NOTHING
       RETURNING id`
    : `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, $4, $5, now())
       ON CONFLICT (client_msg_id) WHERE client_msg_id IS NOT NULL DO NOTHING
       RETURNING id`;
  const insertWithConflictParams = hasMeta
    ? [uuidv4(), clientMsgId, chatId, senderId, text, metaJson]
    : [uuidv4(), clientMsgId, chatId, senderId, text];

  const insertDirectSql = hasMeta
    ? `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, now())
       RETURNING id`
    : `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, $4, $5, now())
       RETURNING id`;
  const insertDirectParams = hasMeta
    ? [uuidv4(), clientMsgId, chatId, senderId, text, metaJson]
    : [uuidv4(), clientMsgId, chatId, senderId, text];

  if (!clientMsgId) {
    if (hasMeta) {
      return db.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, $3, $4, $5::jsonb, now())
         RETURNING id`,
        [uuidv4(), chatId, senderId, text, metaJson],
      );
    }
    return db.query(
      `INSERT INTO messages (id, chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, $4, now())
       RETURNING id`,
      [uuidv4(), chatId, senderId, text],
    );
  }

  try {
    const inserted = await db.query(insertWithConflictSql, insertWithConflictParams);
    if (inserted.rowCount > 0) return inserted;
  } catch (err) {
    if (String(err?.code || "") !== "42P10") throw err;
  }

  const existing = await db.query(
    `SELECT id
     FROM messages
     WHERE client_msg_id = $1
     LIMIT 1`,
    [clientMsgId],
  );
  if (existing.rowCount > 0) return existing;

  return db.query(insertDirectSql, insertDirectParams);
}

async function markChatMessagesRead(chatId, userId) {
  const result = await db.query(
    `WITH unread AS (
       SELECT m.id, m.sender_id
       FROM messages m
     WHERE m.chat_id = $1
       AND m.sender_id IS NOT NULL
       AND m.sender_id <> $2
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       AND NOT EXISTS (
         SELECT 1
         FROM message_reads mr
           WHERE mr.message_id = m.id
             AND mr.user_id = $2
         )
     ),
     inserted AS (
       INSERT INTO message_reads (message_id, user_id, chat_id, read_at)
       SELECT unread.id, $2, $1, now()
       FROM unread
       ON CONFLICT (message_id, user_id) DO NOTHING
       RETURNING message_id
     )
     SELECT unread.id::text AS message_id,
            unread.sender_id::text AS sender_id
     FROM inserted i
     JOIN unread ON unread.id = i.message_id`,
    [chatId, userId],
  );
  return result.rows;
}

async function canPinInChat(user) {
  if (!user) return false;
  const role = normalizeRole(user.base_role || user.role);
  if (role === "creator" || role === "admin") return true;

  const resolved = await resolvePermissionSet(user, db);
  return hasPermission(resolved.permissions, "chat.pin");
}

async function getActivePinForUser(chatId, userId) {
  const pinQ = await db.query(
    `SELECT cp.id,
            cp.chat_id,
            cp.message_id,
            cp.pinned_by,
            cp.created_at,
            cp.updated_at,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS pinned_by_name
     FROM chat_pins cp
     JOIN messages m ON m.id = cp.message_id
     LEFT JOIN users u ON u.id = cp.pinned_by
     WHERE cp.chat_id = $1
       AND cp.is_active = true
       AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
     ORDER BY cp.updated_at DESC
     LIMIT 1`,
    [chatId, String(userId || "")],
  );
  if (pinQ.rowCount === 0) return null;
  const pin = pinQ.rows[0];
  const message = await getHydratedMessageById(pin.message_id, userId);
  if (!message) return null;
  return {
    id: pin.id,
    chat_id: pin.chat_id,
    message_id: pin.message_id,
    pinned_by: pin.pinned_by,
    pinned_by_name: pin.pinned_by_name,
    created_at: pin.created_at,
    updated_at: pin.updated_at,
    message,
  };
}

router.get("/", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const tenantId = req.user.tenant_id || null;
    const userIdText = String(userId);
    const role = normalizeRole(req.user.role);
    const workerOrHigher =
      role === "worker" || role === "admin" || role === "creator";
    const adminOrCreator = role === "admin" || role === "creator";

    const publicAndChannelQ = await db.query(
      `SELECT c.id,
              c.title,
              c.type,
              c.settings,
              last_msg.text AS last_message,
              last_msg.created_at AS updated_at,
              COALESCE(unread_stats.unread_count, 0)::int AS unread_count,
              last_msg.sender_id AS last_message_sender_id,
              COALESCE(NULLIF(BTRIM(last_user.name), ''), NULLIF(BTRIM(last_user.email), ''), 'Система') AS last_message_sender_name,
              last_user.avatar_url AS last_message_sender_avatar_url,
              COALESCE(last_user.avatar_focus_x, 0) AS last_message_sender_avatar_focus_x,
              COALESCE(last_user.avatar_focus_y, 0) AS last_message_sender_avatar_focus_y,
              COALESCE(last_user.avatar_zoom, 1) AS last_message_sender_avatar_zoom
       FROM chats c
       LEFT JOIN LATERAL (
         SELECT m.text, m.created_at, m.sender_id
         FROM messages m
         WHERE m.chat_id = c.id
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $4::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         ORDER BY m.created_at DESC
         LIMIT 1
       ) AS last_msg ON true
       LEFT JOIN LATERAL (
         SELECT COUNT(*) AS unread_count
         FROM messages um
         WHERE um.chat_id = c.id
           AND um.sender_id IS NOT NULL
           AND um.sender_id <> $1
           AND NOT (COALESCE(um.meta->'hidden_for', '[]'::jsonb) ? $4::text)
           AND COALESCE((um.meta->>'hidden_for_all')::boolean, false) = false
           AND NOT EXISTS (
             SELECT 1
             FROM message_reads mr
             WHERE mr.message_id = um.id
               AND mr.user_id = $1
           )
       ) AS unread_stats ON true
       LEFT JOIN users last_user ON last_user.id = last_msg.sender_id
       WHERE (
         (
           c.type <> 'channel'
           AND NOT EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = c.id)
         )
         OR
         (
           c.type = 'channel'
           AND (
             (
               (
                 COALESCE((c.settings->>'admin_only')::boolean, false) = true
                 OR COALESCE(c.settings->>'kind', '') = 'bug_reports'
                 OR LOWER(TRIM(c.title)) = 'баг-репорты'
               )
               AND $3::boolean = true
             )
             OR
             (
               COALESCE((c.settings->>'admin_only')::boolean, false) = false
               AND COALESCE(c.settings->>'kind', '') <> 'bug_reports'
               AND LOWER(TRIM(c.title)) <> 'баг-репорты'
               AND (
                 $2::boolean = true
                 OR (
                   COALESCE(c.settings->>'kind', '') <> 'reserved_orders'
                   AND COALESCE(c.settings->>'system_key', '') <> 'reserved_orders'
                   AND LOWER(TRIM(c.title)) <> 'забронированный товар'
                 )
               )
               AND (
                 COALESCE(c.settings->>'visibility', 'public') = 'public'
                 OR EXISTS (
                   SELECT 1 FROM chat_members cm
                   WHERE cm.chat_id = c.id AND cm.user_id = $1
                 )
                 OR $2::boolean = true
               )
               AND (
                 $3::boolean = true
                 OR NOT (
                   COALESCE(c.settings->'blacklisted_user_ids', '[]'::jsonb) ? $5::text
                 )
               )
             )
           )
         )
       )
       AND ($6::uuid IS NULL OR c.tenant_id = $6::uuid)
       AND (
         c.type <> 'channel'
         OR COALESCE((c.settings->>'hidden_in_chat_list')::boolean, false) = false
       )
       AND COALESCE(c.settings->>'kind', '') <> 'system_duplicate'
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 200`,
      [
        userId,
        workerOrHigher,
        adminOrCreator,
        userIdText,
        userIdText,
        tenantId,
      ],
    );

    const privateQ = await db.query(
      `SELECT c.id,
              c.title,
              c.type,
              c.settings,
              last_msg.text AS last_message,
              last_msg.created_at AS updated_at,
              COALESCE(unread_stats.unread_count, 0)::int AS unread_count,
              last_msg.sender_id AS last_message_sender_id,
              COALESCE(NULLIF(BTRIM(last_user.name), ''), NULLIF(BTRIM(last_user.email), ''), 'Система') AS last_message_sender_name,
              last_user.avatar_url AS last_message_sender_avatar_url,
              COALESCE(last_user.avatar_focus_x, 0) AS last_message_sender_avatar_focus_x,
              COALESCE(last_user.avatar_focus_y, 0) AS last_message_sender_avatar_focus_y,
              COALESCE(last_user.avatar_zoom, 1) AS last_message_sender_avatar_zoom
       FROM chats c
       JOIN chat_members cm ON cm.chat_id = c.id
       LEFT JOIN LATERAL (
         SELECT m.text, m.created_at, m.sender_id
         FROM messages m
         WHERE m.chat_id = c.id
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         ORDER BY m.created_at DESC
         LIMIT 1
       ) AS last_msg ON true
       LEFT JOIN LATERAL (
         SELECT COUNT(*) AS unread_count
         FROM messages um
         WHERE um.chat_id = c.id
           AND um.sender_id IS NOT NULL
           AND um.sender_id <> $1
           AND NOT (COALESCE(um.meta->'hidden_for', '[]'::jsonb) ? $2::text)
           AND COALESCE((um.meta->>'hidden_for_all')::boolean, false) = false
           AND NOT EXISTS (
             SELECT 1
             FROM message_reads mr
             WHERE mr.message_id = um.id
               AND mr.user_id = $1
           )
       ) AS unread_stats ON true
       LEFT JOIN users last_user ON last_user.id = last_msg.sender_id
       WHERE c.type <> 'channel'
         AND cm.user_id = $1
         AND ($3::uuid IS NULL OR c.tenant_id = $3::uuid)
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`,
      [userId, userIdText, tenantId],
    );

    const byId = new Map();
    for (const row of [...publicAndChannelQ.rows, ...privateQ.rows]) {
      if (!byId.has(row.id)) byId.set(row.id, row);
    }
    const chats = Array.from(byId.values());

    return res.json({ ok: true, data: chats });
  } catch (err) {
    console.error("chats.list error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

/**
 * POST /api/chats
 * Создать чат — только creator/admin
 * body: { title, type?: 'public'|'private', members?: [userId,...] }
 */
router.post(
  "/",
  requireAuth,
  requireRole("creator", "admin"),
  async (req, res) => {
    try {
      const { title, type = "public", members = [] } = req.body || {};
      if (!title || typeof title !== "string") {
        return res.status(400).json({ ok: false, error: "title required" });
      }
      const safeType = type === "private" ? "private" : "public";
      const insert = await db.query(
        `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, now(), now())
       RETURNING id, title, type, created_by, settings`,
        [
          uuidv4(),
          title,
          safeType,
          req.user.id,
          req.user.tenant_id,
          JSON.stringify({ kind: "chat" }),
        ],
      );
      const chat = insert.rows[0];

      if (safeType === "private") {
        const creatorId = req.user.id;
        const membersArr = Array.isArray(members) ? members : [];
        const toAddRaw = Array.from(new Set([creatorId, ...membersArr]));
        const allowedMembersQ = await db.query(
          `SELECT id::text AS id
           FROM users
           WHERE id::text = ANY($1::text[])
             AND ($2::uuid IS NULL OR tenant_id = $2::uuid)`,
          [toAddRaw, req.user.tenant_id || null],
        );
        const toAdd = allowedMembersQ.rows.map((row) => String(row.id || "").trim()).filter(Boolean);
        await Promise.all(
          toAdd.map((uid) =>
            db.query(
              `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
           VALUES ($1, $2, $3, now(), $4)
           ON CONFLICT (chat_id, user_id) DO NOTHING`,
              [uuidv4(), chat.id, uid, uid === creatorId ? "owner" : "member"],
            ),
          ),
        );
      }

      const io = req.app.get("io");
      if (safeType === "public" && io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:created", { chat });
      }

      return res.status(201).json({ ok: true, data: chat });
    } catch (err) {
      console.error("chats.create error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

/**
 * GET /api/chats/:chatId/messages
 */
router.get("/:chatId/messages", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const { rows } = await db.query(
      `SELECT m.id,
              m.sender_id,
              m.client_msg_id,
              m.text,
              m.meta,
              m.created_at,
              (m.sender_id::text = $2::text) AS from_me,
              EXISTS(
                SELECT 1
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id = $2::uuid
              ) AS is_read_by_me,
              EXISTS(
                SELECT 1
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              ) AS read_by_others,
              (
                SELECT COUNT(*)
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              )::int AS read_count,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
              u.email AS sender_email,
              u.avatar_url AS sender_avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
       FROM messages m
       LEFT JOIN users u ON u.id = m.sender_id
       WHERE m.chat_id = $1
         AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       ORDER BY m.created_at ASC
       LIMIT 1000`,
      [chatId, String(userId)],
    );
    return res.json({ ok: true, data: rows });
  } catch (err) {
    console.error("chats.messages error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/:chatId/pin", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const pin = await getActivePinForUser(chatId, userId);
    return res.json({ ok: true, data: pin });
  } catch (err) {
    console.error("chats.getPin error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post("/:chatId/pin/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }
    if (!(await canPinInChat(req.user))) {
      return res.status(403).json({
        ok: false,
        error: "Закреплять сообщения могут только администраторы",
      });
    }

    const messageQ = await db.query(
      `SELECT id
       FROM messages
       WHERE id = $1
         AND chat_id = $2
       LIMIT 1`,
      [messageId, chatId],
    );
    if (messageQ.rowCount === 0) {
      return res.status(404).json({
        ok: false,
        error: "Сообщение не найдено в этом чате",
      });
    }

    await db.query(
      `UPDATE chat_pins
       SET is_active = false,
           updated_at = now()
       WHERE chat_id = $1
         AND is_active = true`,
      [chatId],
    );

    await db.query(
      `INSERT INTO chat_pins (
         id,
         chat_id,
         message_id,
         pinned_by,
         is_active,
         created_at,
         updated_at
       )
       VALUES (
         gen_random_uuid(),
         $1,
         $2,
         $3,
         true,
         now(),
         now()
       )
       ON CONFLICT (chat_id, message_id)
       DO UPDATE
         SET pinned_by = EXCLUDED.pinned_by,
             is_active = true,
             updated_at = now()`,
      [chatId, messageId, userId],
    );

    const pin = await getActivePinForUser(chatId, userId);
    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:pinned", { chatId, pin });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({ ok: true, data: pin });
  } catch (err) {
    console.error("chats.pinMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.delete("/:chatId/pin", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }
    if (!(await canPinInChat(req.user))) {
      return res.status(403).json({
        ok: false,
        error: "Снимать закреп может только администратор",
      });
    }

    await db.query(
      `UPDATE chat_pins
       SET is_active = false,
           updated_at = now()
       WHERE chat_id = $1
         AND is_active = true`,
      [chatId],
    );

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:pinned", { chatId, pin: null });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({ ok: true, data: null });
  } catch (err) {
    console.error("chats.unpinMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post("/:chatId/read", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const readRows = await markChatMessagesRead(chatId, userId);
    const messageIds = readRows
      .map((row) => row.message_id)
      .filter(Boolean);

    const io = req.app.get("io");
    if (io && messageIds.length > 0) {
      const bySender = new Map();
      for (const row of readRows) {
        const senderId = String(row.sender_id || "").trim();
        const messageId = String(row.message_id || "").trim();
        if (!senderId || !messageId) continue;
        if (!bySender.has(senderId)) {
          bySender.set(senderId, []);
        }
        bySender.get(senderId).push(messageId);
      }
      for (const [senderId, senderMessageIds] of bySender.entries()) {
        io.to(`user:${senderId}`).emit("chat:message:read", {
          chatId,
          readerId: String(userId),
          messageIds: senderMessageIds,
        });
      }
    }

    return res.json({
      ok: true,
      data: {
        chat_id: chatId,
        message_ids: messageIds,
      },
    });
  } catch (err) {
    console.error("chats.markRead error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

/**
 * POST /api/chats/:chatId/messages
 * Поддержка client_msg_id для дедупликации
 */
router.post("/:chatId/messages", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;
    const { text, client_msg_id } = req.body || {};

    if (!text || !text.trim())
      return res.status(400).json({ ok: false, error: "Text required" });

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    if (!canPostChat(context, role)) {
      return res
        .status(403)
        .json({
          ok: false,
          error: "Нет прав на отправку сообщения в этот чат",
        });
    }

    const insert = await insertMessageWithDedup({
      clientMsgId: String(client_msg_id || "").trim() || null,
      chatId,
      senderId: userId,
      text: String(text),
    });

    const messageId = insert.rows[0]?.id;
    if (!messageId) {
      return res.status(500).json({ ok: false, error: "Не удалось создать сообщение" });
    }

    let promptMessageId = null;
    if (isSupportTicketChatContext(context)) {
      const ticketId = supportTicketIdFromSettings(context.settings);
      if (ticketId) {
        const synced = await syncSupportTicketOnMessage({
          chatId,
          senderId: userId,
          senderRole: role,
          tenantId: req.user.tenant_id || null,
          supportTicketId: ticketId,
        });
        promptMessageId = synced.promptMessageId || null;
      }
    }

    const responseMessage = await finalizeCreatedMessage(
      req,
      chatId,
      messageId,
      userId,
    );
    if (promptMessageId) {
      await finalizeCreatedMessage(req, chatId, promptMessageId, userId);
    }
    return res.status(201).json({ ok: true, data: responseMessage });
  } catch (err) {
    console.error("chats.postMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post(
  "/:chatId/messages/media",
  requireAuth,
  uploadChatMedia,
  async (req, res) => {
    const uploadedFiles = [
      ...((req.files?.image || []).map((file) => file)),
      ...((req.files?.voice || []).map((file) => file)),
    ];
    try {
      const userId = req.user.id;
      const role = req.user.role;
      const { chatId } = req.params;
      const caption = String(req.body?.text || "").trim();
      const clientMsgId = String(req.body?.client_msg_id || "").trim();
      const durationMsRaw = Math.floor(Number(req.body?.duration_ms || 0));
      const imageFile = req.files?.image?.[0] || null;
      const voiceFile = req.files?.voice?.[0] || null;

      if ((imageFile && voiceFile) || (!imageFile && !voiceFile)) {
        removeUploadedFiles(uploadedFiles);
        return res.status(400).json({
          ok: false,
          error: "Нужно передать либо изображение, либо голосовое сообщение",
        });
      }

      const attachmentType = imageFile ? "image" : "voice";
      const uploadedFile = imageFile || voiceFile;
      const mediaUrl = toChatMediaUrl(req, uploadedFile);
      if (!mediaUrl) {
        removeUploadedFiles(uploadedFiles);
        return res.status(400).json({
          ok: false,
          error: "Не удалось обработать вложение",
        });
      }

      const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
      if (!context) {
        removeUploadedFiles(uploadedFiles);
        return res.status(404).json({ ok: false, error: "Chat not found" });
      }
      if (!canPostChat(context, role)) {
        removeUploadedFiles(uploadedFiles);
        return res.status(403).json({
          ok: false,
          error: "Нет прав на отправку сообщения в этот чат",
        });
      }

      const durationMs = Number.isFinite(durationMsRaw) && durationMsRaw > 0
        ? durationMsRaw
        : 0;
      const hasCaption = caption.length > 0;
      const text = attachmentType === "image"
        ? (hasCaption ? caption : "Фото")
        : "Голосовое сообщение";
      const meta = {
        attachment_type: attachmentType,
        ...(hasCaption ? { caption } : {}),
        ...(attachmentType === "image"
          ? {
              image_url: mediaUrl,
            }
          : {
              voice_url: mediaUrl,
              voice_duration_ms: durationMs,
              voice_mime_type: String(uploadedFile.mimetype || "").trim(),
              voice_file_name: String(
                uploadedFile.originalname || uploadedFile.filename || "",
              ).trim(),
            }),
      };

      if (clientMsgId) {
        const existing = await db.query(
          `SELECT id
           FROM messages
           WHERE client_msg_id = $1
           LIMIT 1`,
          [clientMsgId],
        );
        if (existing.rowCount > 0) {
          removeUploadedFiles(uploadedFiles);
          const responseMessage = await finalizeCreatedMessage(
            req,
            chatId,
            existing.rows[0].id,
            userId,
          );
          return res.status(201).json({ ok: true, data: responseMessage });
        }
      }

      const insert = await insertMessageWithDedup({
        clientMsgId: clientMsgId || null,
        chatId,
        senderId: userId,
        text,
        metaJson: JSON.stringify(meta),
      });

      const messageId = insert.rows[0]?.id;
      if (!messageId) {
        removeUploadedFiles(uploadedFiles);
        return res.status(500).json({
          ok: false,
          error: "Не удалось создать сообщение",
        });
      }

      let promptMessageId = null;
      if (isSupportTicketChatContext(context)) {
        const ticketId = supportTicketIdFromSettings(context.settings);
        if (ticketId) {
          const synced = await syncSupportTicketOnMessage({
            chatId,
            senderId: userId,
            senderRole: role,
            tenantId: req.user.tenant_id || null,
            supportTicketId: ticketId,
          });
          promptMessageId = synced.promptMessageId || null;
        }
      }

      const responseMessage = await finalizeCreatedMessage(
        req,
        chatId,
        messageId,
        userId,
      );
      if (promptMessageId) {
        await finalizeCreatedMessage(req, chatId, promptMessageId, userId);
      }
      return res.status(201).json({ ok: true, data: responseMessage });
    } catch (err) {
      removeUploadedFiles(uploadedFiles);
      console.error("chats.postMediaMessage error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

/**
 * PATCH /api/chats/:chatId/messages/:messageId
 * Редактирование обычного сообщения пользователем-автором
 */
router.patch("/:chatId/messages/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;
    const nextText = String(req.body?.text || "").trim();
    if (!nextText) {
      return res.status(400).json({ ok: false, error: "Text required" });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const messageQ = await db.query(
      `SELECT id, chat_id, sender_id, text, meta, created_at
       FROM messages
       WHERE id = $1 AND chat_id = $2
       LIMIT 1`,
      [messageId, chatId],
    );
    if (messageQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
    }

    const message = messageQ.rows[0];
    const meta = parseMeta(message.meta);
    if (isSystemMessage(meta)) {
      return res.status(403).json({
        ok: false,
        error: "Системные сообщения нельзя редактировать",
      });
    }

    if (String(message.sender_id || "") !== String(userId)) {
      return res.status(403).json({
        ok: false,
        error: "Редактировать можно только свои сообщения",
      });
    }

    const upd = await db.query(
      `UPDATE messages
       SET text = $1,
           meta = jsonb_set(
             jsonb_set(COALESCE(meta, '{}'::jsonb), '{edited}', 'true'::jsonb, true),
             '{edited_at}',
             to_jsonb(now()),
             true
           )
       WHERE id = $2
       RETURNING id`,
      [nextText, messageId],
    );
    const updated = await getHydratedMessageById(upd.rows[0]?.id, userId);
    if (!updated) {
      return res.status(500).json({ ok: false, error: "Не удалось загрузить сообщение" });
    }

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:message", { chatId, message: updated });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({ ok: true, data: updated });
  } catch (err) {
    console.error("chats.editMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

/**
 * DELETE /api/chats/:chatId/messages/:messageId
 * Удаление сообщения:
 * - scope=me: скрыть только у текущего пользователя
 * - scope=all: удалить у всех
 */
router.delete("/:chatId/messages/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;
    const scope = String(req.body?.scope || "all")
      .toLowerCase()
      .trim();
    if (scope !== "me" && scope !== "all") {
      return res.status(400).json({
        ok: false,
        error: "scope должен быть me или all",
      });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const messageQ = await db.query(
      `SELECT id, chat_id, sender_id, text, meta, created_at
       FROM messages
       WHERE id = $1 AND chat_id = $2
       LIMIT 1`,
      [messageId, chatId],
    );
    if (messageQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
    }

    const message = messageQ.rows[0];
    const meta = parseMeta(message.meta);

    // Скрыть только для себя (локальное удаление)
    if (scope === "me") {
      await db.query(
        `UPDATE messages
         SET meta = jsonb_set(
           COALESCE(meta, '{}'::jsonb),
           '{hidden_for}',
           CASE
             WHEN COALESCE(meta->'hidden_for', '[]'::jsonb) ? $2::text
               THEN COALESCE(meta->'hidden_for', '[]'::jsonb)
             ELSE COALESCE(meta->'hidden_for', '[]'::jsonb) || to_jsonb($2::text)
           END,
           true
         )
         WHERE id = $1`,
        [messageId, String(userId)],
      );
      return res.json({
        ok: true,
        data: {
          message_id: messageId,
          scope: "me",
        },
      });
    }

    const kind = String(meta?.kind || "")
      .toLowerCase()
      .trim();
    const isCatalogPost = kind === "catalog_product";
    const isSystem = isSystemMessage(meta);
    const isCreator = normalizeRole(role) === "creator";

    if (isSystem && !isCatalogPost && !isCreator) {
      return res.status(403).json({
        ok: false,
        error: "Этот тип системных сообщений нельзя удалять у всех",
      });
    }

    const ownMessage = String(message.sender_id || "") === String(userId);
    const adminOrCreator = isAdminOrCreator(role);

    if (isCatalogPost) {
      if (!adminOrCreator) {
        return res.status(403).json({
          ok: false,
          error: "Посты с товарами могут удалять только admin/creator",
        });
      }
    } else if (!ownMessage && !adminOrCreator) {
      return res.status(403).json({
        ok: false,
        error: "Удалять у всех можно только свои сообщения",
      });
    }

    const deleted = await db.query(
      `DELETE FROM messages
       WHERE id = $1 AND chat_id = $2
       RETURNING id`,
      [messageId, chatId],
    );
    if (deleted.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
    }

    removeChatMediaByUrl(meta?.image_url);
    removeChatMediaByUrl(meta?.voice_url);

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:message:deleted", {
        chatId,
        messageId,
      });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({
      ok: true,
      data: {
        message_id: messageId,
        scope: "all",
      },
    });
  } catch (err) {
    console.error("chats.deleteMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.delete("/:chatId/messages", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const baseRole = String(req.user.base_role || role || "")
      .toLowerCase()
      .trim();
    const { chatId } = req.params;

    if (baseRole !== "creator") {
      return res.status(403).json({
        ok: false,
        error: "Полная очистка чата доступна только создателю",
      });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const mediaQ = await db.query(
      `SELECT meta
       FROM messages
       WHERE chat_id = $1`,
      [chatId],
    );

    for (const row of mediaQ.rows) {
      const meta = parseMeta(row.meta);
      removeChatMediaByUrl(meta?.image_url);
      removeChatMediaByUrl(meta?.voice_url);
    }

    await db.query("DELETE FROM message_reads WHERE chat_id = $1", [chatId]);
    const deleted = await db.query(
      `DELETE FROM messages
       WHERE chat_id = $1`,
      [chatId],
    );
    await db.query("UPDATE chats SET updated_at = now() WHERE id = $1", [chatId]);

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:cleared", { chatId });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({
      ok: true,
      data: {
        chat_id: chatId,
        deleted_count: deleted.rowCount || 0,
      },
    });
  } catch (err) {
    console.error("chats.clearMessages error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

// Members management endpoints
router.get("/:chatId/members", requireAuth, async (req, res) => {
  try {
    const { chatId } = req.params;
    const q = await db.query(
      `SELECT u.id as user_id, u.email, cm.role, cm.joined_at
       FROM users u
       JOIN chat_members cm ON cm.user_id = u.id
       WHERE cm.chat_id = $1
       ORDER BY cm.joined_at ASC`,
      [chatId],
    );
    return res.json({ ok: true, data: q.rows });
  } catch (err) {
    console.error("chats.members.list error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post(
  "/:chatId/members",
  requireAuth,
  requireChatPermission(["owner", "moderator"]),
  async (req, res) => {
    const { chatId } = req.params;
    const { userId, role = "member" } = req.body || {};
    if (!userId)
      return res.status(400).json({ ok: false, error: "userId required" });

    try {
      await db.query(
        `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1,$2,$3,now(),$4)
       ON CONFLICT (chat_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
        [uuidv4(), chatId, userId, role],
      );
      return res.status(201).json({ ok: true });
    } catch (err) {
      console.error("chats.members.add error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.delete(
  "/:chatId/members/:userId",
  requireAuth,
  requireChatPermission(["owner", "moderator"]),
  async (req, res) => {
    const { chatId, userId } = req.params;
    try {
      await db.query(
        "DELETE FROM chat_members WHERE chat_id=$1 AND user_id=$2",
        [chatId, userId],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("chats.members.delete error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.patch(
  "/:chatId/members/:userId/role",
  requireAuth,
  requireChatPermission(["owner"]),
  async (req, res) => {
    const { chatId, userId } = req.params;
    const { role } = req.body || {};
    if (!role)
      return res.status(400).json({ ok: false, error: "role required" });
    try {
      await db.query(
        "UPDATE chat_members SET role=$1 WHERE chat_id=$2 AND user_id=$3",
        [role, chatId, userId],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("chats.members.role error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

module.exports = router;
