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

const productUploadsDir = path.resolve(__dirname, '..', '..', 'uploads', 'products');
fs.mkdirSync(productUploadsDir, { recursive: true });

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

async function getAllowedPostChannels(userRole) {
  const role = String(userRole || '').toLowerCase().trim();
  if (!['worker', 'admin', 'creator'].includes(role)) {
    return [];
  }

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const { mainChannel } = await ensureSystemChannels(client, null);
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
    const data = await getAllowedPostChannels(req.user?.role);
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
      `SELECT id, product_code, title, description, price, quantity, image_url, status, updated_at
       FROM products
       WHERE title ILIKE $1 OR description ILIKE $1
       ORDER BY updated_at DESC
       LIMIT 30`,
      [`%${q}%`]
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
      if (normalizedPrice < 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Некорректная цена товара' });
      }
      const normalizedQuantity = toPositiveInteger(quantity, 1);

      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(client, req.user.id);
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
        `INSERT INTO products (id, title, description, price, quantity, image_url, created_by, status, created_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, 'draft', now(), now())
         RETURNING id, product_code, title, description, price, quantity, image_url, status`,
        [
          uuidv4(),
          normalizedTitle,
          String(description || '').trim(),
          normalizedPrice,
          normalizedQuantity,
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
         RETURNING id, product_code, title, description, price, quantity, image_url, status`,
        [code, productId]
      );
      const product = productCodeUpdate.rows[0];

      const payload = {
        title: product.title,
        description: product.description,
        price: Number(product.price),
        quantity: Number(product.quantity),
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
      } = req.body || {};

      if (!channel_id) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'channel_id обязателен' });
      }

      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(client, req.user.id);
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
        `SELECT id, product_code, title, description, price, quantity, image_url
         FROM products
         WHERE id = $1
         LIMIT 1`,
        [productId]
      );
      if (productQ.rowCount === 0) {
        removeUploadedFile(req.file);
        return res.status(404).json({ ok: false, error: 'Товар не найден' });
      }
      const current = productQ.rows[0];

      const nextTitle = String(title || current.title || '').trim();
      const nextDescription = String(description ?? current.description ?? '').trim();
      const nextPrice = price != null ? toPositiveNumber(price, -1) : Number(current.price);
      const nextQuantity = quantity != null ? toPositiveInteger(quantity, 1) : Number(current.quantity || 1);
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
      if (!Number.isFinite(nextPrice) || nextPrice < 0) {
        removeUploadedFile(req.file);
        return res.status(400).json({ ok: false, error: 'Некорректная цена товара' });
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
             image_url = $5,
             product_code = $6,
             status = 'draft',
             updated_at = now()
         WHERE id = $7
         RETURNING id, product_code, title, description, price, quantity, image_url, status`,
        [nextTitle, nextDescription, nextPrice, nextQuantity, nextImageUrl, nextCode, productId]
      );
      const product = upd.rows[0];

      const payload = {
        title: product.title,
        description: product.description,
        price: Number(product.price),
        quantity: Number(product.quantity),
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

module.exports = router;
