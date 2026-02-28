// server/src/routes/chats.js
const express = require("express");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const db = require("../db");
const { authMiddleware: requireAuth } = require("../utils/auth");
const { requireRole } = require("../utils/roles");
const { requireChatPermission } = require("../utils/permissions");

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function normalizeRole(role) {
  return String(role || "client")
    .toLowerCase()
    .trim();
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

async function getChatAccessContext(chatId, userId) {
  const chatQ = await db.query(
    "SELECT id, title, type, settings FROM chats WHERE id = $1 LIMIT 1",
    [chatId],
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

function isSystemMessage(meta) {
  const kind = String(meta?.kind || "")
    .toLowerCase()
    .trim();
  return kind.length > 0;
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
            (m.sender_id::text = $2::text) AS from_me,
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
    [messageId, String(currentUserId || "")],
  );
  return result.rows[0] || null;
}

router.get("/", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
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
         ORDER BY m.created_at DESC
         LIMIT 1
       ) AS last_msg ON true
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
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 200`,
      [userId, workerOrHigher, adminOrCreator, userIdText, userIdText],
    );

    const privateQ = await db.query(
      `SELECT c.id,
              c.title,
              c.type,
              c.settings,
              last_msg.text AS last_message,
              last_msg.created_at AS updated_at,
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
         ORDER BY m.created_at DESC
         LIMIT 1
       ) AS last_msg ON true
       LEFT JOIN users last_user ON last_user.id = last_msg.sender_id
       WHERE c.type <> 'channel' AND cm.user_id = $1
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`,
      [userId, userIdText],
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
        `INSERT INTO chats (id, title, type, created_by, settings, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5::jsonb, now(), now())
       RETURNING id, title, type, created_by, settings`,
        [
          uuidv4(),
          title,
          safeType,
          req.user.id,
          JSON.stringify({ kind: "chat" }),
        ],
      );
      const chat = insert.rows[0];

      if (safeType === "private") {
        const creatorId = req.user.id;
        const membersArr = Array.isArray(members) ? members : [];
        const toAdd = Array.from(new Set([creatorId, ...membersArr]));
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
        io.emit("chat:created", { chat });
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

    const context = await getChatAccessContext(chatId, userId);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    if (!canReadChat(context, role)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const { rows } = await db.query(
      `SELECT m.id,
              m.sender_id,
              m.text,
              m.meta,
              m.created_at,
              (m.sender_id::text = $2::text) AS from_me,
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

    const context = await getChatAccessContext(chatId, userId);
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

    let insert;
    if (client_msg_id) {
      insert = await db.query(
        `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
         VALUES ($1, $2, $3, $4, $5, now())
         ON CONFLICT (client_msg_id) DO NOTHING
         RETURNING id`,
        [uuidv4(), client_msg_id, chatId, userId, text],
      );
      if (insert.rowCount === 0) {
        insert = await db.query(
          `SELECT id
           FROM messages
           WHERE client_msg_id = $1`,
          [client_msg_id],
        );
      }
    } else {
      insert = await db.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, created_at)
         VALUES ($1, $2, $3, $4, now())
         RETURNING id`,
        [uuidv4(), chatId, userId, text],
      );
    }

    const messageId = insert.rows[0]?.id;
    if (!messageId) {
      return res.status(500).json({ ok: false, error: "Не удалось создать сообщение" });
    }
    const message = await getHydratedMessageById(messageId, userId);
    if (!message) {
      return res.status(500).json({ ok: false, error: "Не удалось загрузить сообщение" });
    }
    await db.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
      chatId,
    ]);

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:message", { chatId, message });
    }

    return res.status(201).json({ ok: true, data: message });
  } catch (err) {
    console.error("chats.postMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

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

    const context = await getChatAccessContext(chatId, userId);
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

    const context = await getChatAccessContext(chatId, userId);
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

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:message:deleted", {
        chatId,
        messageId,
      });
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
