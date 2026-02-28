// server/src/routes/admin.js
const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const db = require("../db");
const { ensureSystemChannels } = require("../utils/systemChannels");

const channelUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "channels",
);
fs.mkdirSync(channelUploadsDir, { recursive: true });

const channelAvatarUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, channelUploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : ".jpg";
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    if (String(file.mimetype || "").startsWith("image/")) {
      cb(null, true);
      return;
    }
    cb(new Error("Можно загружать только изображения"));
  },
});

function uploadChannelAvatar(req, res, next) {
  channelAvatarUpload.single("avatar")(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === "LIMIT_FILE_SIZE") {
      return res
        .status(400)
        .json({ ok: false, error: "Размер фото не должен превышать 8MB" });
    }
    return res
      .status(400)
      .json({ ok: false, error: err.message || "Некорректный файл" });
  });
}

function toChannelAvatarUrl(req, file) {
  if (!file || !file.filename) return null;
  return `${req.protocol}://${req.get("host")}/uploads/channels/${file.filename}`;
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function removeChannelAvatarByUrl(raw) {
  const url = String(raw || "").trim();
  if (!url) return;
  const marker = "/uploads/channels/";
  const idx = url.indexOf(marker);
  if (idx === -1) return;
  const filename = url.slice(idx + marker.length).split(/[?#]/)[0].trim();
  if (!filename) return;
  const fullPath = path.join(channelUploadsDir, filename);
  if (!fullPath.startsWith(channelUploadsDir)) return;
  fs.unlink(fullPath, () => {});
}

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function normalizeVisibility(value) {
  const v = String(value || "public")
    .toLowerCase()
    .trim();
  return v === "private" ? "private" : "public";
}

function clampNumber(value, min, max, fallback = 0) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}

function normalizeAvatarFocus(value, fallback = 0) {
  return clampNumber(value, -1, 1, fallback);
}

function normalizeAvatarZoom(value, fallback = 1) {
  return clampNumber(value, 1, 4, fallback);
}

function isUuidLike(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    String(value || "").trim(),
  );
}

function normalizeUuidList(raw) {
  if (!Array.isArray(raw)) return [];
  const unique = new Set();
  for (const item of raw) {
    const value = String(item || "").trim();
    if (!value || !isUuidLike(value)) continue;
    unique.add(value);
  }
  return Array.from(unique);
}

function parseSettingsStringList(raw) {
  if (!Array.isArray(raw)) return [];
  const unique = new Set();
  for (const item of raw) {
    const value = String(item || "").trim();
    if (!value) continue;
    unique.add(value);
  }
  return Array.from(unique);
}

function isBugReportsTitle(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase() === "баг-репорты"
  );
}

function normalizeBlacklistEntries(settings) {
  const entriesRaw = Array.isArray(settings?.blacklist_entries)
    ? settings.blacklist_entries
    : [];
  const fromIds = parseSettingsStringList(settings?.blacklisted_user_ids);

  const byUserId = new Map();

  for (const entry of entriesRaw) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const userId = String(entry.user_id || "").trim();
    if (!userId || !isUuidLike(userId)) continue;
    byUserId.set(userId, {
      user_id: userId,
      added_at: String(entry.added_at || "").trim() || new Date().toISOString(),
      added_by: String(entry.added_by || "").trim() || null,
      reason: String(entry.reason || "").trim(),
    });
  }

  for (const userId of fromIds) {
    if (byUserId.has(userId)) continue;
    byUserId.set(userId, {
      user_id: userId,
      added_at: new Date().toISOString(),
      added_by: null,
      reason: "",
    });
  }

  return Array.from(byUserId.values());
}

function applyBlacklistToSettings(settings, entries) {
  const nextEntries = normalizeBlacklistEntries({
    blacklist_entries: Array.isArray(entries) ? entries : [],
  });
  return {
    ...settings,
    blacklist_entries: nextEntries,
    blacklisted_user_ids: nextEntries.map((entry) => entry.user_id),
  };
}

function isChannelReadOnlySystemChannel(chatRow, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  return (
    (kind && kind !== "channel") ||
    settings?.admin_only === true ||
    isBugReportsTitle(chatRow?.title)
  );
}

function productMessageText(product) {
  const lines = [
    `🛒 ${product.title}`,
    product.description ? String(product.description).trim() : null,
    `ID товара: ${product.product_code}`,
    `Цена: ${product.price} RUB`,
    `Количество в наличии: ${product.quantity}`,
    'Нажмите "Купить", чтобы добавить в корзину',
  ].filter(Boolean);
  return lines.join("\n");
}

function reservedOrderMessageText(order) {
  const lines = [
    `📦 ${order.product_title}`,
    order.product_description
      ? `Описание: ${String(order.product_description).trim()}`
      : null,
    `Клиент: ${order.client_name || "—"}`,
    `Телефон: ${order.client_phone || "—"}`,
    `ID товара: ${order.product_code ?? "—"}`,
    `Цена: ${order.product_price} RUB`,
    `Куплено: ${order.quantity}`,
    `Полка: ${order.shelf_number ?? "не назначена"}`,
    "Статус: ожидание обработки",
  ].filter(Boolean);
  return lines.join("\n");
}

async function allocateProductCode(client) {
  await client.query("LOCK TABLE products IN SHARE ROW EXCLUSIVE MODE");

  const reusable = await client.query(
    `SELECT product_code
     FROM products
     WHERE status = 'archived'
       AND reusable_at IS NOT NULL
       AND reusable_at <= now()
       AND product_code IS NOT NULL
     ORDER BY reusable_at ASC
     LIMIT 1
     FOR UPDATE`,
  );

  if (reusable.rowCount > 0) {
    const code = reusable.rows[0].product_code;
    await client.query(
      `UPDATE products
       SET product_code = NULL,
           updated_at = now()
       WHERE status = 'archived' AND product_code = $1`,
      [code],
    );
    return code;
  }

  const nextRes = await client.query(
    "SELECT COALESCE(MAX(product_code), 0) + 1 AS next_code FROM products",
  );
  return Number(nextRes.rows[0].next_code);
}

// Список пользователей
router.get(
  "/users",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const result = await db.query(
        "SELECT id, email, role, created_at FROM users ORDER BY created_at DESC",
      );
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error("admin.users.list error", err);
      return res.status(500).json({ error: "Ошибка сервера" });
    }
  },
);

// Назначить роль пользователю
router.post(
  "/users/:id/role",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    const { role } = req.body || {};
    const allowed = ["client", "worker", "admin", "creator"];

    if (!allowed.includes(role)) {
      return res.status(400).json({ error: "Неправильная роль" });
    }

    try {
      if (role === "creator" && req.user.role !== "creator") {
        return res
          .status(403)
          .json({ error: "Только создатель способен на такое" });
      }

      await db.query(
        "UPDATE users SET role = $1, updated_at = now() WHERE id = $2",
        [role, id],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.users.role error", err);
      return res.status(500).json({ error: "Ошибка сервера" });
    }
  },
);

// Получить список каналов
router.get(
  "/channels",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const client = await db.pool.connect();
      try {
        await client.query("BEGIN");
        await ensureSystemChannels(client, req.user.id);
        await client.query("COMMIT");
      } catch (err) {
        await client.query("ROLLBACK");
        throw err;
      } finally {
        client.release();
      }

      const result = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
       FROM chats
       WHERE type = 'channel'
         AND COALESCE(settings->>'kind', 'channel') = 'channel'
         AND COALESCE((settings->>'admin_only')::boolean, false) = false
         AND LOWER(TRIM(title)) <> LOWER(TRIM('Баг-репорты'))
       ORDER BY updated_at DESC NULLS LAST, created_at DESC`,
      );
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error("admin.channels.list error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Создать канал
router.post(
  "/channels",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const { title, description, visibility, avatar_url } = req.body || {};

      const normalizedTitle = String(title || "").trim();
      if (!normalizedTitle) {
        return res
          .status(400)
          .json({ ok: false, error: "Название канала обязательно" });
      }

      const nextVisibility = normalizeVisibility(visibility);
      const settings = {
        kind: "channel",
        description: String(description || "").trim(),
        visibility: nextVisibility,
        worker_can_post: false,
        is_post_channel: false,
        avatar_url: String(avatar_url || "").trim(),
        avatar_focus_x: 0,
        avatar_focus_y: 0,
        avatar_zoom: 1,
        blacklisted_user_ids: [],
        blacklist_entries: [],
      };

      const insert = await db.query(
        `INSERT INTO chats (id, title, type, created_by, settings, created_at, updated_at)
       VALUES ($1, $2, 'channel', $3, $4::jsonb, now(), now())
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [uuidv4(), normalizedTitle, req.user.id, JSON.stringify(settings)],
      );
      const channel = insert.rows[0];

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:created", { chatId: channel.id });
      }

      return res.status(201).json({ ok: true, data: channel });
    } catch (err) {
      console.error("admin.channels.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Удалить канал
router.delete(
  "/channels/:id",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const current = await client.query(
        `SELECT id, title, settings
       FROM chats
       WHERE id = $1 AND type = 'channel'
       LIMIT 1
       FOR UPDATE`,
        [id],
      );
      if (current.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }
      const currentSettings = normalizeSettings(current.rows[0].settings);
      const systemKey = String(currentSettings.system_key || "").toLowerCase().trim();
      if (
        (currentSettings.kind && currentSettings.kind !== "channel") ||
        systemKey === "main_channel" ||
        systemKey === "reserved_orders" ||
        currentSettings.admin_only === true ||
        isBugReportsTitle(current.rows[0].title)
      ) {
        await client.query("ROLLBACK");
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя удалять" });
      }

      const deleted = await client.query(
        `DELETE FROM chats
       WHERE id = $1 AND type = 'channel'
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [id],
      );
      const deletedChannel = deleted.rows[0];
      const deletedSettings = normalizeSettings(deletedChannel.settings);

      // Если удалили текущий post-channel, автоматически назначаем следующий канал.
      if (deletedSettings.is_post_channel === true) {
        const next = await client.query(
          `SELECT id
         FROM chats
         WHERE type = 'channel'
           AND COALESCE(settings->>'kind', 'channel') = 'channel'
         ORDER BY updated_at DESC NULLS LAST, created_at DESC
         LIMIT 1`,
        );
        if (next.rowCount > 0) {
          await client.query(
            `UPDATE chats
           SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{is_post_channel}', 'true'::jsonb, true),
               updated_at = now()
           WHERE id = $1`,
            [next.rows[0].id],
          );
        }
      }

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:deleted", { chatId: id });
      }

      return res.json({ ok: true, data: deletedChannel });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Обновить настройки канала
router.patch(
  "/channels/:id",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      const current = await db.query(
        `SELECT id, title, settings
       FROM chats
       WHERE id = $1 AND type = 'channel'
       LIMIT 1`,
        [id],
      );
      if (current.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const row = current.rows[0];
      const rowSettings = normalizeSettings(row.settings);
      if (isChannelReadOnlySystemChannel(row, rowSettings)) {
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя редактировать" });
      }
      const nextSettings = {
        kind: "channel",
        ...rowSettings,
      };
      nextSettings.avatar_focus_x = normalizeAvatarFocus(
        nextSettings.avatar_focus_x,
        0,
      );
      nextSettings.avatar_focus_y = normalizeAvatarFocus(
        nextSettings.avatar_focus_y,
        0,
      );
      nextSettings.avatar_zoom = normalizeAvatarZoom(nextSettings.avatar_zoom, 1);
      const normalizedEntries = normalizeBlacklistEntries(nextSettings);
      nextSettings.blacklist_entries = normalizedEntries;
      nextSettings.blacklisted_user_ids = normalizedEntries.map(
        (entry) => entry.user_id,
      );
      const systemKey = String(nextSettings.system_key || "").toLowerCase().trim();
      const isMainChannel = systemKey === "main_channel";

      if (Object.prototype.hasOwnProperty.call(req.body || {}, "description")) {
        nextSettings.description = String(req.body.description || "").trim();
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "visibility")) {
        nextSettings.visibility = normalizeVisibility(req.body.visibility);
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_url")) {
        nextSettings.avatar_url = String(req.body.avatar_url || "").trim();
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_focus_x")) {
        nextSettings.avatar_focus_x = normalizeAvatarFocus(
          req.body.avatar_focus_x,
          nextSettings.avatar_focus_x,
        );
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_focus_y")) {
        nextSettings.avatar_focus_y = normalizeAvatarFocus(
          req.body.avatar_focus_y,
          nextSettings.avatar_focus_y,
        );
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_zoom")) {
        nextSettings.avatar_zoom = normalizeAvatarZoom(
          req.body.avatar_zoom,
          nextSettings.avatar_zoom,
        );
      }
      if (isMainChannel) {
        nextSettings.visibility = "public";
        nextSettings.worker_can_post = true;
        nextSettings.is_post_channel = true;
        nextSettings.admin_only = false;
      } else {
        nextSettings.worker_can_post = false;
        nextSettings.is_post_channel = false;
      }

      const nextTitle =
        typeof req.body?.title === "string" && req.body.title.trim()
          ? req.body.title.trim()
          : row.title;

      const updated = await db.query(
        `UPDATE chats
       SET title = $1,
           settings = $2::jsonb,
           updated_at = now()
       WHERE id = $3
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [nextTitle, JSON.stringify(nextSettings), id],
      );

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:updated", { chat: updated.rows[0] });
      }

      return res.json({ ok: true, data: updated.rows[0] });
    } catch (err) {
      console.error("admin.channels.update error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Детальный обзор канала: клиенты, медиа, blacklist, счетчики
router.get(
  "/channels/:id/overview",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      const channelQ = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
         FROM chats
         WHERE id = $1 AND type = 'channel'
         LIMIT 1`,
        [id],
      );
      if (channelQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const channel = channelQ.rows[0];
      const settings = normalizeSettings(channel.settings);
      if (isChannelReadOnlySystemChannel(channel, settings)) {
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал недоступен в настройках" });
      }

      const visibility = normalizeVisibility(settings.visibility);
      const blacklistEntries = normalizeBlacklistEntries(settings);
      const blacklistedUserIds = blacklistEntries.map((entry) => entry.user_id);
      const blacklistedSet = new Set(blacklistedUserIds);

      const statsQ = await db.query(
        `SELECT COUNT(*)::int AS messages_total,
                COUNT(*) FILTER (
                  WHERE created_at >= now() - interval '24 hours'
                )::int AS messages_24h,
                COUNT(*) FILTER (
                  WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
                )::int AS product_posts_total,
                COUNT(*) FILTER (
                  WHERE
                    COALESCE(meta->>'image_url', '') <> ''
                    OR COALESCE(meta->>'product_image_url', '') <> ''
                    OR COALESCE(meta->>'kind', '') = 'catalog_product'
                )::int AS media_total,
                MAX(created_at) AS last_message_at
         FROM messages
         WHERE chat_id = $1`,
        [id],
      );

      const queueQ = await db.query(
        `SELECT COUNT(*) FILTER (
                  WHERE status = 'pending' AND COALESCE(is_sent, false) = false
                )::int AS pending_posts_total,
                COUNT(*) FILTER (
                  WHERE status = 'published' AND COALESCE(is_sent, false) = true
                )::int AS published_queue_total
         FROM product_publication_queue
         WHERE channel_id = $1`,
        [id],
      );

      const membersQ = await db.query(
        `SELECT u.id::text AS user_id,
                COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Пользователь') AS name,
                u.email,
                u.role,
                ph.phone,
                cm.role AS chat_role,
                cm.joined_at
         FROM chat_members cm
         JOIN users u ON u.id = cm.user_id
         LEFT JOIN phones ph ON ph.user_id = u.id
         WHERE cm.chat_id = $1
         ORDER BY cm.joined_at DESC
         LIMIT 300`,
        [id],
      );

      let clientsQ;
      let clientsTotal = 0;
      if (visibility === "private") {
        clientsQ = await db.query(
          `SELECT u.id::text AS user_id,
                  COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Клиент') AS name,
                  u.email,
                  ph.phone,
                  true AS is_member
           FROM chat_members cm
           JOIN users u ON u.id = cm.user_id
           LEFT JOIN phones ph ON ph.user_id = u.id
           WHERE cm.chat_id = $1 AND u.role = 'client'
           ORDER BY cm.joined_at DESC
           LIMIT 300`,
          [id],
        );
        clientsTotal = clientsQ.rowCount;
      } else {
        clientsQ = await db.query(
          `SELECT u.id::text AS user_id,
                  COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Клиент') AS name,
                  u.email,
                  ph.phone,
                  EXISTS (
                    SELECT 1 FROM chat_members cm
                    WHERE cm.chat_id = $1 AND cm.user_id = u.id
                  ) AS is_member
           FROM users u
           LEFT JOIN phones ph ON ph.user_id = u.id
           WHERE u.role = 'client'
           ORDER BY u.created_at DESC
           LIMIT 300`,
          [id],
        );
        const clientsCountQ = await db.query(
          `SELECT COUNT(*)::int AS total
           FROM users
           WHERE role = 'client'`,
        );
        clientsTotal = Number(clientsCountQ.rows[0]?.total || 0);
      }

      const clients = clientsQ.rows.map((row) => ({
        ...row,
        is_blacklisted: blacklistedSet.has(String(row.user_id)),
      }));

      const mediaQ = await db.query(
        `SELECT m.id AS message_id,
                m.text,
                m.meta,
                m.created_at,
                u.id::text AS sender_id,
                COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Пользователь') AS sender_name,
                u.email AS sender_email
         FROM messages m
         LEFT JOIN users u ON u.id = m.sender_id
         WHERE m.chat_id = $1
           AND (
             COALESCE(m.meta->>'image_url', '') <> ''
             OR COALESCE(m.meta->>'product_image_url', '') <> ''
             OR COALESCE(m.meta->>'kind', '') = 'catalog_product'
           )
         ORDER BY m.created_at DESC
         LIMIT 120`,
        [id],
      );

      const media = mediaQ.rows
        .map((row) => {
          const meta = normalizeSettings(row.meta);
          const imageUrl =
            String(meta.image_url || "").trim() ||
            String(meta.product_image_url || "").trim() ||
            null;
          if (!imageUrl) return null;
          return {
            message_id: row.message_id,
            created_at: row.created_at,
            kind: String(meta.kind || "").trim(),
            image_url: imageUrl,
            text: String(row.text || "").trim(),
            sender_id: row.sender_id,
            sender_name: row.sender_name,
            sender_email: row.sender_email,
          };
        })
        .filter(Boolean);

      let blacklistedUsers = [];
      if (blacklistedUserIds.length > 0) {
        const validBlacklistedIds = normalizeUuidList(blacklistedUserIds);
        if (validBlacklistedIds.length > 0) {
          const usersQ = await db.query(
            `SELECT u.id::text AS user_id,
                    COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Пользователь') AS name,
                    u.email,
                    u.role,
                    ph.phone
             FROM users u
             LEFT JOIN phones ph ON ph.user_id = u.id
             WHERE u.id = ANY($1::uuid[])
             LIMIT 300`,
            [validBlacklistedIds],
          );
          const byId = new Map(usersQ.rows.map((u) => [String(u.user_id), u]));
          blacklistedUsers = blacklistEntries.map((entry) => ({
            ...entry,
            user: byId.get(String(entry.user_id)) || null,
          }));
        } else {
          blacklistedUsers = blacklistEntries.map((entry) => ({
            ...entry,
            user: null,
          }));
        }
      }

      const stats = {
        messages_total: Number(statsQ.rows[0]?.messages_total || 0),
        messages_24h: Number(statsQ.rows[0]?.messages_24h || 0),
        media_total: Number(statsQ.rows[0]?.media_total || 0),
        product_posts_total: Number(statsQ.rows[0]?.product_posts_total || 0),
        pending_posts_total: Number(queueQ.rows[0]?.pending_posts_total || 0),
        published_queue_total: Number(queueQ.rows[0]?.published_queue_total || 0),
        members_total: Number(membersQ.rowCount || 0),
        clients_total: Number(clientsTotal || 0),
        blacklisted_total: blacklistedUserIds.length,
        last_message_at: statsQ.rows[0]?.last_message_at || null,
      };

      const suggestedBlacklistUsers = clients
        .filter((u) => !u.is_blacklisted)
        .slice(0, 60);

      return res.json({
        ok: true,
        data: {
          channel: {
            ...channel,
            settings: {
              ...settings,
              avatar_focus_x: normalizeAvatarFocus(settings.avatar_focus_x, 0),
              avatar_focus_y: normalizeAvatarFocus(settings.avatar_focus_y, 0),
              avatar_zoom: normalizeAvatarZoom(settings.avatar_zoom, 1),
              blacklisted_user_ids: blacklistedUserIds,
              blacklist_entries: blacklistEntries,
            },
          },
          stats,
          members: membersQ.rows,
          clients,
          media,
          blacklist: blacklistedUsers,
          suggested_blacklist_users: suggestedBlacklistUsers,
        },
      });
    } catch (err) {
      console.error("admin.channels.overview error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Добавить пользователя в blacklist канала
router.post(
  "/channels/:id/blacklist",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    const userId = String(req.body?.user_id || "").trim();
    const reason = String(req.body?.reason || "").trim().slice(0, 240);
    if (!isUuidLike(userId)) {
      return res
        .status(400)
        .json({ ok: false, error: "user_id должен быть UUID" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const channelQ = await client.query(
        `SELECT id, title, settings
         FROM chats
         WHERE id = $1 AND type = 'channel'
         LIMIT 1
         FOR UPDATE`,
        [id],
      );
      if (channelQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const channel = channelQ.rows[0];
      const settings = normalizeSettings(channel.settings);
      if (isChannelReadOnlySystemChannel(channel, settings)) {
        await client.query("ROLLBACK");
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя редактировать" });
      }

      const userQ = await client.query(
        `SELECT id::text AS user_id, role, name, email
         FROM users
         WHERE id = $1::uuid
         LIMIT 1`,
        [userId],
      );
      if (userQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res
          .status(404)
          .json({ ok: false, error: "Пользователь не найден" });
      }
      const targetUser = userQ.rows[0];
      const targetRole = String(targetUser.role || "")
        .toLowerCase()
        .trim();
      if (targetRole === "admin" || targetRole === "creator") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Нельзя добавлять admin/creator в черный список",
        });
      }

      const currentEntries = normalizeBlacklistEntries(settings);
      const byUserId = new Map(
        currentEntries.map((entry) => [String(entry.user_id), entry]),
      );
      const nowIso = new Date().toISOString();
      byUserId.set(userId, {
        user_id: userId,
        added_at: nowIso,
        added_by: String(req.user.id || "").trim() || null,
        reason,
      });
      const nextSettings = applyBlacklistToSettings(
        {
          ...settings,
          avatar_focus_x: normalizeAvatarFocus(settings.avatar_focus_x, 0),
          avatar_focus_y: normalizeAvatarFocus(settings.avatar_focus_y, 0),
          avatar_zoom: normalizeAvatarZoom(settings.avatar_zoom, 1),
        },
        Array.from(byUserId.values()),
      );

      const updated = await client.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id],
      );

      // Если канал приватный и пользователь был участником — удаляем его.
      await client.query(
        `DELETE FROM chat_members
         WHERE chat_id = $1 AND user_id = $2::uuid`,
        [id, userId],
      );

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:updated", { chat: updated.rows[0] });
      }

      return res.json({
        ok: true,
        data: {
          channel: updated.rows[0],
          user: targetUser,
          blacklist_user_ids: nextSettings.blacklisted_user_ids,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.blacklist.add error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Удалить пользователя из blacklist канала
router.delete(
  "/channels/:id/blacklist/:userId",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id, userId } = req.params;
    if (!isUuidLike(userId)) {
      return res
        .status(400)
        .json({ ok: false, error: "userId должен быть UUID" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const channelQ = await client.query(
        `SELECT id, title, settings
         FROM chats
         WHERE id = $1 AND type = 'channel'
         LIMIT 1
         FOR UPDATE`,
        [id],
      );
      if (channelQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }
      const channel = channelQ.rows[0];
      const settings = normalizeSettings(channel.settings);
      if (isChannelReadOnlySystemChannel(channel, settings)) {
        await client.query("ROLLBACK");
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя редактировать" });
      }

      const nextEntries = normalizeBlacklistEntries(settings).filter(
        (entry) => String(entry.user_id) !== String(userId),
      );
      const nextSettings = applyBlacklistToSettings(
        {
          ...settings,
          avatar_focus_x: normalizeAvatarFocus(settings.avatar_focus_x, 0),
          avatar_focus_y: normalizeAvatarFocus(settings.avatar_focus_y, 0),
          avatar_zoom: normalizeAvatarZoom(settings.avatar_zoom, 1),
        },
        nextEntries,
      );

      const updated = await client.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id],
      );
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:updated", { chat: updated.rows[0] });
      }

      return res.json({
        ok: true,
        data: {
          channel: updated.rows[0],
          blacklist_user_ids: nextSettings.blacklisted_user_ids,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.blacklist.remove error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Загрузить/обновить аватарку канала
router.post(
  "/channels/:id/avatar",
  requireAuth,
  requireRole("admin", "creator"),
  uploadChannelAvatar,
  async (req, res) => {
    const { id } = req.params;
    const uploadedUrl = toChannelAvatarUrl(req, req.file);
    if (!uploadedUrl) {
      return res.status(400).json({ ok: false, error: "Файл аватарки обязателен" });
    }
    try {
      const current = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
         FROM chats
         WHERE id = $1 AND type = 'channel'
         LIMIT 1`,
        [id],
      );
      if (current.rowCount === 0) {
        removeUploadedFile(req.file);
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const currentRow = current.rows[0];
      const settings = normalizeSettings(currentRow.settings);
      const nextSettings = { ...settings, avatar_url: uploadedUrl };
      const previousAvatar = String(settings.avatar_url || "").trim();

      const upd = await db.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id],
      );
      const updated = upd.rows[0];

      if (previousAvatar && previousAvatar !== uploadedUrl) {
        removeChannelAvatarByUrl(previousAvatar);
      }

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:updated", { chat: updated });
      }

      return res.json({ ok: true, data: updated });
    } catch (err) {
      removeUploadedFile(req.file);
      console.error("admin.channels.avatar error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Удалить аватарку канала
router.delete(
  "/channels/:id/avatar",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      const current = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
         FROM chats
         WHERE id = $1 AND type = 'channel'
         LIMIT 1`,
        [id],
      );
      if (current.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }
      const currentRow = current.rows[0];
      const settings = normalizeSettings(currentRow.settings);
      const previousAvatar = String(settings.avatar_url || "").trim();
      const nextSettings = { ...settings, avatar_url: "" };

      const upd = await db.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id],
      );
      const updated = upd.rows[0];

      if (previousAvatar) {
        removeChannelAvatarByUrl(previousAvatar);
      }

      const io = req.app.get("io");
      if (io) {
        io.emit("chat:updated", { chat: updated });
      }

      return res.json({ ok: true, data: updated });
    } catch (err) {
      console.error("admin.channels.avatar.remove error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Назначить каналом для публикации товаров (эксклюзивный выбор)
router.post(
  "/channels/:id/set_post_channel",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    return res.status(410).json({
      ok: false,
      error:
        "Функция выбора канала публикации отключена. Публикация идет только в Основной канал.",
    });
  },
);

// Очередь постов от worker (ожидают подтверждения)
router.get(
  "/channels/pending_posts",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const channelId = req.query.channel_id
        ? String(req.query.channel_id)
        : null;
      const result = await db.query(
        `SELECT q.id,
              q.product_id,
              q.channel_id,
              q.queued_by,
              q.status,
              q.is_sent,
              q.payload,
              q.created_at,
              c.title AS channel_title,
              p.title AS product_title,
              p.description AS product_description,
              p.price AS product_price,
              p.quantity AS product_quantity,
              p.image_url AS product_image_url,
              p.product_code,
              u.email AS queued_by_email
       FROM product_publication_queue q
       JOIN chats c ON c.id = q.channel_id
       JOIN products p ON p.id = q.product_id
       LEFT JOIN users u ON u.id = q.queued_by
       WHERE q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
         AND ($1::uuid IS NULL OR q.channel_id = $1::uuid)
       ORDER BY q.created_at ASC`,
        [channelId],
      );
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error("admin.channels.pending_posts error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Отправить заказы клиентов в канал "Забронированный товар"
router.post(
  "/orders/dispatch_reserved",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { reservedChannel } = await ensureSystemChannels(client, req.user.id);

      const ordersQ = await client.query(
        `SELECT r.id AS reservation_id,
                r.user_id,
                r.product_id,
                r.cart_item_id,
                r.quantity,
                r.is_fulfilled,
                r.is_sent,
                p.product_code,
                p.title AS product_title,
                p.description AS product_description,
                p.price AS product_price,
                p.image_url AS product_image_url,
                u.name AS client_name,
                ph.phone AS client_phone,
                us.shelf_number
         FROM reservations r
         JOIN products p ON p.id = r.product_id
         JOIN users u ON u.id = r.user_id
         LEFT JOIN phones ph ON ph.user_id = r.user_id
         LEFT JOIN user_shelves us ON us.user_id = r.user_id
         WHERE r.is_fulfilled = false
         ORDER BY r.created_at ASC
         FOR UPDATE OF r`,
      );

      const dispatched = [];
      for (const row of ordersQ.rows) {
        const meta = {
          kind: "reserved_order_item",
          reservation_id: row.reservation_id,
          cart_item_id: row.cart_item_id,
          user_id: row.user_id,
          product_id: row.product_id,
          product_code: row.product_code,
          title: row.product_title,
          description: row.product_description,
          price: Number(row.product_price),
          quantity: Number(row.quantity),
          image_url: row.product_image_url,
          client_name: row.client_name || "—",
          client_phone: row.client_phone || "—",
          shelf_number: row.shelf_number,
          placed: false,
        };

        const messageInsert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, $3, $4, $5::jsonb, now())
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            uuidv4(),
            reservedChannel.id,
            req.user.id,
            reservedOrderMessageText(row),
            JSON.stringify(meta),
          ],
        );

        await client.query(
          `UPDATE reservations
           SET is_sent = true,
               sent_at = now(),
               reserved_channel_message_id = $2,
               updated_at = now()
           WHERE id = $1`,
          [row.reservation_id, messageInsert.rows[0].id],
        );

        if (row.cart_item_id) {
          await client.query(
            `UPDATE cart_items
             SET reserved_sent_at = now(),
                 updated_at = now()
             WHERE id = $1`,
            [row.cart_item_id],
          );
        }

        dispatched.push({
          reservation_id: row.reservation_id,
          cart_item_id: row.cart_item_id,
          message_id: messageInsert.rows[0].id,
          user_id: row.user_id,
          shelf_number: row.shelf_number,
          product_code: row.product_code,
          quantity: Number(row.quantity),
          client_name: row.client_name || "—",
        });
      }

      if (dispatched.length > 0) {
        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          reservedChannel.id,
        ]);
      }

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io && dispatched.length > 0) {
        for (const item of dispatched) {
          const msgRes = await db.query(
            "SELECT id, chat_id, sender_id, text, meta, created_at FROM messages WHERE id = $1 LIMIT 1",
            [item.message_id],
          );
          if (msgRes.rowCount > 0) {
            io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
              chatId: reservedChannel.id,
              message: msgRes.rows[0],
            });
          }
        }
      }

      return res.json({
        ok: true,
        data: {
          channel_id: reservedChannel.id,
          dispatched_count: dispatched.length,
          orders: dispatched,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.orders.dispatch_reserved error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Отметить товар как "положил" (обработан)
router.post(
  "/orders/mark_placed",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const reservationId = String(req.body?.reservation_id || "").trim();
    const cartItemId = String(req.body?.cart_item_id || "").trim();
    const shelfRaw = req.body?.shelf_number;
    const shelfNumber =
      shelfRaw == null || shelfRaw === ""
        ? null
        : Number.parseInt(String(shelfRaw), 10);

    if (!reservationId && !cartItemId) {
      return res
        .status(400)
        .json({ ok: false, error: "reservation_id или cart_item_id обязателен" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { reservedChannel } = await ensureSystemChannels(client, req.user.id);

      const reservationQ = await client.query(
        `SELECT r.id,
                r.user_id,
                r.product_id,
                r.cart_item_id,
                r.quantity,
                r.is_fulfilled,
                c.status AS cart_status,
                p.product_code,
                p.title,
                p.price
         FROM reservations r
         LEFT JOIN cart_items c ON c.id = r.cart_item_id
         JOIN products p ON p.id = r.product_id
         WHERE (
           ($1::uuid IS NOT NULL AND r.id = $1::uuid)
           OR
           ($1::uuid IS NULL AND $2::uuid IS NOT NULL AND r.cart_item_id = $2::uuid)
         )
         ORDER BY r.created_at DESC
         LIMIT 1
         FOR UPDATE OF r`,
        [reservationId || null, cartItemId || null],
      );
      if (reservationQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Резерв не найден" });
      }
      const item = reservationQ.rows[0];
      const targetCartItemId = item.cart_item_id ? String(item.cart_item_id) : "";
      if (item.is_fulfilled === true) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Этот товар уже обработан",
          data: { status: "processed" },
        });
      }

      const shelfQ = await client.query(
        `SELECT shelf_number
         FROM user_shelves
         WHERE user_id = $1
         LIMIT 1
         FOR UPDATE`,
        [item.user_id],
      );

      let finalShelf = shelfQ.rowCount > 0 ? Number(shelfQ.rows[0].shelf_number) : null;
      if (finalShelf == null) {
        if (!Number.isFinite(shelfNumber) || Number(shelfNumber) <= 0) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            code: "SHELF_REQUIRED",
            error: "Требуется номер полки",
          });
        }
        finalShelf = Number(shelfNumber);
        await client.query(
          `INSERT INTO user_shelves (user_id, shelf_number, created_at, updated_at)
           VALUES ($1, $2, now(), now())
           ON CONFLICT (user_id) DO UPDATE
             SET shelf_number = EXCLUDED.shelf_number,
                 updated_at = now()`,
          [item.user_id, finalShelf],
        );
      }

      await client.query(
        `UPDATE reservations
         SET is_fulfilled = true,
             is_sent = true,
             fulfilled_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [item.id],
      );

      if (targetCartItemId) {
        await client.query(
          `UPDATE cart_items
           SET status = 'processed',
               updated_at = now()
           WHERE id = $1`,
          [targetCartItemId],
        );
      }

      const processedByQ = await client.query(
        `SELECT name, email
         FROM users
         WHERE id = $1
         LIMIT 1`,
        [req.user.id],
      );
      const processedByRow =
        processedByQ.rowCount > 0 ? processedByQ.rows[0] : null;
      const processedByName =
        String(processedByRow?.name || "").trim() ||
        String(processedByRow?.email || "").trim() ||
        "Сотрудник";

      const updatedReservedMessages = await client.query(
        `UPDATE messages
         SET meta = jsonb_set(
           jsonb_set(
             jsonb_set(
               jsonb_set(COALESCE(meta, '{}'::jsonb), '{placed}', 'true'::jsonb, true),
               '{shelf_number}',
               to_jsonb($2::int),
               true
             ),
             '{processed_by_id}',
             to_jsonb($3::text),
             true
           ),
           '{processed_by_name}',
           to_jsonb($4::text),
           true
         )
         WHERE chat_id = $1
           AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
           AND (
             COALESCE(meta->>'reservation_id', '') = $5
             OR ($6 <> '' AND COALESCE(meta->>'cart_item_id', '') = $6)
           )
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
        [
          reservedChannel.id,
          finalShelf,
          String(req.user.id),
          processedByName,
          String(item.id),
          targetCartItemId,
        ],
      );

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        reservedChannel.id,
      ]);

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const message of updatedReservedMessages.rows) {
          io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
            chatId: reservedChannel.id,
            message,
          });
        }
      }

      return res.json({
        ok: true,
        data: {
          reservation_id: item.id,
          cart_item_id: targetCartItemId || null,
          status: "processed",
          shelf_number: finalShelf,
          processed_by_name: processedByName,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.orders.mark_placed error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Подтвердить и отправить посты на канал
router.post(
  "/channels/publish_pending",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const channelId = req.body?.channel_id ? String(req.body.channel_id) : null;
    const queueIds = Array.isArray(req.body?.queue_ids)
      ? req.body.queue_ids.map((v) => String(v))
      : [];
    const onlySelected = queueIds.length > 0;

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      let rows;
      if (onlySelected) {
        const q = await client.query(
          `SELECT q.id, q.product_id, q.channel_id, q.payload, q.queued_by,
                p.title, p.description, p.price, p.quantity, p.image_url, p.product_code,
                c.title AS channel_title
         FROM product_publication_queue q
         JOIN products p ON p.id = q.product_id
         JOIN chats c ON c.id = q.channel_id
         WHERE q.status = 'pending'
           AND COALESCE(q.is_sent, false) = false
           AND q.id = ANY($1::uuid[])
         ORDER BY q.created_at ASC
         FOR UPDATE`,
          [queueIds],
        );
        rows = q.rows;
      } else {
        const q = await client.query(
          `SELECT q.id, q.product_id, q.channel_id, q.payload, q.queued_by,
                p.title, p.description, p.price, p.quantity, p.image_url, p.product_code,
                c.title AS channel_title
         FROM product_publication_queue q
         JOIN products p ON p.id = q.product_id
         JOIN chats c ON c.id = q.channel_id
         WHERE q.status = 'pending'
           AND COALESCE(q.is_sent, false) = false
           AND ($1::uuid IS NULL OR q.channel_id = $1::uuid)
         ORDER BY q.created_at ASC
         FOR UPDATE`,
          [channelId],
        );
        rows = q.rows;
      }

      const published = [];

      for (const row of rows) {
        let code = row.product_code;
        if (!code) {
          code = await allocateProductCode(client);
        }

        const payload =
          row.payload &&
          typeof row.payload === "object" &&
          !Array.isArray(row.payload)
            ? row.payload
            : {};

        const nextTitle = String(payload.title || row.title || "").trim();
        const nextDescription = String(
          payload.description || row.description || "",
        ).trim();
        const nextPrice = Number(payload.price ?? row.price ?? 0);
        const nextQuantity = Number(payload.quantity ?? row.quantity ?? 1);
        const nextImageUrl = payload.image_url || row.image_url || null;

        const productUpdate = await client.query(
          `UPDATE products
         SET product_code = $1,
             title = $2,
             description = $3,
             price = $4,
             quantity = $5,
             image_url = $6,
             status = 'published',
             reusable_at = NULL,
             updated_at = now()
         WHERE id = $7
         RETURNING id, product_code, title, description, price, quantity, image_url`,
          [
            code,
            nextTitle,
            nextDescription,
            nextPrice,
            nextQuantity,
            nextImageUrl,
            row.product_id,
          ],
        );
        const product = productUpdate.rows[0];

        const messageMeta = {
          kind: "catalog_product",
          product_id: product.id,
          product_code: product.product_code,
          price: Number(product.price),
          quantity: Number(product.quantity),
          image_url: product.image_url,
        };

        const messageInsert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, $3, $4, $5::jsonb, now())
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            uuidv4(),
            row.channel_id,
            req.user.id,
            productMessageText(product),
            JSON.stringify(messageMeta),
          ],
        );
        const message = messageInsert.rows[0];

        await client.query(
          `UPDATE product_publication_queue
         SET status = 'published',
             is_sent = true,
             approved_by = $1,
             approved_at = now(),
             published_message_id = $2
         WHERE id = $3`,
          [req.user.id, message.id, row.id],
        );

        await client.query(
          "UPDATE chats SET updated_at = now() WHERE id = $1",
          [row.channel_id],
        );

        published.push({
          queue_id: row.id,
          channel_id: row.channel_id,
          channel_title: row.channel_title,
          product_id: product.id,
          product_code: product.product_code,
          message_id: message.id,
        });
      }

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const item of published) {
          const msgRes = await db.query(
            "SELECT id, chat_id, sender_id, text, meta, created_at FROM messages WHERE id = $1 LIMIT 1",
            [item.message_id],
          );
          if (msgRes.rowCount > 0) {
            io.to(`chat:${item.channel_id}`).emit("chat:message", {
              chatId: item.channel_id,
              message: msgRes.rows[0],
            });
          }
        }
      }

      return res.json({
        ok: true,
        published_count: published.length,
        data: published,
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.publish_pending error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Архивировать товар и освободить ID через 60 дней
router.post(
  "/products/:id/archive",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const { id } = req.params;
      const upd = await db.query(
        `UPDATE products
       SET status = 'archived',
           reusable_at = now() + interval '60 days',
           updated_at = now()
       WHERE id = $1
       RETURNING id, product_code, title, status, reusable_at`,
        [id],
      );
      if (upd.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Товар не найден" });
      }
      return res.json({ ok: true, data: upd.rows[0] });
    } catch (err) {
      console.error("admin.products.archive error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

module.exports = router;
