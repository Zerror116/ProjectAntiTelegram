// server/src/routes/worker.js
const express = require('express');
const fs = require('fs');
const path = require('path');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();
const db = require('../db');
const { authMiddleware } = require('../utils/auth');
const { requireRole } = require('../utils/roles');
const { ensureSystemChannels } = require('../utils/systemChannels');
const { emitToTenant } = require('../utils/socket');

const productUploadsDir = path.resolve(__dirname, '..', '..', 'uploads', 'products');
fs.mkdirSync(productUploadsDir, { recursive: true });
const SAMARA_TZ = 'Europe/Samara';

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, productUploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || '').toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : '.jpg';
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    if (String(file.mimetype || '').startsWith('image/')) {
      cb(null, true);
      return;
    }
    cb(new Error('Можно загружать только изображения'));
  },
});

function uploadProductImage(req, res, next) {
  upload.single('image')(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === 'LIMIT_FILE_SIZE') {
      return res.status(400).json({ ok: false, error: 'Размер фото не должен превышать 8MB' });
    }
    return res.status(400).json({ ok: false, error: err.message || 'Некорректный файл' });
  });
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function toAbsoluteImageUrl(req, file) {
  if (!file || !file.filename) return null;
  return `${req.protocol}://${req.get('host')}/uploads/products/${file.filename}`;
}

function normalizeImageUrl(value) {
  if (value == null) return null;
  const trimmed = String(value).trim();
  return trimmed ? trimmed : null;
}

function parseSettings(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  return raw;
}

function toPositiveNumber(value, fallback = 0) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) return fallback;
  return n;
}

function toPositiveInteger(value, fallback = 1) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.floor(n);
}

function hasAtLeastTwoLetters(value) {
  const letters = String(value || '').match(/[A-Za-zА-Яа-яЁё]/g) || [];
  return letters.length >= 2;
}

function isIsoDay(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || '').trim());
}

function parseRevisionDates(value) {
  if (Array.isArray(value)) {
    const normalized = value
      .map((item) => String(item || '').trim())
      .filter((item) => item && isIsoDay(item));
    return Array.from(new Set(normalized)).slice(0, 2);
  }
  if (typeof value === 'string') {
    const normalized = value
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item && isIsoDay(item));
    return Array.from(new Set(normalized)).slice(0, 2);
  }
  return [];
}

function roundPriceToStep(value, step = 50, min = 50) {
  const n = Number(value);
  if (!Number.isFinite(n)) return min;
  const rounded = Math.round(n / step) * step;
  return Math.max(min, rounded);
}

function toShelfNumber(value, fallback = 1) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.floor(n);
}

function formatProductLabel(productCode, shelfNumber) {
  const code = Number(productCode);
  const shelf = Number(shelfNumber);
  const codePart = Number.isFinite(code) && code > 0 ? String(Math.floor(code)) : '—';
  const shelfPart = Number.isFinite(shelf) && shelf > 0
    ? String(Math.floor(shelf)).padStart(2, '0')
    : '—';
  return `${codePart}--${shelfPart}`;
}

function toBoolean(value, fallback = false) {
  if (typeof value === 'boolean') return value;
  const normalized = String(value ?? '').trim().toLowerCase();
  if (!normalized) return fallback;
  return ['1', 'true', 'yes', 'y', 'on'].includes(normalized);
}

function productMessageText(product) {
  const lines = [
    `🛒 ${product.title}`,
    product.description ? String(product.description).trim() : null,
    `Цена: ${product.price} RUB`,
    `Количество в наличии: ${product.quantity}`,
    'Нажмите "Купить", чтобы добавить в корзину',
  ].filter(Boolean);
  return lines.join('\n');
}

function normalizeRevisionEntry(raw) {
  const item = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const title = String(item.title || '').trim();
  const description = String(item.description || '').trim();
  const price = Number(item.price);
  const quantity = Number(item.quantity);
  const shelfNumber = Number(item.shelf_number);
  return {
    product_id: String(item.product_id || '').trim(),
    message_id: String(item.message_id || '').trim(),
    title,
    description,
    price,
    quantity,
    shelf_number: shelfNumber,
    image_url: normalizeImageUrl(item.image_url),
  };
}

async function fetchRevisionDays(client, channelId, limit = 2) {
  const safeLimit = Math.min(Math.max(Number(limit) || 2, 1), 10);
  const q = await client.query(
    `SELECT to_char((m.created_at AT TIME ZONE $2), 'YYYY-MM-DD') AS day,
            to_char((m.created_at AT TIME ZONE $2), 'DD.MM.YYYY') AS label,
            COUNT(*)::int AS posts
     FROM messages m
     WHERE m.chat_id = $1
       AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
     GROUP BY day, label
     ORDER BY day DESC
     LIMIT $3`,
    [channelId, SAMARA_TZ, safeLimit]
  );
  return q.rows;
}

async function fetchRevisionPosts(client, channelId, selectedDates) {
  const dateFilter = Array.isArray(selectedDates) && selectedDates.length > 0 ? selectedDates : null;
  const rows = await client.query(
    `SELECT m.id AS message_id,
            m.chat_id,
            m.created_at,
            m.text,
            m.meta,
            p.id AS product_id,
            p.product_code,
            p.shelf_number AS product_shelf_number,
            p.title AS product_title,
            p.description AS product_description,
            p.price AS product_price,
            p.quantity AS product_quantity,
            p.image_url AS product_image_url
     FROM messages m
     LEFT JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
     WHERE m.chat_id = $1
       AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       AND (
         $2::text[] IS NULL
         OR to_char((m.created_at AT TIME ZONE $3), 'YYYY-MM-DD') = ANY($2::text[])
       )
     ORDER BY m.created_at DESC`,
    [channelId, dateFilter, SAMARA_TZ]
  );
  return rows.rows.map((row) => {
    const meta = parseSettings(row.meta);
    const fallbackPrice = toPositiveNumber(meta.price, 0);
    const fallbackQuantity = toPositiveInteger(meta.quantity, 1);
    const fallbackImage = normalizeImageUrl(meta.image_url);
    return {
      message_id: row.message_id,
      chat_id: row.chat_id,
      created_at: row.created_at,
      text: row.text,
      meta,
      product_id: row.product_id || meta.product_id || null,
      product_code: row.product_code ?? meta.product_code ?? null,
      shelf_number: Number(row.product_shelf_number ?? meta.shelf_number ?? 1),
      title: String(row.product_title || '').trim(),
      description: String(row.product_description || '').trim(),
      price: Number(row.product_price ?? fallbackPrice),
      quantity: Number(row.product_quantity ?? fallbackQuantity),
      image_url: normalizeImageUrl(row.product_image_url) || fallbackImage,
    };
  });
}

async function allocateProductCode(client) {
  await client.query('LOCK TABLE products IN SHARE ROW EXCLUSIVE MODE');

  const reusable = await client.query(
    `SELECT product_code
     FROM products
     WHERE status = 'archived'
       AND reusable_at IS NOT NULL
       AND reusable_at <= now()
       AND product_code IS NOT NULL
     ORDER BY reusable_at ASC
     LIMIT 1
     FOR UPDATE`
  );

  if (reusable.rowCount > 0) {
    const code = reusable.rows[0].product_code;
    await client.query(
      `UPDATE products
       SET product_code = NULL,
           updated_at = now()
       WHERE status = 'archived' AND product_code = $1`,
      [code]
    );
    return code;
  }

  const nextRes = await client.query('SELECT COALESCE(MAX(product_code), 0) + 1 AS next_code FROM products');
  return Number(nextRes.rows[0].next_code);
}

async function getAllowedPostChannels(userRole, tenantId = null) {
  const role = String(userRole || '').toLowerCase().trim();
  if (!['worker', 'admin', 'tenant', 'creator'].includes(role)) {
    return [];
  }

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const { mainChannel } = await ensureSystemChannels(
      client,
      null,
      tenantId || null,
    );
    await client.query('COMMIT');
    return [
      {
        ...mainChannel,
        settings: parseSettings(mainChannel.settings),
      },
    ];
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Список каналов, доступных для очереди публикаций
router.get('/channels', authMiddleware, requireRole('worker', 'admin', 'creator'), async (req, res) => {
  try {
    const data = await getAllowedPostChannels(req.user?.role, req.user?.tenant_id || null);
    return res.json({ ok: true, data });
  } catch (err) {
    console.error('worker.channels.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Поиск старых товаров по названию/описанию
router.get('/products/search', authMiddleware, requireRole('worker', 'admin', 'creator'), async (req, res) => {
  try {
    const q = String(req.query.q || '').trim();
    if (!q) return res.json({ ok: true, data: [] });

    const result = await db.query(
      `WITH ranked AS (
         SELECT p.id,
                p.product_code,
                p.shelf_number,
                p.title,
                p.description,
                p.price,
                p.quantity,
                p.image_url,
                p.status,
                p.created_at,
                p.updated_at,
                ROW_NUMBER() OVER (
                  PARTITION BY LOWER(TRIM(p.title))
                  ORDER BY p.created_at DESC, p.updated_at DESC
                ) AS title_rank
         FROM products p
         WHERE (p.title ILIKE $1 OR p.description ILIKE $1)
           AND EXISTS (
             SELECT 1
             FROM product_publication_queue q
             JOIN chats c ON c.id = q.channel_id
             WHERE q.product_id = p.id
               AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
           )
       )
       SELECT id, product_code, shelf_number, title, description, price, quantity, image_url, status, created_at, updated_at
       FROM ranked
       WHERE title_rank <= 2
       ORDER BY created_at DESC, updated_at DESC
       LIMIT 30`,
      [`%${q}%`, req.user?.tenant_id || null]
    );
    return res.json({ ok: true, data: result.rows });
  } catch (err) {
    console.error('worker.products.search error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Добавить новый товар в очередь публикации
router.post(
  '/channels/:chatId/posts',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  uploadProductImage,
  async (req, res) => {
    const { chatId } = req.params;
    const client = await db.pool.connect();
    try {
      const {
        title,
        description = '',
        price,
        quantity = 1,
        shelf_number,
      } = req.body || {};

      const imageUrl = req.file ? toAbsoluteImageUrl(req, req.file) : normalizeImageUrl(req.body?.image_url);
      const normalizedTitle = String(title || '').trim();
      if (!normalizedTitle) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
      }
      if (!imageUrl) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Фото товара обязательно' });
      }

      const normalizedPrice = toPositiveNumber(price, -1);
      if (normalizedPrice <= 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Цена товара должна быть больше нуля' });
      }
      const rawQuantity = quantity == null || quantity === '' ? 1 : Number(quantity);
      if (!Number.isFinite(rawQuantity) || rawQuantity <= 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Количество должно быть больше нуля' });
      }
      const normalizedQuantity = Math.floor(rawQuantity);
      const rawShelf = shelf_number == null || shelf_number === '' ? 1 : Number(shelf_number);
      if (!Number.isFinite(rawShelf) || rawShelf <= 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Номер полки должен быть больше нуля' });
      }
      const normalizedShelfNumber = Math.floor(rawShelf);
      const normalizedDescription = String(description || '').trim();
      if (!hasAtLeastTwoLetters(normalizedDescription)) {
        removeUploadedFile(req.file);
        return res.status(400).json({
          ok: false,
          error: 'Описание должно содержать минимум 2 буквы',
        });
      }

      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );
      if (String(chatId) !== String(mainChannel.id)) {
        await client.query('ROLLBACK');
        removeUploadedFile(req.file);
        return res.status(403).json({
          ok: false,
          error: 'Публикация доступна только в Основной канал',
          data: { main_channel_id: mainChannel.id },
        });
      }

      const code = await allocateProductCode(client);

      const productInsert = await client.query(
        `INSERT INTO products (id, title, description, price, quantity, shelf_number, image_url, created_by, status, created_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'draft', now(), now())
         RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status`,
        [
          uuidv4(),
          normalizedTitle,
          normalizedDescription,
          normalizedPrice,
          normalizedQuantity,
          normalizedShelfNumber,
          imageUrl,
          req.user.id,
        ]
      );
      const productId = productInsert.rows[0].id;
      const productCodeUpdate = await client.query(
        `UPDATE products
         SET product_code = $1,
             updated_at = now()
         WHERE id = $2
         RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status`,
        [code, productId]
      );
      const product = productCodeUpdate.rows[0];

      const payload = {
        title: product.title,
        description: product.description,
        price: Number(product.price),
        quantity: Number(product.quantity),
        shelf_number: Number(product.shelf_number),
        image_url: product.image_url,
      };

      const queueInsert = await client.query(
        `INSERT INTO product_publication_queue (id, product_id, channel_id, queued_by, status, is_sent, payload, created_at)
         VALUES ($1, $2, $3, $4, 'pending', false, $5::jsonb, now())
         RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
        [uuidv4(), product.id, mainChannel.id, req.user.id, JSON.stringify(payload)]
      );

      await client.query('COMMIT');

      return res.status(201).json({
        ok: true,
        data: {
          queue: queueInsert.rows[0],
          product,
          product_label: formatProductLabel(product.product_code, product.shelf_number),
          message: 'Товар отправлен в очередь. Пост появится после подтверждения админом/создателем.',
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      removeUploadedFile(req.file);
      console.error('worker.channels.post_product error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

// Переиспользование старого товара (обновить и снова отправить в очередь)
router.post(
  '/products/:productId/requeue',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  uploadProductImage,
  async (req, res) => {
    const { productId } = req.params;
    const client = await db.pool.connect();
    try {
      const {
        channel_id,
        title,
        description,
        price,
        quantity,
        shelf_number,
      } = req.body || {};

      if (!channel_id) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'channel_id обязателен' });
      }

      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );
      if (String(channel_id) !== String(mainChannel.id)) {
        await client.query('ROLLBACK');
        removeUploadedFile(req.file);
        return res.status(403).json({
          ok: false,
          error: 'Переотправка доступна только в Основной канал',
          data: { main_channel_id: mainChannel.id },
        });
      }

      const productQ = await client.query(
        `SELECT id, product_code, shelf_number, title, description, price, quantity, image_url
         FROM products
         WHERE id = $1
           AND EXISTS (
             SELECT 1
             FROM product_publication_queue q
             JOIN chats c ON c.id = q.channel_id
             WHERE q.product_id = products.id
               AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
           )
         LIMIT 1`,
        [productId, req.user?.tenant_id || null]
      );
      if (productQ.rowCount === 0) {
        removeUploadedFile(req.file);
        return res.status(404).json({ ok: false, error: 'Товар не найден' });
      }
      const current = productQ.rows[0];

      const nextTitle = String(title || current.title || '').trim();
      const nextDescription = String(description ?? current.description ?? '').trim();
      const nextPrice = price != null ? toPositiveNumber(price, -1) : Number(current.price);
      const nextQuantity =
        quantity != null && quantity !== ''
          ? Number(quantity)
          : Number(current.quantity || 1);
      const nextShelfNumber =
        shelf_number != null && shelf_number !== ''
          ? Number(shelf_number)
          : Number(current.shelf_number || 1);
      let nextImageUrl = current.image_url;
      if (req.file) {
        nextImageUrl = toAbsoluteImageUrl(req, req.file);
      } else if (Object.prototype.hasOwnProperty.call(req.body || {}, 'image_url')) {
        nextImageUrl = normalizeImageUrl(req.body.image_url);
      }

      if (!nextTitle) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
      }
      if (!hasAtLeastTwoLetters(nextDescription)) {
        removeUploadedFile(req.file);
        return res.status(400).json({
          ok: false,
          error: 'Описание должно содержать минимум 2 буквы',
        });
      }
      if (!Number.isFinite(nextPrice) || nextPrice <= 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Цена товара должна быть больше нуля' });
      }
      if (!Number.isFinite(nextQuantity) || nextQuantity <= 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({
          ok: false,
          error: 'Количество должно быть больше нуля',
        });
      }
      if (!Number.isFinite(nextShelfNumber) || nextShelfNumber <= 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({
          ok: false,
          error: 'Номер полки должен быть больше нуля',
        });
      }
      if (!nextImageUrl) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Фото товара обязательно' });
      }

      const nextCode = current.product_code != null
        ? Number(current.product_code)
        : await allocateProductCode(client);

      const upd = await client.query(
        `UPDATE products
         SET title = $1,
             description = $2,
             price = $3,
             quantity = $4,
             shelf_number = $5,
             image_url = $6,
             product_code = $7,
             status = 'draft',
             updated_at = now()
         WHERE id = $8
         RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status`,
        [
          nextTitle,
          nextDescription,
          nextPrice,
          Math.floor(nextQuantity),
          Math.floor(nextShelfNumber),
          nextImageUrl,
          nextCode,
          productId,
        ]
      );
      const product = upd.rows[0];

      const payload = {
        title: product.title,
        description: product.description,
        price: Number(product.price),
        quantity: Number(product.quantity),
        shelf_number: Number(product.shelf_number),
        image_url: product.image_url,
      };

      const queueInsert = await client.query(
        `INSERT INTO product_publication_queue (id, product_id, channel_id, queued_by, status, is_sent, payload, created_at)
         VALUES ($1, $2, $3, $4, 'pending', false, $5::jsonb, now())
         RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
        [uuidv4(), product.id, mainChannel.id, req.user.id, JSON.stringify(payload)]
      );

      await client.query('COMMIT');

      return res.status(201).json({
        ok: true,
        data: {
          queue: queueInsert.rows[0],
          product,
          product_label: formatProductLabel(product.product_code, product.shelf_number),
          message: 'Товар переотправлен в очередь',
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      removeUploadedFile(req.file);
      console.error('worker.products.requeue error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.get(
  '/queue/mine',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
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
                p.product_code,
                p.shelf_number AS product_shelf_number,
                p.title AS product_title,
                p.description AS product_description,
                p.price AS product_price,
                p.quantity AS product_quantity,
                p.image_url AS product_image_url
         FROM product_publication_queue q
         JOIN products p ON p.id = q.product_id
         JOIN chats c ON c.id = q.channel_id
         WHERE q.queued_by = $1
           AND q.status = 'pending'
           AND COALESCE(q.is_sent, false) = false
         ORDER BY q.created_at DESC`,
        [req.user.id]
      );
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error('worker.queue.mine error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

router.patch(
  '/queue/:queueId',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  async (req, res) => {
    const queueId = String(req.params.queueId || '').trim();
    const title = String(req.body?.title || '').trim();
    const description = String(req.body?.description || '').trim();
    const price = Number(req.body?.price);
    const quantity = Number(req.body?.quantity);
    const shelfNumber = Number(req.body?.shelf_number);

    if (!queueId) {
      return res.status(400).json({ ok: false, error: 'queueId обязателен' });
    }
    if (!title) {
      return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
    }
    if (!hasAtLeastTwoLetters(description)) {
      return res.status(400).json({
        ok: false,
        error: 'Описание должно содержать минимум 2 буквы',
      });
    }
    if (!Number.isFinite(price) || price <= 0) {
      return res.status(400).json({ ok: false, error: 'Цена должна быть больше нуля' });
    }
    if (!Number.isFinite(quantity) || quantity <= 0) {
      return res.status(400).json({ ok: false, error: 'Количество должно быть больше нуля' });
    }
    if (!Number.isFinite(shelfNumber) || shelfNumber <= 0) {
      return res.status(400).json({ ok: false, error: 'Номер полки должен быть больше нуля' });
    }

    try {
      const result = await db.query(
        `WITH target AS (
           SELECT q.id, q.product_id
           FROM product_publication_queue q
           WHERE q.id = $1
             AND q.queued_by = $2
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
           LIMIT 1
         ),
         product_upd AS (
           UPDATE products p
           SET title = $3,
               description = $4,
               price = $5,
               quantity = $6,
               shelf_number = $7,
               updated_at = now()
           FROM target t
           WHERE p.id = t.product_id
           RETURNING p.id, p.title, p.description, p.price, p.quantity, p.shelf_number, p.image_url
         )
         UPDATE product_publication_queue q
         SET payload = jsonb_strip_nulls(
               jsonb_build_object(
                 'title', $3,
                 'description', $4,
                 'price', $5,
                 'quantity', $6,
                 'shelf_number', $7,
                 'image_url', (SELECT image_url FROM product_upd LIMIT 1)
               )
             )
         WHERE q.id = $1
           AND EXISTS (SELECT 1 FROM target)
         RETURNING q.id`,
        [
          queueId,
          req.user.id,
          title,
          description,
          price,
          Math.floor(quantity),
          Math.floor(shelfNumber),
        ]
      );
      if (result.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: 'Пост не найден, уже опубликован или не принадлежит вам',
        });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error('worker.queue.patch error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

router.get(
  '/revision/dates',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id || null
      );
      const days = await fetchRevisionDays(client, mainChannel.id, 2);
      await client.query('COMMIT');
      return res.json({ ok: true, data: days });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.dates error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.get(
  '/revision/posts',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  async (req, res) => {
    const selectedDates = parseRevisionDates(req.query?.dates);
    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id || null
      );
      const fallbackDays = selectedDates.length > 0
        ? selectedDates
        : (await fetchRevisionDays(client, mainChannel.id, 2)).map((x) => x.day);
      const posts = await fetchRevisionPosts(client, mainChannel.id, fallbackDays);
      await client.query('COMMIT');
      return res.json({
        ok: true,
        data: {
          dates: fallbackDays,
          posts,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.posts error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.post(
  '/revision/manual',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  async (req, res) => {
    const entries = Array.isArray(req.body?.entries) ? req.body.entries : [];
    if (!entries.length) {
      return res.status(400).json({ ok: false, error: 'Передайте entries для ручной ревизии' });
    }
    if (entries.length > 200) {
      return res.status(400).json({ ok: false, error: 'Слишком много позиций за один запрос' });
    }

    const normalized = entries.map(normalizeRevisionEntry);
    for (const item of normalized) {
      if (!item.product_id && !item.message_id) {
        return res.status(400).json({
          ok: false,
          error: 'Для каждой позиции нужен product_id или message_id',
        });
      }
      if (!item.title) {
        return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
      }
      if (!hasAtLeastTwoLetters(item.description)) {
        return res.status(400).json({
          ok: false,
          error: 'Описание должно содержать минимум 2 буквы',
        });
      }
      if (!Number.isFinite(item.price) || item.price <= 0) {
        return res.status(400).json({ ok: false, error: 'Цена должна быть больше нуля' });
      }
      if (!Number.isFinite(item.quantity) || item.quantity <= 0) {
        return res.status(400).json({ ok: false, error: 'Количество должно быть больше нуля' });
      }
      if (Number.isFinite(item.shelf_number) && item.shelf_number <= 0) {
        return res.status(400).json({ ok: false, error: 'Номер полки должен быть больше нуля' });
      }
    }

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id || null
      );

      const updatedMessages = [];

      for (const item of normalized) {
        let targetQ;
        if (item.message_id) {
          targetQ = await client.query(
            `SELECT m.id AS message_id,
                    m.chat_id,
                    m.meta,
                    p.id AS product_id,
                    p.product_code,
                    p.shelf_number AS product_shelf_number,
                    p.title AS product_title,
                    p.description AS product_description,
                    p.price AS product_price,
                    p.quantity AS product_quantity,
                    p.image_url AS product_image_url
             FROM messages m
             LEFT JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
             WHERE m.id = $1
               AND m.chat_id = $2
               AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
             LIMIT 1`,
            [item.message_id, mainChannel.id]
          );
        } else {
          targetQ = await client.query(
            `SELECT m.id AS message_id,
                    m.chat_id,
                    m.meta,
                    p.id AS product_id,
                    p.product_code,
                    p.shelf_number AS product_shelf_number,
                    p.title AS product_title,
                    p.description AS product_description,
                    p.price AS product_price,
                    p.quantity AS product_quantity,
                    p.image_url AS product_image_url
             FROM messages m
             JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
             WHERE p.id = $1::uuid
               AND m.chat_id = $2
               AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
               AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
             ORDER BY m.created_at DESC
             LIMIT 1`,
            [item.product_id, mainChannel.id]
          );
        }

        if (targetQ.rowCount === 0) {
          continue;
        }
        const target = targetQ.rows[0];
        const productId = String(target.product_id || '').trim();
        if (!productId) {
          continue;
        }

        const nextQuantity = Math.floor(item.quantity);
        const nextShelfNumber =
          Number.isFinite(item.shelf_number) && item.shelf_number > 0
            ? Math.floor(item.shelf_number)
            : toShelfNumber(target.product_shelf_number, 1);
        const nextPrice = roundPriceToStep(item.price, 50, 50);
        const nextImageUrl = item.image_url || normalizeImageUrl(target.product_image_url) || null;

        const productUpdate = await client.query(
          `UPDATE products
           SET title = $1,
               description = $2,
               price = $3,
               quantity = $4,
               shelf_number = $5,
               image_url = $6,
               status = CASE WHEN status = 'archived' THEN 'published' ELSE status END,
               updated_at = now()
           WHERE id = $7::uuid
           RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url`,
          [
            item.title,
            item.description,
            nextPrice,
            nextQuantity,
            nextShelfNumber,
            nextImageUrl,
            productId,
          ]
        );
        if (productUpdate.rowCount === 0) {
          continue;
        }
        const product = productUpdate.rows[0];

        const messageUpdate = await client.query(
          `UPDATE messages
           SET text = $1,
               meta = jsonb_strip_nulls(
                 COALESCE(meta, '{}'::jsonb)
                 || jsonb_build_object(
                    'kind', 'catalog_product',
                    'product_id', $2::text,
                    'product_code', $3::int,
                    'price', $4::numeric,
                    'quantity', $5::int,
                    'shelf_number', $6::int,
                    'image_url', $7::text
                  )
               )
           WHERE id = $8
             AND chat_id = $9
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            productMessageText(product),
            product.id,
            product.product_code,
            Number(product.price),
            Number(product.quantity),
            Number(product.shelf_number),
            product.image_url,
            target.message_id,
            mainChannel.id,
          ]
        );
        if (messageUpdate.rowCount > 0) {
          updatedMessages.push(messageUpdate.rows[0]);
        }
      }

      await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [mainChannel.id]);
      await client.query('COMMIT');

      const io = req.app.get('io');
      if (io) {
        for (const message of updatedMessages) {
          io.to(`chat:${mainChannel.id}`).emit('chat:message', {
            chatId: mainChannel.id,
            message,
          });
        }
        if (updatedMessages.length > 0) {
          emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
            chatId: mainChannel.id,
          });
        }
      }

      return res.json({
        ok: true,
        data: {
          updated_count: updatedMessages.length,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.manual error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.post(
  '/revision/auto',
  authMiddleware,
  requireRole('worker', 'admin', 'creator'),
  async (req, res) => {
    const dates = parseRevisionDates(req.body?.dates);
    const percent = Number(req.body?.percent);
    const hideOldVersions = toBoolean(req.body?.hide_old_versions, true);

    if (!Number.isFinite(percent) || percent < -95 || percent > 500) {
      return res.status(400).json({
        ok: false,
        error: 'Процент ревизии должен быть в диапазоне от -95 до 500',
      });
    }

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id || null
      );
      const selectedDates = dates.length > 0
        ? dates
        : (await fetchRevisionDays(client, mainChannel.id, 2)).map((x) => x.day);
      const posts = await fetchRevisionPosts(client, mainChannel.id, selectedDates);

      const groups = new Map();
      for (const post of posts) {
        const productId = String(post.product_id || '').trim();
        if (!productId) continue;
        if (!groups.has(productId)) groups.set(productId, []);
        groups.get(productId).push(post);
      }

      const keepPosts = [];
      const hideMessageIds = [];
      for (const list of groups.values()) {
        list.sort((a, b) => Date.parse(String(b.created_at)) - Date.parse(String(a.created_at)));
        keepPosts.push(list[0]);
        if (hideOldVersions) {
          for (const old of list.slice(1)) {
            if (old.message_id) hideMessageIds.push(old.message_id);
          }
        }
      }

      const queuedItems = [];
      let reusedPendingCount = 0;

      for (const post of keepPosts) {
        const productId = String(post.product_id || '').trim();
        if (!productId) continue;
        const basePrice = Number(post.price || 0);
        if (!Number.isFinite(basePrice) || basePrice <= 0) continue;

        const revisedPrice = roundPriceToStep(
          basePrice * (1 + percent / 100),
          50,
          50
        );
        const nextQuantity = toPositiveInteger(post.quantity, 1);
        const nextShelfNumber = toShelfNumber(post.shelf_number, 1);
        const title = String(post.title || '').trim();
        if (!title) continue;
        const description = String(post.description || '').trim();
        const imageUrl = normalizeImageUrl(post.image_url);

        const payload = {
          title,
          description,
          price: revisedPrice,
          quantity: nextQuantity,
          shelf_number: nextShelfNumber,
          image_url: imageUrl,
          revision_auto: true,
          source_message_id: String(post.message_id || '').trim() || null,
          hide_old_versions: hideOldVersions,
          revision_dates: selectedDates,
        };

        const existingPendingQ = await client.query(
          `SELECT id
           FROM product_publication_queue
           WHERE product_id = $1::uuid
             AND channel_id = $2::uuid
             AND status = 'pending'
             AND COALESCE(is_sent, false) = false
           ORDER BY created_at DESC
           LIMIT 1
           FOR UPDATE`,
          [productId, mainChannel.id]
        );

        if (existingPendingQ.rowCount > 0) {
          reusedPendingCount += 1;
          const queueId = existingPendingQ.rows[0].id;
          await client.query(
            `UPDATE product_publication_queue
             SET payload = $1::jsonb,
                 queued_by = $2,
                 created_at = now(),
                 approved_by = NULL,
                 approved_at = NULL
             WHERE id = $3`,
            [JSON.stringify(payload), req.user.id, queueId]
          );
          queuedItems.push({
            queue_id: queueId,
            product_id: productId,
            mode: 'updated_pending',
          });
        } else {
          const insertedQueue = await client.query(
            `INSERT INTO product_publication_queue (
               id,
               product_id,
               channel_id,
               queued_by,
               status,
               is_sent,
               payload,
               created_at
             )
             VALUES ($1, $2::uuid, $3::uuid, $4, 'pending', false, $5::jsonb, now())
             RETURNING id`,
            [
              uuidv4(),
              productId,
              mainChannel.id,
              req.user.id,
              JSON.stringify(payload),
            ]
          );
          queuedItems.push({
            queue_id: insertedQueue.rows[0].id,
            product_id: productId,
            mode: 'created_pending',
          });
        }
      }

      // hide_old_versions applies later, when admin publishes queued posts.
      // Keeping channel untouched here is intentional.
      if (hideMessageIds.length > 0) {
        // keep variable used for future compatibility in response/debug
      }
      await client.query('COMMIT');

      const io = req.app.get('io');
      if (io) {
        if (queuedItems.length > 0) {
          emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
            chatId: mainChannel.id,
          });
        }
      }

      return res.json({
        ok: true,
        data: {
          dates: selectedDates,
          percent,
          updated_count: queuedItems.length,
          hidden_old_count: 0,
          queued_count: queuedItems.length,
          reused_pending_count: reusedPendingCount,
          queued_items: queuedItems,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.auto error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

module.exports = router;
