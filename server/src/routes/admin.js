// server/src/routes/admin.js
const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const requirePermission = require("../middleware/requirePermission");
const db = require("../db");
const { ensureSystemChannels } = require("../utils/systemChannels");
const {
  generateAccessKey,
  generateInviteCode,
  generateTenantCode,
  hashAccessKey,
  maskAccessKey,
  normalizeAccessKey,
  normalizeInviteCode,
} = require("../utils/tenants");
const {
  provisionIsolatedTenantDatabase,
} = require("../utils/tenantDatabases");
const { logMonitoringEvent } = require("../utils/monitoring");
const { emitToTenant } = require("../utils/socket");
const { antifraudGuard } = require("../utils/antifraud");
const {
  encryptMessageText,
  decryptMessageRow,
} = require("../utils/messageCrypto");

const requireProductPublishPermission = requirePermission("product.publish");
const requireReservationFulfillPermission = requirePermission(
  "reservation.fulfill",
);
const PUBLISH_POST_INTERVAL_MS = 3000;
const SAMARA_TZ = "Europe/Samara";
const TENANT_ACCESS_KEY_PATTERN = /^[A-Z]{3}-[A-Z0-9]{1,32}-KEY$/;

function buildIsolatedProvisionWarning(err) {
  const code = String(err?.code || "").trim();
  if (code === "42501") {
    return "Изолированная БД не создана (проверьте CREATEDB). Арендатор переведен в shared-режим.";
  }
  if (code === "23503") {
    return "Изолированная БД создана частично, но не удалось связать служебные данные. Арендатор переведен в shared-режим.";
  }
  return "Изолированная БД не создана. Арендатор переведен в shared-режим.";
}

function emitTenantSubscriptionUpdate(io, tenantId, row, source = "admin") {
  if (!io) return;
  const targetTenantId = String(tenantId || row?.id || "").trim();
  if (!targetTenantId) return;
  emitToTenant(io, targetTenantId, "tenant:subscription:update", {
    tenant_id: targetTenantId,
    status: row?.status || null,
    subscription_expires_at: row?.subscription_expires_at || null,
    source,
    at: new Date().toISOString(),
  });
}

const channelUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "channels",
);
const productUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "products",
);
fs.mkdirSync(channelUploadsDir, { recursive: true });
fs.mkdirSync(productUploadsDir, { recursive: true });

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

function schedulePublishedMessages(io, published, tenantId = null) {
  if (!io || !Array.isArray(published) || published.length === 0) return;
  published.forEach((item, index) => {
    setTimeout(async () => {
      try {
        const msgRes = await db.query(
          "SELECT id, chat_id, sender_id, text, meta, created_at FROM messages WHERE id = $1 LIMIT 1",
          [item.message_id],
        );
        if (msgRes.rowCount === 0) return;
        io.to(`chat:${item.channel_id}`).emit("chat:message", {
          chatId: item.channel_id,
          message: decryptMessageRow(msgRes.rows[0]),
        });
        emitToTenant(io, tenantId, "chat:updated", { chatId: item.channel_id });
      } catch (err) {
        console.error("admin.publish_pending emit error", err);
      }
    }, index * PUBLISH_POST_INTERVAL_MS);
  });
}

function normalizeVisibility(value) {
  const v = String(value || "public")
    .toLowerCase()
    .trim();
  return v === "private" ? "private" : "public";
}

function isIsoDay(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || "").trim());
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

const demoPlaceholderPngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAoAAAAHgCAYAAAA10dzkAAAACXBIWXMAAAsSAAALEgHS3X78AAAGnElEQVR4nO3UQQ0AIBDAsAP/nuGNAvZoFSzZOjM7AID3zA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDv7AFCiwL6geiJ2QAAAABJRU5ErkJggg==";

function ensureDemoProductImage(req) {
  const filename = "demo-placeholder.png";
  const target = path.join(productUploadsDir, filename);
  if (!fs.existsSync(target)) {
    fs.writeFileSync(target, Buffer.from(demoPlaceholderPngBase64, "base64"));
  }
  return `${req.protocol}://${req.get("host")}/uploads/products/${filename}`;
}

function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
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

function isMainSystemTitle(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase() === "основной канал"
  );
}

function isReservedSystemTitle(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase() === "забронированный товар"
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
    `Цена: ${product.price} ₽`,
    `Количество в наличии: ${product.quantity}`,
    'Нажмите "Купить", чтобы добавить в корзину',
  ].filter(Boolean);
  return lines.join("\n");
}

function formatProductLabel(productCode, shelfNumber) {
  const code = Number(productCode);
  const shelf = Number(shelfNumber);
  const codePart = Number.isFinite(code) && code > 0 ? String(Math.floor(code)) : "—";
  const shelfPart = Number.isFinite(shelf) && shelf > 0
    ? String(Math.floor(shelf)).padStart(2, "0")
    : "—";
  return `${codePart}--${shelfPart}`;
}

async function resolveAutoShelfNumber(
  client,
  tenantId = null,
  dateValue = null,
  fallback = 1,
) {
  const dayQ = await client.query(
    `SELECT to_char((COALESCE($1::timestamptz, now()) AT TIME ZONE $2)::date, 'YYYY-MM-DD') AS current_day`,
    [dateValue, SAMARA_TZ],
  );
  const currentDay = String(dayQ.rows[0]?.current_day || "").trim();
  if (!isIsoDay(currentDay)) return fallback;

  let startDay = currentDay;
  const mainQ = await client.query(
    `SELECT id, settings
     FROM chats
     WHERE type = 'channel'
       AND COALESCE(settings->>'system_key', '') = 'main_channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
     ORDER BY created_at ASC
     LIMIT 1
     FOR UPDATE`,
    [tenantId || null],
  );
  if (mainQ.rowCount > 0) {
    const main = mainQ.rows[0];
    const settings = normalizeSettings(main.settings);
    const savedStart = String(settings.shelf_cycle_start_day || "").trim();
    if (isIsoDay(savedStart)) {
      startDay = savedStart;
    } else {
      const nextSettings = {
        ...settings,
        shelf_cycle_start_day: currentDay,
      };
      await client.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2`,
        [JSON.stringify(nextSettings), main.id],
      );
      startDay = currentDay;
    }
  }

  const diffQ = await client.query(
    `SELECT GREATEST(0, ($1::date - $2::date))::int AS diff_days`,
    [currentDay, startDay],
  );
  const diffDays = Number(diffQ.rows[0]?.diff_days || 0);
  if (!Number.isFinite(diffDays) || diffDays < 0) return fallback;
  return (diffDays % 10) + 1;
}

function reservedOrderMessageText(order) {
  const productLabel = formatProductLabel(
    order.product_code,
    order.product_shelf_number,
  );
  const lines = [
    `📦 ${order.product_title}`,
    order.product_description
      ? `Описание: ${String(order.product_description).trim()}`
      : null,
    `Клиент: ${order.client_name || "—"}`,
    `Телефон: ${order.client_phone || "—"}`,
    `ID товара: ${productLabel}`,
    `Цена: ${order.product_price} ₽`,
    `Куплено: ${order.quantity}`,
    `Полка товара: ${order.product_shelf_number ?? "не назначена"}`,
    `Полка клиента: ${order.shelf_number ?? "не назначена"}`,
    "Статус: ожидание обработки",
  ].filter(Boolean);
  return lines.join("\n");
}

function archivedProductMessageText({
  product,
  sourceChannelTitle,
  queuedByName,
  queuedByEmail,
  queuedByPhone,
}) {
  const creator = queuedByName || queuedByEmail || "Неизвестно";
  const productLabel = formatProductLabel(product.product_code, product.shelf_number);
  const lines = [
    "🗂 Архив поста товара",
    `Название: ${product.title}`,
    product.description ? `Описание: ${String(product.description).trim()}` : null,
    `Цена: ${product.price} ₽`,
    `Количество: ${product.quantity}`,
    `ID товара: ${productLabel}`,
    `Канал публикации: ${sourceChannelTitle || "Основной канал"}`,
    `Кто создал пост: ${creator}`,
    queuedByPhone ? `Телефон создателя: ${queuedByPhone}` : null,
  ].filter(Boolean);
  return lines.join("\n");
}

function buildDemoProduct(index, imageUrl) {
  const nouns = [
    "Шампунь",
    "Кофта",
    "Кружка",
    "Плед",
    "Игрушка",
    "Сумка",
    "Свеча",
    "Куртка",
    "Термос",
    "Скраб",
  ];
  const adjectives = [
    "новый",
    "уютный",
    "мягкий",
    "яркий",
    "плотный",
    "аккуратный",
    "зимний",
    "летний",
    "практичный",
    "компактный",
  ];
  const noun = nouns[index % nouns.length];
  const adjective = adjectives[randomInt(0, adjectives.length - 1)];
  const price = randomInt(80, 2500);
  const quantity = randomInt(1, 8);
  return {
    title: `${noun} ${index + 1}`,
    description: `${adjective} товар для теста публикации на канал. Партия ${randomInt(
      1,
      99,
    )}.`,
    price,
    quantity,
    image_url: imageUrl,
  };
}

function publishDemoPostsSequentially({
  io,
  count,
  channelId,
  channelTitle,
  tenantId,
  createdBy,
  imageUrl,
}) {
  for (let index = 0; index < count; index += 1) {
    setTimeout(async () => {
      const client = await db.pool.connect();
      try {
        await client.query("BEGIN");
        const code = await allocateProductCode(client, tenantId || null);
        const demo = buildDemoProduct(index, imageUrl);
        const productId = uuidv4();
        await client.query(
          `INSERT INTO products (
             id, product_code, title, description, price, quantity,
             image_url, created_by, status, created_at, updated_at
           )
           VALUES (
             $1, $2, $3, $4, $5, $6,
             $7, $8, 'published', now(), now()
           )`,
          [
            productId,
            code,
            demo.title,
            demo.description,
            demo.price,
            demo.quantity,
            demo.image_url,
            createdBy,
          ],
        );

        const payload = {
          title: demo.title,
          description: demo.description,
          price: demo.price,
          quantity: demo.quantity,
          image_url: demo.image_url,
        };
        const messageMeta = {
          kind: "catalog_product",
          product_id: productId,
          product_code: code,
          price: demo.price,
          quantity: demo.quantity,
          image_url: demo.image_url,
        };
        const messageInsert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, NULL, $3, $4::jsonb, now())
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            uuidv4(),
            channelId,
            encryptMessageText(
              productMessageText({
              title: demo.title,
              description: demo.description,
              price: demo.price,
              quantity: demo.quantity,
              }),
            ),
            JSON.stringify(messageMeta),
          ],
        );

        await client.query(
          `INSERT INTO product_publication_queue (
             id, product_id, channel_id, queued_by,
             status, is_sent, payload, approved_by, approved_at, published_message_id, created_at
           )
           VALUES (
             $1, $2, $3, $4,
             'published', true, $5::jsonb, $6, now(), $7, now()
           )`,
          [
            uuidv4(),
            productId,
            channelId,
            createdBy,
            JSON.stringify(payload),
            createdBy,
            messageInsert.rows[0].id,
          ],
        );

        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          channelId,
        ]);
        await client.query("COMMIT");

        if (io) {
          io.to(`chat:${channelId}`).emit("chat:message", {
            chatId: channelId,
            message: decryptMessageRow(messageInsert.rows[0]),
          });
          emitToTenant(io, tenantId || null, "chat:updated", {
            chatId: channelId,
            chat: {
              id: channelId,
              title: channelTitle,
              updated_at: new Date().toISOString(),
            },
          });
        }
      } catch (err) {
        await client.query("ROLLBACK");
        console.error("admin.test.publishDemoPostsSequentially error", err);
      } finally {
        client.release();
      }
    }, index * PUBLISH_POST_INTERVAL_MS);
  }
}

async function allocateProductCode(client, tenantId = null) {
  await client.query("LOCK TABLE products IN SHARE ROW EXCLUSIVE MODE");

  const reusable = await client.query(
    `SELECT p.id, p.product_code, p.reusable_at
     FROM products p
     WHERE p.status = 'archived'
       AND p.reusable_at IS NOT NULL
       AND p.reusable_at <= now()
       AND p.product_code IS NOT NULL
       AND p.product_code > 0
       AND EXISTS (
         SELECT 1
         FROM product_publication_queue q
         JOIN chats c ON c.id = q.channel_id
         WHERE q.product_id = p.id
           AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
       )
     ORDER BY p.product_code ASC, p.reusable_at ASC
     FOR UPDATE OF p`,
    [tenantId || null],
  );

  const reusableCodes = reusable.rows
    .map((row) => Number(row.product_code))
    .filter((value) => Number.isFinite(value) && value > 0);
  const reusableCodeSet = new Set(reusableCodes);
  const reusableByCode = new Map();
  for (const row of reusable.rows) {
    const code = Number(row.product_code);
    if (!Number.isFinite(code) || code <= 0) continue;
    if (!reusableByCode.has(code)) {
      reusableByCode.set(code, row.id);
    }
  }

  const nextRes = await client.query(
    `WITH used AS (
       SELECT DISTINCT p.product_code
       FROM products p
       WHERE p.product_code IS NOT NULL
         AND p.product_code > 0
         AND NOT (p.product_code = ANY($2::int[]))
         AND EXISTS (
           SELECT 1
           FROM product_publication_queue q
           JOIN chats c ON c.id = q.channel_id
           WHERE q.product_id = p.id
             AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
         )
     )
     SELECT COALESCE(
       (SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM used WHERE product_code = 1)),
       (
         SELECT MIN(u1.product_code + 1)
         FROM used u1
         LEFT JOIN used u2
           ON u2.product_code = u1.product_code + 1
         WHERE u2.product_code IS NULL
       ),
       1
     ) AS next_code`,
    [tenantId || null, reusableCodes],
  );
  const nextCode = Number(nextRes.rows[0]?.next_code || 1);
  if (!Number.isFinite(nextCode) || nextCode <= 0) return 1;

  if (reusableCodeSet.has(nextCode)) {
    const reusableProductId = reusableByCode.get(nextCode);
    if (reusableProductId) {
      await client.query(
        `UPDATE products
         SET product_code = NULL,
             updated_at = now()
         WHERE id = $1`,
        [reusableProductId],
      );
    }
  }

  return nextCode;
}

// Список пользователей
router.get(
  "/users",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Управление ролями доступно арендатору только во вкладке Профиль",
      });
    }
    try {
      const role = String(req.user?.role || "")
        .toLowerCase()
        .trim();
      const isCreator = role === "creator";
      const result = await db.query(
        `SELECT id, email, role, created_at
         FROM users
         WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid)
         ORDER BY created_at DESC`,
        [isCreator ? null : req.user?.tenant_id || null],
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
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Управление ролями доступно арендатору только во вкладке Профиль",
      });
    }
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

      const isCreator = String(req.user?.role || "")
        .toLowerCase()
        .trim() === "creator";
      const updated = await db.query(
        `UPDATE users
         SET role = $1, updated_at = now()
         WHERE id = $2
           AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
         RETURNING id`,
        [role, id, isCreator ? null : req.user?.tenant_id || null],
      );
      if (updated.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Пользователь не найден" });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.users.role error", err);
      return res.status(500).json({ error: "Ошибка сервера" });
    }
  },
);

// Управление арендаторами (только platform creator)
router.get("/tenants", requireAuth, requireRole("creator"), async (req, res) => {
  if (req.user?.is_platform_creator !== true) {
    return res.status(403).json({ ok: false, error: "Forbidden" });
  }
  try {
    const includeDeleted = String(req.query?.include_deleted || "")
      .trim()
      .toLowerCase() === "1";
    const result = await db.platformQuery(
      `SELECT id, code, name, status,
              COALESCE(access_key_mask, '—') AS access_key_mask,
              COALESCE(NULLIF(access_key_value, ''), NULL) AS access_key_value,
              subscription_expires_at, last_payment_confirmed_at, notes,
              db_mode, db_name, is_deleted,
              created_at, updated_at
       FROM tenants
       WHERE ($1::boolean = true OR COALESCE(is_deleted, false) = false)
       ORDER BY created_at DESC`,
      [includeDeleted],
    );
    return res.json({ ok: true, data: result.rows });
  } catch (err) {
    console.error("admin.tenants.list error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post(
  "/tenants",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }

    const name = String(req.body?.name || "").trim();
    const monthsRaw = Number(req.body?.months);
    const months = Number.isFinite(monthsRaw)
      ? Math.max(1, Math.min(24, Math.floor(monthsRaw)))
      : 1;
    const notes = String(req.body?.notes || "").trim();

    if (!name) {
      return res
        .status(400)
        .json({ ok: false, error: "Название арендатора обязательно" });
    }

    const accessKey = generateAccessKey();
    const accessKeyHash = hashAccessKey(accessKey);
    const accessKeyMask = maskAccessKey(accessKey);
    const tenantId = uuidv4();
    const code = generateTenantCode(name);

    const platformDbUrl =
      process.env.DATABASE_URL ||
      "postgresql://antitelegram:antitelegram@localhost:5432/antitelegram";
    const client = await db.platformConnect();
    try {
      await client.query("BEGIN");
      const created = await client.query(
        `INSERT INTO tenants (
           id, code, name, access_key_hash, access_key_mask,
           access_key_value,
           status, subscription_expires_at, last_payment_confirmed_at,
           created_by, notes, db_mode, db_name, db_url, created_at, updated_at
         )
         VALUES (
           $1, $2, $3, $4, $5, $6,
           'active', now() + make_interval(months => $7::int), now(),
           $8, $9, 'isolated', NULL, NULL, now(), now()
         )
         RETURNING id, code, name, status, access_key_mask, access_key_value, subscription_expires_at, notes, created_at`,
        [
          tenantId,
          code,
          name,
          accessKeyHash,
          accessKeyMask,
          accessKey,
          months,
          req.user.id,
          notes,
        ],
      );
      await client.query("COMMIT");

      const createdRow = created.rows[0];
      var dbMode = "isolated";
      var dbName = null;
      var warning = "";

      try {
        const provision = await provisionIsolatedTenantDatabase({
          platformDbUrl,
          tenantId,
          tenantCode: code,
          tenantName: name,
          accessKeyHash,
          accessKeyMask,
          accessKeyValue: accessKey,
          status: "active",
          subscriptionExpiresAt: createdRow.subscription_expires_at,
          createdBy: req.user.id,
          notes,
        });

        dbName = provision.dbName;
        await db.platformQuery(
          `UPDATE tenants
           SET db_mode = 'isolated',
               db_name = $2,
               db_url = $3,
               updated_at = now()
           WHERE id = $1`,
          [tenantId, provision.dbName, provision.dbUrl],
        );
      } catch (provisionErr) {
        console.error(
          "admin.tenants.create isolated provision failed",
          provisionErr,
        );
        dbMode = "shared";
        dbName = null;
        warning = buildIsolatedProvisionWarning(provisionErr);
        try {
          await db.platformQuery(
            `UPDATE tenants
             SET db_mode = 'shared',
                 db_name = NULL,
                 db_url = NULL,
                 updated_at = now()
             WHERE id = $1`,
            [tenantId],
          );
          const sharedClient = await db.platformConnect();
          try {
            await sharedClient.query("BEGIN");
            await ensureSystemChannels(sharedClient, req.user.id, tenantId);
            await sharedClient.query("COMMIT");
          } catch (sharedErr) {
            await sharedClient.query("ROLLBACK");
            throw sharedErr;
          } finally {
            sharedClient.release();
          }
        } catch (fallbackErr) {
          console.error(
            "admin.tenants.create shared fallback failed",
            fallbackErr,
          );
          await db.platformQuery(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
          return res.status(500).json({
            ok: false,
            error:
              "Не удалось создать арендатора: изолированная и shared инициализация завершились ошибкой.",
          });
        }
      }

      return res.status(201).json({
        ok: true,
        data: {
          ...createdRow,
          access_key: accessKey,
          db_mode: dbMode,
          db_name: dbName,
          warning,
        },
      });
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      try {
        await db.platformQuery("DELETE FROM tenants WHERE id = $1", [tenantId]);
      } catch (_) {}
      console.error("admin.tenants.create error", err);
      return res.status(500).json({
        ok: false,
        error:
          "Не удалось создать арендатора и его отдельную БД. Проверьте доступ к PostgreSQL.",
      });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/tenants/:tenantId/confirm-payment",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    const monthsRaw = Number(req.body?.months);
    const months = Number.isFinite(monthsRaw)
      ? Math.max(1, Math.min(24, Math.floor(monthsRaw)))
      : 1;

    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }

    try {
      const updated = await db.platformQuery(
        `UPDATE tenants
         SET status = 'active',
             subscription_expires_at = GREATEST(now(), subscription_expires_at) + make_interval(months => $1::int),
             last_payment_confirmed_at = now(),
             updated_at = now()
         WHERE id = $2
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, subscription_expires_at, last_payment_confirmed_at`,
        [months, tenantId],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      const io = req.app.get("io");
      emitTenantSubscriptionUpdate(
        io,
        tenantId,
        updated.rows[0],
        "confirm_payment",
      );
      return res.json({ ok: true, data: updated.rows[0] });
    } catch (err) {
      console.error("admin.tenants.confirmPayment error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenants/:tenantId/status",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    const status = String(req.body?.status || "")
      .toLowerCase()
      .trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }
    if (status !== "active" && status !== "blocked") {
      return res.status(400).json({ ok: false, error: "Статус должен быть active или blocked" });
    }

    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      if (tenant.is_deleted === true) {
        return res.status(404).json({
          ok: false,
          error: "Арендатор уже удален",
        });
      }
      if (isProtectedTenantCode(tenant.code)) {
        return res.status(403).json({
          ok: false,
          error: "Системного арендатора default нельзя блокировать",
        });
      }
      const updated = await db.platformQuery(
        `UPDATE tenants
         SET status = $1,
             updated_at = now()
         WHERE id = $2
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, subscription_expires_at, updated_at`,
        [status, tenantId],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      const io = req.app.get("io");
      emitTenantSubscriptionUpdate(
        io,
        tenantId,
        updated.rows[0],
        "status_change",
      );
      return res.json({ ok: true, data: updated.rows[0] });
    } catch (err) {
      console.error("admin.tenants.updateStatus error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenants/:tenantId/access-key",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }

    const generate = req.body?.generate === true;
    let accessKey = generate
      ? generateAccessKey()
      : normalizeTenantAccessKeyInput(req.body?.access_key || "");
    if (!accessKey) {
      return res.status(400).json({
        ok: false,
        error: "Укажите новый ключ арендатора или включите авто-генерацию",
      });
    }
    if (!TENANT_ACCESS_KEY_PATTERN.test(accessKey)) {
      return res.status(400).json({
        ok: false,
        error:
          "Ключ должен быть в формате XXX-XXXXXXX-KEY (3 буквы слева, в центре буквы/цифры, справа KEY)",
      });
    }

    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant || tenant.is_deleted === true) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }

      const updated = await db.platformQuery(
        `UPDATE tenants
         SET access_key_hash = $1,
             access_key_mask = $2,
             access_key_value = $3,
             updated_at = now()
         WHERE id = $4
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, access_key_value, subscription_expires_at, updated_at`,
        [
          hashAccessKey(accessKey),
          maskAccessKey(accessKey),
          accessKey,
          tenantId,
        ],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      return res.json({
        ok: true,
        data: {
          ...updated.rows[0],
          access_key: accessKey,
        },
      });
    } catch (err) {
      console.error("admin.tenants.updateAccessKey error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/tenants/:tenantId",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }
    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      if (tenant.is_deleted === true) {
        return res.status(404).json({
          ok: false,
          error: "Арендатор уже удален",
        });
      }
      const archived = await db.platformQuery(
        `UPDATE tenants
         SET status = 'blocked',
             is_deleted = true,
             subscription_expires_at = now(),
             updated_at = now()
         WHERE id = $1
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, subscription_expires_at, updated_at, is_deleted`,
        [tenantId],
      );
      if (archived.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден или уже удален" });
      }
      const io = req.app.get("io");
      emitTenantSubscriptionUpdate(io, tenantId, archived.rows[0], "delete");
      return res.json({ ok: true, data: archived.rows[0] });
    } catch (err) {
      console.error("admin.tenants.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

function tenantInviteRole(rawRole) {
  const role = String(rawRole || "").toLowerCase().trim();
  if (role === "client") return role;
  return "client";
}

function parseNullablePositiveInt(raw, { min = 1, max = 100000 } = {}) {
  if (raw == null) return null;
  if (typeof raw === "string" && raw.trim() === "") return null;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return null;
  return Math.max(min, Math.min(max, Math.floor(parsed)));
}

function normalizeTenantAccessKeyInput(raw) {
  const normalized = normalizeAccessKey(raw);
  if (!normalized) return "";
  const compact = normalized.replace(/[^A-Z0-9]/g, "");
  if (compact.length >= 7 && compact.endsWith("KEY")) {
    const prefix = compact.slice(0, 3);
    const middle = compact.slice(3, -3);
    if (/^[A-Z]{3}$/.test(prefix) && /^[A-Z0-9]{1,32}$/.test(middle)) {
      return `${prefix}-${middle}-KEY`;
    }
  }
  return normalized.slice(0, 64);
}

async function resolveTargetTenantForInvite(req) {
  const ownTenantId = String(req.user?.tenant_id || "").trim();
  if (ownTenantId) {
    return {
      id: ownTenantId,
      code: String(req.user?.tenant_code || "").trim() || null,
    };
  }

  const tenantIdHint = String(
    req.query?.tenant_id || req.body?.tenant_id || "",
  ).trim();
  if (tenantIdHint) {
    const byId = await db.platformQuery(
      `SELECT id, code
       FROM tenants
       WHERE id = $1
       LIMIT 1`,
      [tenantIdHint],
    );
    if (byId.rowCount > 0) {
      return {
        id: byId.rows[0].id,
        code: byId.rows[0].code || null,
      };
    }
  }

  const tenantCodeHint = String(
    req.query?.tenant_code || req.body?.tenant_code || "",
  )
    .trim()
    .toLowerCase();
  if (tenantCodeHint) {
    const byCode = await db.platformQuery(
      `SELECT id, code
       FROM tenants
       WHERE lower(code) = $1
       LIMIT 1`,
      [tenantCodeHint],
    );
    if (byCode.rowCount > 0) {
      return {
        id: byCode.rows[0].id,
        code: byCode.rows[0].code || null,
      };
    }
  }

  const latest = await db.platformQuery(
    `SELECT id, code
     FROM tenants
     WHERE code <> 'default'
     ORDER BY updated_at DESC NULLS LAST, created_at DESC
     LIMIT 1`,
  );
  if (latest.rowCount > 0) {
    return {
      id: latest.rows[0].id,
      code: latest.rows[0].code || null,
    };
  }
  return null;
}

function inviteLinkForRequest(req, inviteCode, tenantCode = "") {
  const base = String(process.env.INVITE_LINK_BASE || "").trim();
  const encoded = encodeURIComponent(inviteCode);
  const tenantPart = tenantCode
    ? `&tenant=${encodeURIComponent(tenantCode)}`
    : "";
  if (base) {
    const glue = base.includes("?") ? "&" : "?";
    return `${base}${glue}invite=${encoded}${tenantPart}`;
  }
  return `${req.protocol}://${req.get("host")}/?invite=${encoded}${tenantPart}`;
}

function isTenantUser(user) {
  const base = String(user?.base_role || user?.role || "")
    .toLowerCase()
    .trim();
  return base === "tenant";
}

async function getTenantById(tenantId) {
  const result = await db.platformQuery(
    `SELECT id, code, name, is_deleted
     FROM tenants
     WHERE id = $1
     LIMIT 1`,
    [tenantId],
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

function isProtectedTenantCode(code) {
  return String(code || "").toLowerCase().trim() === "default";
}

router.get(
  "/tenant/invites",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    try {
      const includeInactive = String(req.query?.include_inactive || "")
        .toLowerCase()
        .trim() === "1";
      const result = await db.platformQuery(
        `SELECT i.id,
                i.tenant_id,
                t.code AS tenant_code,
                i.code,
                i.role,
                i.is_active,
                i.max_uses,
                i.used_count,
                i.expires_at,
                i.created_by,
                i.last_used_at,
                i.notes,
                i.created_at,
                i.updated_at
         FROM tenant_invites i
         JOIN tenants t ON t.id = i.tenant_id
         WHERE i.tenant_id = $1
           AND ($2::boolean = true OR i.is_active = true)
         ORDER BY i.created_at DESC`,
        [targetTenant.id, includeInactive],
      );
      const data = result.rows.map((row) => ({
        ...row,
        invite_link: inviteLinkForRequest(
          req,
          row.code,
          row.tenant_code || targetTenant.code || "",
        ),
      }));
      return res.json({ ok: true, data });
    } catch (err) {
      console.error("admin.tenant.invites.list error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/tenant/invites",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const role = tenantInviteRole(req.body?.role);
    const notes = String(req.body?.notes || "").trim();
    const maxUses = parseNullablePositiveInt(req.body?.max_uses, {
      min: 1,
      max: 100000,
    });
    const expiresDays = parseNullablePositiveInt(req.body?.expires_days, {
      min: 1,
      max: 365,
    });
    const forceNew = req.body?.force_new === true;

    try {
      if (!forceNew) {
        const existing = await db.platformQuery(
          `SELECT id,
                  tenant_id,
                  code,
                  role,
                  is_active,
                  max_uses,
                  used_count,
                  expires_at,
                  created_by,
                  last_used_at,
                  notes,
                  created_at,
                  updated_at
           FROM tenant_invites
           WHERE tenant_id = $1
             AND role = $2
             AND is_active = true
             AND max_uses IS NULL
             AND expires_at IS NULL
             AND (expires_at IS NULL OR expires_at > now())
             AND (max_uses IS NULL OR used_count < max_uses)
           ORDER BY created_at DESC
           LIMIT 1`,
          [targetTenant.id, role],
        );
        if (existing.rowCount > 0) {
          const row = existing.rows[0];
          return res.json({
            ok: true,
            reused: true,
            data: {
              ...row,
              invite_link: inviteLinkForRequest(
                req,
                row.code,
                targetTenant.code || "",
              ),
            },
          });
        }
      }

      let tries = 0;
      while (tries < 5) {
        tries += 1;
        const code = generateInviteCode();
        try {
          const inserted = await db.platformQuery(
            `INSERT INTO tenant_invites (
               id, tenant_id, code, role, is_active, max_uses,
               used_count, expires_at, created_by, notes, created_at, updated_at
             )
             VALUES (
               $1, $2, $3, $4, true, $5,
               0,
               CASE WHEN $6::int IS NULL THEN NULL ELSE now() + make_interval(days => $6::int) END,
               $7, NULLIF($8, ''), now(), now()
             )
             RETURNING id,
                       tenant_id,
                       code,
                       role,
                       is_active,
                       max_uses,
                       used_count,
                       expires_at,
                       created_by,
                       last_used_at,
                       notes,
                       created_at,
                       updated_at`,
            [
              uuidv4(),
              targetTenant.id,
              normalizeInviteCode(code),
              role,
              maxUses,
              expiresDays,
              req.user.id,
              notes,
            ],
          );
          const row = inserted.rows[0];
          return res.status(201).json({
            ok: true,
            data: {
              ...row,
              invite_link: inviteLinkForRequest(
                req,
                row.code,
                targetTenant.code || "",
              ),
            },
          });
        } catch (err) {
          if (String(err?.code || "") === "23505") {
            continue;
          }
          throw err;
        }
      }
      return res.status(500).json({
        ok: false,
        error: "Не удалось сгенерировать уникальный код приглашения",
      });
    } catch (err) {
      console.error("admin.tenant.invites.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenant/invites/:inviteId/status",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const inviteId = String(req.params?.inviteId || "").trim();
    const active = req.body?.is_active === true;
    if (!isUuidLike(inviteId)) {
      return res.status(400).json({ ok: false, error: "Некорректный inviteId" });
    }
    try {
      const updated = await db.platformQuery(
        `UPDATE tenant_invites
         SET is_active = $1,
             updated_at = now()
         WHERE id = $2
           AND tenant_id = $3
         RETURNING id,
                   tenant_id,
                   code,
                   role,
                   is_active,
                   max_uses,
                   used_count,
                   expires_at,
                   created_by,
                   last_used_at,
                   notes,
                   created_at,
                   updated_at`,
        [active, inviteId, targetTenant.id],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Код приглашения не найден" });
      }
      const row = updated.rows[0];
      return res.json({
        ok: true,
        data: {
          ...row,
          invite_link: inviteLinkForRequest(
            req,
            row.code,
            targetTenant.code || "",
          ),
        },
      });
    } catch (err) {
      console.error("admin.tenant.invites.status error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/tenant/invites/:inviteId",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const inviteId = String(req.params?.inviteId || "").trim();
    if (!isUuidLike(inviteId)) {
      return res.status(400).json({ ok: false, error: "Некорректный inviteId" });
    }
    try {
      const removed = await db.platformQuery(
        `UPDATE tenant_invites
         SET is_active = false,
             updated_at = now()
         WHERE id = $1
           AND tenant_id = $2
         RETURNING id`,
        [inviteId, targetTenant.id],
      );
      if (removed.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Код приглашения не найден" });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.tenant.invites.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
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
        await ensureSystemChannels(client, req.user.id, req.user.tenant_id);
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
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
         AND COALESCE(settings->>'kind', 'channel') = 'channel'
         AND COALESCE((settings->>'admin_only')::boolean, false) = false
         AND COALESCE((settings->>'hidden_in_chat_list')::boolean, false) = false
         AND LOWER(TRIM(title)) <> LOWER(TRIM('Баг-репорты'))
       ORDER BY updated_at DESC NULLS LAST, created_at DESC`,
        [req.user.tenant_id || null],
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
      if (isMainSystemTitle(normalizedTitle) || isReservedSystemTitle(normalizedTitle)) {
        return res.status(400).json({
          ok: false,
          error:
            "Это системное название. Измените существующий системный канал в настройках, а не создавайте новый.",
        });
      }

      const nextVisibility = normalizeVisibility(visibility);
      const settings = {
        kind: "channel",
        tenant_id: req.user.tenant_id,
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
        `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
       VALUES ($1, $2, 'channel', $3, $4, $5::jsonb, now(), now())
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [
          uuidv4(),
          normalizedTitle,
          req.user.id,
          req.user.tenant_id,
          JSON.stringify(settings),
        ],
      );
      const channel = insert.rows[0];

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:created", {
          chatId: channel.id,
        });
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
       WHERE id = $1 AND type = 'channel' AND tenant_id = $2
       LIMIT 1
       FOR UPDATE`,
        [id, req.user.tenant_id],
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
       WHERE id = $1 AND type = 'channel' AND tenant_id = $2
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [id, req.user.tenant_id],
      );
      const deletedChannel = deleted.rows[0];
      const deletedSettings = normalizeSettings(deletedChannel.settings);

      // Если удалили текущий post-channel, автоматически назначаем следующий канал.
      if (deletedSettings.is_post_channel === true) {
        const next = await client.query(
          `SELECT id
         FROM chats
         WHERE type = 'channel'
           AND tenant_id = $1
           AND COALESCE(settings->>'kind', 'channel') = 'channel'
         ORDER BY updated_at DESC NULLS LAST, created_at DESC
         LIMIT 1`,
          [req.user.tenant_id],
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
        emitToTenant(io, req.user?.tenant_id || null, "chat:deleted", {
          chatId: id,
        });
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
       WHERE id = $1 AND type = 'channel' AND tenant_id = $2
       LIMIT 1`,
        [id, req.user.tenant_id],
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
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated.rows[0],
        });
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
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
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
             AND u.tenant_id = $2
           ORDER BY u.created_at DESC
           LIMIT 300`,
          [id, req.user.tenant_id],
        );
        const clientsCountQ = await db.query(
          `SELECT COUNT(*)::int AS total
           FROM users
           WHERE role = 'client'
             AND tenant_id = $1`,
          [req.user.tenant_id],
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
               AND u.tenant_id = $2
             LIMIT 300`,
            [validBlacklistedIds, req.user.tenant_id],
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
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1
         FOR UPDATE`,
        [id, req.user.tenant_id],
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
           AND tenant_id = $2
         LIMIT 1`,
        [userId, req.user.tenant_id],
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
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
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
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated.rows[0],
        });
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
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1
         FOR UPDATE`,
        [id, req.user.tenant_id],
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
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated.rows[0],
        });
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
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
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
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );
      const updated = upd.rows[0];

      if (previousAvatar && previousAvatar !== uploadedUrl) {
        removeChannelAvatarByUrl(previousAvatar);
      }

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated,
        });
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
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
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
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );
      const updated = upd.rows[0];

      if (previousAvatar) {
        removeChannelAvatarByUrl(previousAvatar);
      }

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated,
        });
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
  requireProductPublishPermission,
  async (req, res) => {
    try {
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
              p.shelf_number AS product_shelf_number,
              p.image_url AS product_image_url,
              p.product_code,
              u.email AS queued_by_email,
              u.name AS queued_by_name
       FROM product_publication_queue q
       JOIN chats c ON c.id = q.channel_id
       JOIN products p ON p.id = q.product_id
       LEFT JOIN users u ON u.id = q.queued_by
       WHERE q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
         AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
       ORDER BY q.created_at ASC`,
        [req.user.tenant_id || null],
      );
      const reservedStatsQ = await db.query(
        `SELECT COUNT(*)::int AS total,
                COALESCE(SUM(quantity), 0)::int AS units
         FROM reservations r
         JOIN users u ON u.id = r.user_id
         WHERE r.is_fulfilled = false
           AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)`,
        [req.user.tenant_id || null],
      );
      return res.json({
        ok: true,
        data: result.rows,
        meta: {
          reserved_pending_total: Number(reservedStatsQ.rows[0]?.total || 0),
          reserved_pending_units: Number(reservedStatsQ.rows[0]?.units || 0),
        },
      });
    } catch (err) {
      console.error("admin.channels.pending_posts error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/channels/pending_posts/:queueId",
  requireAuth,
  requireRole("admin", "creator"),
  requireProductPublishPermission,
  async (req, res) => {
    const queueId = String(req.params.queueId || "").trim();
    const title = String(req.body?.title || "").trim();
    const description = String(req.body?.description || "").trim();
    const price = Number(req.body?.price);
    const quantity = Number(req.body?.quantity);
    const rawShelfNumber = Number(req.body?.shelf_number);
    const shelfNumber =
      Number.isFinite(rawShelfNumber) && rawShelfNumber > 0
        ? Math.floor(rawShelfNumber)
        : null;

    if (!queueId) {
      return res.status(400).json({ ok: false, error: "queueId обязателен" });
    }
    if (!title) {
      return res
        .status(400)
        .json({ ok: false, error: "Название товара обязательно" });
    }
    if (!description || description.length < 2) {
      return res.status(400).json({
        ok: false,
        error: "Описание должно содержать минимум 2 символа",
      });
    }
    if (!Number.isFinite(price) || price <= 0) {
      return res
        .status(400)
        .json({ ok: false, error: "Цена должна быть больше нуля" });
    }
    if (!Number.isFinite(quantity) || quantity <= 0) {
      return res
        .status(400)
        .json({ ok: false, error: "Количество должно быть больше нуля" });
    }
    try {
      const updated = await db.query(
         `WITH target AS (
           SELECT q.id, q.product_id
           FROM product_publication_queue q
           JOIN chats c ON c.id = q.channel_id
           WHERE q.id = $1
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
             AND ($7::uuid IS NULL OR c.tenant_id = $7::uuid)
           LIMIT 1
         ),
         product_upd AS (
           UPDATE products p
           SET title = $2,
               description = $3,
               price = $4,
               quantity = $5,
               shelf_number = COALESCE($6::int, p.shelf_number),
                updated_at = now()
           FROM target t
           WHERE p.id = t.product_id
           RETURNING p.id, p.title, p.description, p.price, p.quantity, p.shelf_number, p.image_url, p.product_code
         )
         UPDATE product_publication_queue q
         SET payload = jsonb_strip_nulls(
               jsonb_build_object(
                 'title', $2,
                 'description', $3,
                 'price', $4,
                 'quantity', $5,
                 'shelf_number', (SELECT shelf_number FROM product_upd LIMIT 1),
                 'image_url', (SELECT image_url FROM product_upd LIMIT 1)
               )
             )
         WHERE q.id = $1
           AND EXISTS (SELECT 1 FROM target)
         RETURNING q.id`,
        [
          queueId,
          title,
          description,
          price,
          Math.floor(quantity),
          shelfNumber,
          req.user.tenant_id || null,
        ],
      );
      if (updated.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: "Пост не найден или уже опубликован",
        });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.channels.pending_posts.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Отправить заказы клиентов в канал "Забронированный товар"
router.post(
  "/orders/dispatch_reserved",
  requireAuth,
  requireRole("admin", "creator"),
  requireReservationFulfillPermission,
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { reservedChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );

      const ordersQ = await client.query(
        `SELECT r.id AS reservation_id,
                r.user_id,
                r.product_id,
                r.cart_item_id,
                r.quantity,
                r.is_fulfilled,
                r.is_sent,
                p.product_code,
                p.shelf_number AS product_shelf_number,
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
           AND COALESCE(r.is_sent, false) = false
           AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
         ORDER BY r.created_at ASC
         FOR UPDATE OF r`,
        [req.user.tenant_id || null],
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
          product_label: formatProductLabel(
            row.product_code,
            row.product_shelf_number,
          ),
          product_shelf_number: row.product_shelf_number,
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
            encryptMessageText(reservedOrderMessageText(row)),
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
          product_shelf_number: row.product_shelf_number,
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
              message: decryptMessageRow(msgRes.rows[0]),
            });
            emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
              chatId: reservedChannel.id,
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
  requireReservationFulfillPermission,
  async (req, res) => {
    const reservationId = String(req.body?.reservation_id || "").trim();
    const cartItemId = String(req.body?.cart_item_id || "").trim();
    const shelfRaw = Number(req.body?.shelf_number);
    const manualShelf = Number.isFinite(shelfRaw) && shelfRaw > 0 ? Math.floor(shelfRaw) : null;
    const effectiveRole = String(req.user?.role || "").toLowerCase().trim();
    const requiresManualShelf = effectiveRole === "admin" || effectiveRole === "tenant";

    if (!reservationId && !cartItemId) {
      return res
        .status(400)
        .json({ ok: false, error: "reservation_id или cart_item_id обязателен" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { reservedChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );

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
         JOIN users buyer ON buyer.id = r.user_id
         WHERE (
           ($1::uuid IS NOT NULL AND r.id = $1::uuid)
           OR
           ($1::uuid IS NULL AND $2::uuid IS NOT NULL AND r.cart_item_id = $2::uuid)
         )
           AND ($3::uuid IS NULL OR buyer.tenant_id = $3::uuid)
         ORDER BY r.created_at DESC
         LIMIT 1
         FOR UPDATE OF r`,
        [reservationId || null, cartItemId || null, req.user.tenant_id || null],
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

      if (requiresManualShelf && manualShelf == null) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Для администратора нужно вручную указать номер полки",
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

      let finalShelf = manualShelf;
      if (finalShelf == null) {
        finalShelf = shelfQ.rowCount > 0 ? Number(shelfQ.rows[0].shelf_number) : null;
      }
      if (finalShelf == null) {
        finalShelf = await resolveAutoShelfNumber(
          client,
          req.user?.tenant_id || null,
          null,
          1,
        );
      }
      await client.query(
        `INSERT INTO user_shelves (user_id, shelf_number, created_at, updated_at)
         VALUES ($1, $2, now(), now())
         ON CONFLICT (user_id) DO UPDATE
           SET shelf_number = EXCLUDED.shelf_number,
               updated_at = now()`,
        [item.user_id, finalShelf],
      );

      await client.query(
        `UPDATE reservations
         SET is_fulfilled = true,
             is_sent = true,
             fulfilled_by_id = $2,
             fulfilled_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [item.id, req.user.id],
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

      let hiddenCatalogMessages = [];
      const productIdText = String(item.product_id || "").trim();
      if (productIdText) {
        const productQ = await client.query(
          `SELECT id, quantity
           FROM products
           WHERE id = $1
           LIMIT 1
           FOR UPDATE`,
          [productIdText],
        );
        if (
          productQ.rowCount > 0 &&
          Number(productQ.rows[0].quantity || 0) <= 0
        ) {
          const unresolvedQ = await client.query(
            `SELECT 1
             FROM reservations r
             JOIN users u ON u.id = r.user_id
             WHERE r.product_id = $1
               AND r.is_fulfilled = false
               AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
             LIMIT 1`,
            [productIdText, req.user.tenant_id || null],
          );
          if (unresolvedQ.rowCount === 0) {
            await client.query(
              `UPDATE products
               SET status = 'archived',
                   reusable_at = now() + interval '2 months',
                   updated_at = now()
               WHERE id = $1
                 AND status <> 'archived'`,
              [productIdText],
            );

            const hiddenQ = await client.query(
              `UPDATE messages
               SET meta = jsonb_set(
                     jsonb_set(
                       COALESCE(meta, '{}'::jsonb),
                       '{hidden_for_all}',
                       'true'::jsonb,
                       true
                     ),
                     '{sold_out_processed}',
                     'true'::jsonb,
                     true
                   )
               WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
                 AND COALESCE(meta->>'product_id', '') = $1::text
                 AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false
               RETURNING id, chat_id, sender_id, text, meta, created_at`,
              [productIdText],
            );
            hiddenCatalogMessages = hiddenQ.rows;
          }
        }
      }

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        reservedChannel.id,
      ]);

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const message of updatedReservedMessages.rows) {
          io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
            chatId: reservedChannel.id,
            message: decryptMessageRow(message),
          });
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId: reservedChannel.id,
          });
        }
        io.to(`user:${item.user_id}`).emit("cart:updated", {
          userId: String(item.user_id),
          product_id: item.product_id ? String(item.product_id) : "",
          cart_item_id: targetCartItemId || null,
          status: "processed",
          shelf_number: finalShelf,
          processed_by_name: processedByName,
            reason: "item_processed",
        });
        for (const hiddenMessage of hiddenCatalogMessages) {
          io.to(`chat:${hiddenMessage.chat_id}`).emit("chat:message", {
            chatId: hiddenMessage.chat_id,
            message: decryptMessageRow(hiddenMessage),
          });
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId: hiddenMessage.chat_id,
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
          product_hidden_after_sellout: hiddenCatalogMessages.length > 0,
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
  requireProductPublishPermission,
  antifraudGuard("admin.publish_pending", (req) => ({
    channel_id: req.body?.channel_id || null,
    queue_count: Array.isArray(req.body?.queue_ids) ? req.body.queue_ids.length : 0,
  })),
  async (req, res) => {
    const rawChannelId = req.body?.channel_id
      ? String(req.body.channel_id).trim()
      : "";
    if (rawChannelId && !isUuidLike(rawChannelId)) {
      return res.status(400).json({
        ok: false,
        error: "Некорректный channel_id",
      });
    }
    const channelId = rawChannelId || null;

    const rawQueueIds = Array.isArray(req.body?.queue_ids)
      ? req.body.queue_ids
      : [];
    const queueIds = normalizeUuidList(rawQueueIds);
    if (rawQueueIds.length > 0 && queueIds.length === 0) {
      return res.status(400).json({
        ok: false,
        error: "Некорректные queue_ids",
      });
    }
    const onlySelected = queueIds.length > 0;

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      let rows;
      if (onlySelected) {
        const lockedQ = await client.query(
          `SELECT q.id
           FROM product_publication_queue q
           WHERE q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
             AND q.id = ANY($1::uuid[])
             AND EXISTS (
               SELECT 1
               FROM chats c
               WHERE c.id = q.channel_id
                 AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
             )
           ORDER BY q.created_at ASC
           FOR UPDATE OF q`,
          [queueIds, req.user.tenant_id || null],
        );
        const lockedIds = lockedQ.rows.map((row) => row.id);
        if (lockedIds.length === 0) {
          rows = [];
        } else {
          const detailsQ = await client.query(
            `SELECT q.id, q.product_id, q.channel_id, q.payload, q.queued_by,
                  p.title, p.description, p.price, p.quantity, p.shelf_number, p.image_url, p.product_code,
                  c.title AS channel_title,
                  u.name AS queued_by_name,
                  u.email AS queued_by_email,
                  ph.phone AS queued_by_phone
             FROM product_publication_queue q
             JOIN products p ON p.id = q.product_id
             JOIN chats c ON c.id = q.channel_id
             LEFT JOIN users u ON u.id = q.queued_by
             LEFT JOIN phones ph ON ph.user_id = q.queued_by
             WHERE q.id = ANY($1::uuid[])
             ORDER BY q.created_at ASC`,
            [lockedIds],
          );
          rows = detailsQ.rows;
        }
      } else {
        const lockedQ = await client.query(
          `SELECT q.id
           FROM product_publication_queue q
           WHERE q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
             AND ($1::uuid IS NULL OR q.channel_id = $1::uuid)
             AND EXISTS (
               SELECT 1
               FROM chats c
               WHERE c.id = q.channel_id
                 AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
             )
           ORDER BY q.created_at ASC
           FOR UPDATE OF q`,
          [channelId, req.user.tenant_id || null],
        );
        const lockedIds = lockedQ.rows.map((row) => row.id);
        if (lockedIds.length === 0) {
          rows = [];
        } else {
          const detailsQ = await client.query(
            `SELECT q.id, q.product_id, q.channel_id, q.payload, q.queued_by,
                  p.title, p.description, p.price, p.quantity, p.shelf_number, p.image_url, p.product_code,
                  c.title AS channel_title,
                  u.name AS queued_by_name,
                  u.email AS queued_by_email,
                  ph.phone AS queued_by_phone
             FROM product_publication_queue q
             JOIN products p ON p.id = q.product_id
             JOIN chats c ON c.id = q.channel_id
             LEFT JOIN users u ON u.id = q.queued_by
             LEFT JOIN phones ph ON ph.user_id = q.queued_by
             WHERE q.id = ANY($1::uuid[])
             ORDER BY q.created_at ASC`,
            [lockedIds],
          );
          rows = detailsQ.rows;
        }
      }

      const published = [];
      const archivePublished = [];
      const hiddenRevisionMessages = [];
      const skipped = [];
      const ensuredSystem = await ensureSystemChannels(
        client,
        req.user.id || null,
        req.user.tenant_id || null,
      );
      const postsArchiveChannelId = String(
        ensuredSystem?.postsArchiveChannel?.id || "",
      ).trim();

      for (const row of rows) {
        let code = row.product_code;
        if (!code) {
          code = await allocateProductCode(client, req.user?.tenant_id || null);
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
        if (!nextTitle) {
          skipped.push({
            queue_id: row.id,
            reason: "Пустое название товара",
          });
          continue;
        }

        const rawNextPrice = Number(payload.price ?? row.price ?? 0);
        const fallbackPrice = Number(row.price ?? 0);
        const nextPrice = Number.isFinite(rawNextPrice) && rawNextPrice >= 0
          ? rawNextPrice
          : (Number.isFinite(fallbackPrice) && fallbackPrice >= 0 ? fallbackPrice : 0);

        const rawNextQuantity = Number(payload.quantity ?? row.quantity ?? 1);
        const fallbackQuantity = Number(row.quantity ?? 1);
        const nextQuantity = Number.isFinite(rawNextQuantity) && rawNextQuantity > 0
          ? Math.floor(rawNextQuantity)
          : (Number.isFinite(fallbackQuantity) && fallbackQuantity > 0
            ? Math.floor(fallbackQuantity)
            : 1);
        const rawNextShelf = Number(payload.shelf_number ?? row.shelf_number ?? 0);
        const nextShelfNumber = Number.isFinite(rawNextShelf) && rawNextShelf > 0
          ? Math.floor(rawNextShelf)
          : await resolveAutoShelfNumber(
              client,
              req.user?.tenant_id || null,
              null,
              1,
            );
        const nextImageUrl = payload.image_url || row.image_url || null;

        const productUpdate = await client.query(
          `UPDATE products
         SET product_code = $1,
             title = $2,
             description = $3,
             price = $4,
             quantity = $5,
             shelf_number = $6,
             image_url = $7,
             status = 'published',
             reusable_at = NULL,
             updated_at = now()
         WHERE id = $8
         RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url`,
          [
            code,
            nextTitle,
            nextDescription,
            nextPrice,
            nextQuantity,
            nextShelfNumber,
            nextImageUrl,
            row.product_id,
          ],
        );
        if (productUpdate.rowCount === 0) {
          skipped.push({
            queue_id: row.id,
            reason: "Товар не найден",
          });
          continue;
        }
        const product = productUpdate.rows[0];

        const messageMeta = {
          kind: "catalog_product",
          product_id: product.id,
          product_code: product.product_code,
          product_label: formatProductLabel(
            product.product_code,
            product.shelf_number,
          ),
          price: Number(product.price),
          quantity: Number(product.quantity),
          shelf_number: Number(product.shelf_number),
          image_url: product.image_url,
        };

        const messageInsert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, NULL, $3, $4::jsonb, now())
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            uuidv4(),
            row.channel_id,
            encryptMessageText(productMessageText(product)),
            JSON.stringify(messageMeta),
          ],
        );
        const message = messageInsert.rows[0];

        const shouldHidePrevious =
          payload?.hide_old_versions === true ||
          String(payload?.hide_old_versions || '').toLowerCase().trim() ===
            'true';
        const sourceMessageId = String(payload?.source_message_id || '').trim();
        if (
          shouldHidePrevious &&
          isUuidLike(sourceMessageId) &&
          sourceMessageId !== String(message.id)
        ) {
          const hiddenQ = await client.query(
            `UPDATE messages
             SET meta = jsonb_set(
                   COALESCE(meta, '{}'::jsonb),
                   '{hidden_for_all}',
                   'true'::jsonb,
                   true
                 )
             WHERE id = $1
               AND chat_id = $2
               AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false
             RETURNING id, chat_id, sender_id, text, meta, created_at`,
            [sourceMessageId, row.channel_id],
          );
          hiddenRevisionMessages.push(...hiddenQ.rows);
        }

        if (postsArchiveChannelId) {
          const archiveMeta = {
            kind: "catalog_product_archive",
            product_id: product.id,
            product_code: product.product_code,
            product_label: formatProductLabel(
              product.product_code,
              product.shelf_number,
            ),
            price: Number(product.price),
            quantity: Number(product.quantity),
            shelf_number: Number(product.shelf_number),
            image_url: product.image_url,
            source_channel_id: row.channel_id,
            source_channel_title: row.channel_title,
            source_message_id: message.id,
            queued_by: row.queued_by,
            queued_by_name: row.queued_by_name || null,
            queued_by_email: row.queued_by_email || null,
            queued_by_phone: row.queued_by_phone || null,
          };
          const archiveMessageInsert = await client.query(
            `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
             VALUES ($1, $2, NULL, $3, $4::jsonb, now())
             RETURNING id`,
            [
              uuidv4(),
              postsArchiveChannelId,
              encryptMessageText(
                archivedProductMessageText({
                  product,
                  sourceChannelTitle: row.channel_title,
                  queuedByName: row.queued_by_name,
                  queuedByEmail: row.queued_by_email,
                  queuedByPhone: row.queued_by_phone,
                }),
              ),
              JSON.stringify(archiveMeta),
            ],
          );
          const archiveMessageId = String(
            archiveMessageInsert.rows[0]?.id || "",
          ).trim();
          await client.query(
            "UPDATE chats SET updated_at = now() WHERE id = $1",
            [postsArchiveChannelId],
          );
          if (archiveMessageId) {
            archivePublished.push({
              channel_id: postsArchiveChannelId,
              message_id: archiveMessageId,
            });
          }
        }

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
          product_label: formatProductLabel(
            product.product_code,
            product.shelf_number,
          ),
          shelf_number: Number(product.shelf_number),
          message_id: message.id,
        });
      }

      await client.query("COMMIT");

      schedulePublishedMessages(
        req.app.get("io"),
        published,
        req.user?.tenant_id || null,
      );
      if (archivePublished.length > 0) {
        schedulePublishedMessages(
          req.app.get("io"),
          archivePublished,
          req.user?.tenant_id || null,
        );
      }
      const io = req.app.get("io");
      if (io && hiddenRevisionMessages.length > 0) {
        for (const message of hiddenRevisionMessages) {
          io.to(`chat:${message.chat_id}`).emit("chat:message", {
            chatId: message.chat_id,
            message: decryptMessageRow(message),
          });
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId: message.chat_id,
          });
        }
      }

      return res.json({
        ok: true,
        published_count: published.length,
        skipped_count: skipped.length,
        skipped,
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

router.post(
  "/test/tenants/matrix",
  requireAuth,
  async (req, res) => {
    if (String(req.user?.base_role || req.user?.role || "") !== "creator") {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только создателю платформы",
      });
    }

    const includeDeleted = req.body?.include_deleted === true;
    const includeDefault = req.body?.include_default === true;

    const where = [
      includeDeleted
        ? "1=1"
        : "COALESCE(t.is_deleted, false) = false",
      includeDefault ? "1=1" : "lower(t.code) <> 'default'",
    ].join(" AND ");

    const client = await db.platformConnect();
    try {
      const q = await client.query(
        `SELECT t.id,
                t.code,
                t.name,
                t.status,
                t.db_mode,
                t.db_name,
                t.is_deleted,
                t.subscription_expires_at,
                t.last_payment_confirmed_at,
                t.created_at,
                t.updated_at,
                COALESCE(uc.user_count, 0)::int AS user_count,
                COALESCE(uc.client_count, 0)::int AS client_count,
                COALESCE(uc.staff_count, 0)::int AS staff_count,
                COALESCE(cc.chat_count, 0)::int AS chat_count,
                COALESCE(cc.channel_count, 0)::int AS channel_count,
                COALESCE(cc.private_chat_count, 0)::int AS private_chat_count,
                EXISTS (
                  SELECT 1
                    FROM chats cm
                   WHERE cm.tenant_id = t.id
                     AND lower(COALESCE(cm.type, '')) = 'channel'
                     AND (
                       lower(COALESCE(cm.settings->>'system_key', '')) = 'main_channel'
                       OR lower(COALESCE(cm.settings->>'kind', '')) = 'main_channel'
                       OR COALESCE(cm.settings->>'is_main_channel', '') = 'true'
                       OR lower(COALESCE(cm.title, '')) LIKE 'основной канал%'
                     )
                ) AS has_main_channel
           FROM tenants t
      LEFT JOIN (
             SELECT tenant_id,
                    COUNT(*)::int AS user_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(role, '')) = 'client'
                    )::int AS client_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(role, '')) IN ('creator', 'tenant', 'admin', 'worker')
                    )::int AS staff_count
               FROM users
           GROUP BY tenant_id
      ) uc
             ON uc.tenant_id = t.id
      LEFT JOIN (
             SELECT tenant_id,
                    COUNT(*)::int AS chat_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(type, '')) = 'channel'
                    )::int AS channel_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(type, '')) = 'private'
                    )::int AS private_chat_count
               FROM chats
           GROUP BY tenant_id
      ) cc
             ON cc.tenant_id = t.id
          WHERE ${where}
       ORDER BY lower(t.code) ASC, t.created_at ASC`,
      );

      const now = Date.now();
      let active = 0;
      let blocked = 0;
      let expiringSoon = 0;
      let expired = 0;
      let missingMainChannel = 0;
      let missingStaff = 0;
      let isolated = 0;
      let shared = 0;

      for (const row of q.rows) {
        const status = String(row.status || "")
          .toLowerCase()
          .trim();
        if (status === "active") active += 1;
        if (status === "blocked") blocked += 1;

        const expiresAtRaw = row.subscription_expires_at
          ? new Date(row.subscription_expires_at).getTime()
          : NaN;
        if (Number.isFinite(expiresAtRaw)) {
          if (expiresAtRaw <= now) {
            expired += 1;
          } else if (expiresAtRaw - now <= 24 * 60 * 60 * 1000) {
            expiringSoon += 1;
          }
        }

        if (!row.has_main_channel) missingMainChannel += 1;
        if (Number(row.staff_count || 0) <= 0) missingStaff += 1;

        const dbMode = String(row.db_mode || "")
          .toLowerCase()
          .trim();
        if (dbMode === "isolated") isolated += 1;
        if (dbMode === "shared") shared += 1;
      }

      return res.json({
        ok: true,
        data: {
          include_deleted: includeDeleted,
          include_default: includeDefault,
          total: q.rows.length,
          summary: {
            active,
            blocked,
            expiring_soon_24h: expiringSoon,
            expired,
            missing_main_channel: missingMainChannel,
            missing_staff: missingStaff,
            isolated,
            shared,
          },
          rows: q.rows,
        },
      });
    } catch (err) {
      console.error("admin.test.tenants.matrix error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/test/tenants/subscriptions",
  requireAuth,
  async (req, res) => {
    if (String(req.user?.base_role || req.user?.role || "") !== "creator") {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только создателю платформы",
      });
    }

    const mode = String(req.body?.mode || "")
      .toLowerCase()
      .trim();
    const includeDefault = req.body?.include_default === true;
    const dryRun = req.body?.dry_run === true;
    const warningHoursRaw = Number(req.body?.warning_hours);
    const warningHours = Number.isFinite(warningHoursRaw)
      ? Math.max(1, Math.min(72, Math.floor(warningHoursRaw)))
      : 20;

    const allowedModes = new Set([
      "block_all",
      "activate_all",
      "warn_soon_all",
      "expire_all",
      "restore_snapshot",
    ]);
    if (!allowedModes.has(mode)) {
      return res.status(400).json({
        ok: false,
        error:
          "Некорректный mode. Разрешено: block_all, activate_all, warn_soon_all, expire_all, restore_snapshot",
      });
    }

    let snapshotRows = [];
    if (mode === "restore_snapshot") {
      const rawSnapshot = Array.isArray(req.body?.snapshot)
        ? req.body.snapshot
        : [];
      snapshotRows = rawSnapshot
        .map((row) => {
          const id = String(row?.id || "").trim();
          const status = String(row?.status || "")
            .toLowerCase()
            .trim();
          const expiresRaw = String(
            row?.subscription_expires_at || row?.subscriptionExpiresAt || "",
          ).trim();
          if (!isUuidLike(id)) return null;
          if (status !== "active" && status !== "blocked") return null;
          return {
            id,
            status,
            subscription_expires_at: expiresRaw || null,
          };
        })
        .filter(Boolean);
      if (snapshotRows.length === 0) {
        return res.status(400).json({
          ok: false,
          error: "Для restore_snapshot нужен непустой snapshot",
        });
      }
    }

    const whereSql = includeDefault
      ? "COALESCE(is_deleted, false) = false"
      : "COALESCE(is_deleted, false) = false AND lower(code) <> 'default'";

    const client = await db.platformConnect();
    try {
      await client.query("BEGIN");

      const beforeQ = await client.query(
        `SELECT id, code, name, status, subscription_expires_at
         FROM tenants
         WHERE ${whereSql}
         ORDER BY created_at DESC`,
      );
      const before = beforeQ.rows;

      if (!dryRun && before.length > 0) {
        if (mode === "block_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'blocked',
                 updated_at = now()
             WHERE ${whereSql}`,
          );
        } else if (mode === "activate_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'active',
                 updated_at = now()
             WHERE ${whereSql}`,
          );
        } else if (mode === "warn_soon_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'active',
                 subscription_expires_at = now() + make_interval(hours => $1::int),
                 updated_at = now()
             WHERE ${whereSql}`,
            [warningHours],
          );
        } else if (mode === "expire_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'active',
                 subscription_expires_at = now() - interval '5 minutes',
                 updated_at = now()
             WHERE ${whereSql}`,
          );
        } else if (mode === "restore_snapshot") {
          await client.query(
            `WITH payload AS (
               SELECT *
               FROM jsonb_to_recordset($1::jsonb)
                 AS p(id uuid, status text, subscription_expires_at timestamptz)
             )
             UPDATE tenants t
             SET status = lower(p.status),
                 subscription_expires_at = p.subscription_expires_at,
                 updated_at = now()
             FROM payload p
             WHERE t.id = p.id
               AND ${whereSql}`,
            [JSON.stringify(snapshotRows)],
          );
        }
      }

      const afterQ = await client.query(
        `SELECT id, code, name, status, subscription_expires_at
         FROM tenants
         WHERE ${whereSql}
         ORDER BY created_at DESC`,
      );
      const after = afterQ.rows;

      const beforeById = new Map(before.map((row) => [String(row.id), row]));
      let changed = 0;
      const changedRows = [];
      for (const row of after) {
        const prev = beforeById.get(String(row.id));
        if (!prev) continue;
        const prevStatus = String(prev.status || "");
        const nextStatus = String(row.status || "");
        const prevExpiry = String(prev.subscription_expires_at || "");
        const nextExpiry = String(row.subscription_expires_at || "");
        if (prevStatus !== nextStatus || prevExpiry !== nextExpiry) {
          changed += 1;
          changedRows.push(row);
        }
      }

      const activeCount = after.filter(
        (row) => String(row.status || "").toLowerCase().trim() === "active",
      ).length;
      const blockedCount = after.length - activeCount;

      await client.query("COMMIT");

      if (!dryRun && changedRows.length > 0) {
        const io = req.app.get("io");
        for (const row of changedRows) {
          emitTenantSubscriptionUpdate(
            io,
            row.id,
            row,
            `test_bulk:${mode}`,
          );
        }
      }

      return res.json({
        ok: true,
        data: {
          mode,
          include_default: includeDefault,
          dry_run: dryRun,
          warning_hours: warningHours,
          total: after.length,
          changed,
          active_count: activeCount,
          blocked_count: blockedCount,
          before,
          after,
        },
      });
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      console.error("admin.test.tenants.subscriptions error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/test/publish-demo-posts",
  requireAuth,
  async (req, res) => {
    if (String(req.user?.base_role || req.user?.role || "") !== "creator") {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const requestedCount = Number(req.body?.count);
    const count = Number.isFinite(requestedCount)
      ? Math.max(1, Math.min(50, Math.floor(requestedCount)))
      : 10;

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );
      const imageUrl = ensureDemoProductImage(req);
      await client.query("COMMIT");

      publishDemoPostsSequentially({
        io: req.app.get("io"),
        count,
        channelId: mainChannel.id,
        channelTitle: mainChannel.title,
        tenantId: req.user?.tenant_id || null,
        createdBy: req.user.id,
        imageUrl,
      });

      return res.json({
        ok: true,
        data: {
          count,
          scheduled: true,
          interval_ms: PUBLISH_POST_INTERVAL_MS,
          channel_id: mainChannel.id,
          channel_title: mainChannel.title,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.test.publish_demo_posts error", err);
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

function isCreatorBase(user) {
  const base = String(user?.base_role || user?.role || "")
    .toLowerCase()
    .trim();
  return base === "creator";
}

function tenantFilterSql(alias = "u", tenantIdParamIndex = 1) {
  return `($${tenantIdParamIndex}::uuid IS NULL OR ${alias}.tenant_id = $${tenantIdParamIndex}::uuid)`;
}

router.get(
  "/role-templates",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const tenantId = req.user.tenant_id || null;
      const templatesQ = await db.query(
        `SELECT rt.id,
                rt.tenant_id,
                rt.code,
                rt.title,
                rt.description,
                rt.permissions,
                rt.is_system,
                rt.created_at,
                rt.updated_at,
                COUNT(urt.user_id)::int AS assigned_users
         FROM role_templates rt
         LEFT JOIN user_role_templates urt ON urt.template_id = rt.id
         WHERE rt.tenant_id = $1::uuid
            OR rt.tenant_id IS NULL
         GROUP BY rt.id
         ORDER BY
           CASE WHEN rt.tenant_id IS NULL THEN 1 ELSE 0 END,
           rt.is_system DESC,
           rt.updated_at DESC`,
        [tenantId],
      );
      return res.json({ ok: true, data: templatesQ.rows });
    } catch (err) {
      console.error("admin.roleTemplates.list error", err);
      await logMonitoringEvent({
        tenantId: req.user.tenant_id || null,
        userId: req.user.id,
        level: "error",
        code: "admin_role_templates_list_failed",
        source: "admin.role-templates",
        message: "Не удалось загрузить шаблоны ролей",
        details: { error: String(err?.message || err) },
      });
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/role-templates",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    try {
      const code = String(req.body?.code || "")
        .trim()
        .toLowerCase();
      const title = String(req.body?.title || "").trim();
      const description = String(req.body?.description || "").trim();
      const permissions =
        req.body?.permissions &&
        typeof req.body.permissions === "object" &&
        !Array.isArray(req.body.permissions)
          ? req.body.permissions
          : {};

      if (!/^[a-z0-9_.-]{2,40}$/.test(code)) {
        return res.status(400).json({
          ok: false,
          error: "code должен содержать 2-40 символов: a-z, 0-9, _, -, .",
        });
      }
      if (!title) {
        return res.status(400).json({ ok: false, error: "title обязателен" });
      }

      const result = await db.query(
        `INSERT INTO role_templates (
           id,
           tenant_id,
           code,
           title,
           description,
           permissions,
           is_system,
           created_by,
           created_at,
           updated_at
         )
         VALUES (
           gen_random_uuid(),
           $1,
           $2,
           $3,
           NULLIF($4, ''),
           $5::jsonb,
           false,
           $6,
           now(),
           now()
         )
         RETURNING *`,
        [
          req.user.tenant_id || null,
          code,
          title,
          description,
          JSON.stringify(permissions),
          req.user.id,
        ],
      );
      return res.status(201).json({ ok: true, data: result.rows[0] });
    } catch (err) {
      console.error("admin.roleTemplates.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/role-templates/:id",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    try {
      const templateId = String(req.params?.id || "").trim();
      if (!isUuidLike(templateId)) {
        return res.status(400).json({ ok: false, error: "Некорректный id" });
      }

      const title = String(req.body?.title || "").trim();
      const description = String(req.body?.description || "").trim();
      const permissions =
        req.body?.permissions &&
        typeof req.body.permissions === "object" &&
        !Array.isArray(req.body.permissions)
          ? req.body.permissions
          : null;

      const existingQ = await db.query(
        `SELECT id, tenant_id, is_system
         FROM role_templates
         WHERE id = $1
         LIMIT 1`,
        [templateId],
      );
      if (existingQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Шаблон не найден" });
      }
      const existing = existingQ.rows[0];
      if (existing.is_system === true) {
        return res.status(403).json({
          ok: false,
          error: "Системный шаблон редактировать нельзя",
        });
      }
      if (String(existing.tenant_id || "") !== String(req.user.tenant_id || "")) {
        return res.status(403).json({ ok: false, error: "Нет доступа" });
      }

      const upd = await db.query(
        `UPDATE role_templates
         SET title = COALESCE(NULLIF($1, ''), title),
             description = CASE WHEN $2::text IS NULL THEN description ELSE NULLIF($2, '') END,
             permissions = CASE
               WHEN $3::jsonb IS NULL THEN permissions
               ELSE $3::jsonb
             END,
             updated_at = now()
         WHERE id = $4
         RETURNING *`,
        [title, description || null, permissions ? JSON.stringify(permissions) : null, templateId],
      );
      return res.json({ ok: true, data: upd.rows[0] });
    } catch (err) {
      console.error("admin.roleTemplates.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/role-templates/assign",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const userId = String(req.body?.user_id || "").trim();
      const templateId = String(req.body?.template_id || "").trim();
      if (!isUuidLike(userId) || !isUuidLike(templateId)) {
        return res.status(400).json({
          ok: false,
          error: "user_id и template_id должны быть UUID",
        });
      }

      const userQ = await db.query(
        `SELECT id, tenant_id
         FROM users
         WHERE id = $1
           AND ${tenantFilterSql("users", 2)}
         LIMIT 1`,
        [userId, req.user.tenant_id || null],
      );
      if (userQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Пользователь не найден" });
      }

      const templateQ = await db.query(
        `SELECT id, tenant_id
         FROM role_templates
         WHERE id = $1
           AND (
             tenant_id = $2::uuid
             OR tenant_id IS NULL
           )
         LIMIT 1`,
        [templateId, req.user.tenant_id || null],
      );
      if (templateQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Шаблон роли не найден" });
      }

      await db.query(
        `INSERT INTO user_role_templates (
           user_id,
           template_id,
           assigned_by,
           assigned_at,
           updated_at
         )
         VALUES ($1, $2, $3, now(), now())
         ON CONFLICT (user_id) DO UPDATE
           SET template_id = EXCLUDED.template_id,
               assigned_by = EXCLUDED.assigned_by,
               assigned_at = now(),
               updated_at = now()`,
        [userId, templateId, req.user.id],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.roleTemplates.assign error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get("/problem-report", requireAuth, async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Доступ только создателю" });
    }
    const tenantId = req.user.tenant_id || null;

    const pendingPostsQ = await db.query(
      `SELECT COUNT(*)::int AS total,
              COUNT(*) FILTER (WHERE q.created_at < now() - interval '12 hours')::int AS stale
       FROM product_publication_queue q
       JOIN chats c ON c.id = q.channel_id
       WHERE q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
         AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)`,
      [tenantId],
    );
    const reservationsQ = await db.query(
      `SELECT COUNT(*)::int AS total,
              COALESCE(SUM(r.quantity), 0)::int AS units
       FROM reservations r
       JOIN users u ON u.id = r.user_id
       WHERE r.is_fulfilled = false
         AND (${tenantFilterSql("u", 1)})`,
      [tenantId],
    );
    const deliveryQ = await db.query(
      `SELECT COUNT(*)::int AS waiting_for_courier
       FROM delivery_batch_customers c
       JOIN delivery_batches b ON b.id = c.batch_id
       JOIN users u ON u.id = c.user_id
       WHERE b.status IN ('calling', 'couriers_assigned')
         AND c.call_status = 'accepted'
         AND COALESCE(c.courier_name, '') = ''
         AND (${tenantFilterSql("u", 1)})`,
      [tenantId],
    );
    const monitoringQ = await db.query(
      `SELECT level,
              COUNT(*)::int AS total
       FROM monitoring_events
       WHERE resolved = false
         AND created_at >= now() - interval '7 days'
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid OR tenant_id IS NULL)
       GROUP BY level`,
      [tenantId],
    );
    const sourceQ = await db.query(
      `SELECT COALESCE(NULLIF(TRIM(source), ''), 'unknown') AS source,
              COUNT(*)::int AS total
       FROM monitoring_events
       WHERE created_at >= now() - interval '7 days'
         AND level IN ('error', 'critical')
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid OR tenant_id IS NULL)
       GROUP BY 1
       ORDER BY total DESC, source ASC
       LIMIT 8`,
      [tenantId],
    );

    const byLevel = {};
    for (const row of monitoringQ.rows) {
      byLevel[row.level] = Number(row.total) || 0;
    }

    const pendingPosts = Number(pendingPostsQ.rows[0]?.total || 0);
    const stalePendingPosts = Number(pendingPostsQ.rows[0]?.stale || 0);
    const unresolvedReservations = Number(reservationsQ.rows[0]?.total || 0);
    const unresolvedReservationUnits = Number(reservationsQ.rows[0]?.units || 0);
    const waitingForCourier = Number(deliveryQ.rows[0]?.waiting_for_courier || 0);
    const criticalErrors = Number(byLevel.critical || 0);
    const errorEvents = Number(byLevel.error || 0);

    const hotspots = [];
    if (stalePendingPosts > 0) {
      hotspots.push({
        key: "stale_pending_posts",
        title: "Зависшие посты в модерации",
        value: stalePendingPosts,
        severity: stalePendingPosts > 25 ? "high" : "medium",
      });
    }
    if (waitingForCourier > 0) {
      hotspots.push({
        key: "waiting_for_courier",
        title: "Клиенты без назначенного курьера",
        value: waitingForCourier,
        severity: waitingForCourier > 15 ? "high" : "medium",
      });
    }
    if (criticalErrors + errorEvents > 0) {
      hotspots.push({
        key: "monitoring_errors",
        title: "Ошибки сервера за 7 дней",
        value: criticalErrors + errorEvents,
        severity: criticalErrors > 0 ? "high" : "medium",
      });
    }

    return res.json({
      ok: true,
      data: {
        summary: {
          pending_posts: pendingPosts,
          stale_pending_posts: stalePendingPosts,
          unresolved_reservations: unresolvedReservations,
          unresolved_reservation_units: unresolvedReservationUnits,
          waiting_for_courier: waitingForCourier,
          monitoring_errors_7d: errorEvents,
          monitoring_critical_7d: criticalErrors,
        },
        hotspots,
        error_sources_7d: sourceQ.rows.map((row) => ({
          source: row.source,
          total: Number(row.total) || 0,
        })),
      },
    });
  } catch (err) {
    console.error("admin.problemReport error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/monitoring/events", requireAuth, async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Доступ только создателю" });
    }
    const tenantId = req.user.tenant_id || null;
    const limitRaw = Number(req.query?.limit || 120);
    const limit = Number.isFinite(limitRaw)
      ? Math.max(20, Math.min(500, Math.floor(limitRaw)))
      : 120;

    const rows = await db.query(
      `SELECT id,
              tenant_id,
              user_id,
              scope,
              level,
              code,
              message,
              source,
              details,
              resolved,
              created_at
       FROM monitoring_events
       WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid OR tenant_id IS NULL)
       ORDER BY created_at DESC
       LIMIT $2`,
      [tenantId, limit],
    );
    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error("admin.monitoring.list error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.patch("/monitoring/events/:id/resolve", requireAuth, async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Доступ только создателю" });
    }
    const id = String(req.params?.id || "").trim();
    if (!isUuidLike(id)) {
      return res.status(400).json({ ok: false, error: "Некорректный id события" });
    }
    const tenantId = req.user.tenant_id || null;
    const upd = await db.query(
      `UPDATE monitoring_events
       SET resolved = true
       WHERE id = $1
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid OR tenant_id IS NULL)
       RETURNING id, resolved`,
      [id, tenantId],
    );
    if (upd.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Событие не найдено" });
    }
    return res.json({ ok: true, data: upd.rows[0] });
  } catch (err) {
    console.error("admin.monitoring.resolve error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
