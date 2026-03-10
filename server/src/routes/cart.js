// server/src/routes/cart.js
const express = require('express');
const fs = require('fs');
const path = require('path');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();
const db = require('../db');
const { authMiddleware } = require('../utils/auth');
const { requireRole } = require('../utils/roles');
const requirePermission = require('../middleware/requirePermission');
const { emitToTenant } = require('../utils/socket');
const { guardAction } = require('../utils/antifraud');

const requireReservationFulfillPermission = requirePermission('reservation.fulfill');
const requireDeliveryManagePermission = requirePermission('delivery.manage');

const CART_STATUSES = [
  'pending_processing',
  'processed',
  'preparing_delivery',
  'handing_to_courier',
  'in_delivery',
  'delivered',
];
const CLAIM_TYPES = new Set(['return', 'discount']);
const CLAIM_STATUSES = new Set([
  'pending',
  'approved_return',
  'approved_discount',
  'rejected',
  'settled',
]);

const claimsUploadsDir = path.resolve(__dirname, '..', '..', 'uploads', 'claims');
fs.mkdirSync(claimsUploadsDir, { recursive: true });

const claimImageUploadEngine = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, claimsUploadsDir),
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

function toMoney(value, fallback = 0) {
  const raw = Number(value);
  const normalized = Number.isFinite(raw) ? raw : Number(fallback || 0);
  return Math.round(normalized * 100) / 100;
}

function emitCartUpdated(req, userId, payload = {}) {
  const io = req.app.get('io');
  if (!io || !userId) return;
  io.to(`user:${userId}`).emit('cart:updated', {
    userId: String(userId),
    ...payload,
  });
}

function emitClaimUpdated(req, claim, reason = 'claim_updated') {
  const io = req.app.get('io');
  if (!io || !claim) return;
  const payload = {
    reason,
    claim_id: String(claim.id || ''),
    user_id: String(claim.user_id || ''),
    status: String(claim.status || ''),
    claim_type: String(claim.claim_type || ''),
    approved_amount: toMoney(claim.approved_amount),
    requested_amount: toMoney(claim.requested_amount),
    updated_at: claim.updated_at || null,
  };
  emitToTenant(
    io,
    claim.tenant_id || req.user?.tenant_id || null,
    'claims:updated',
    payload,
  );
  if (claim.user_id) {
    io.to(`user:${claim.user_id}`).emit('claims:updated', payload);
  }
}

function uploadClaimImage(req, res, next) {
  claimImageUploadEngine.single('image')(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === 'LIMIT_FILE_SIZE') {
      return res.status(400).json({ ok: false, error: 'Размер фото не должен превышать 8MB' });
    }
    return res.status(400).json({ ok: false, error: err.message || 'Некорректный файл' });
  });
}

function toAbsoluteClaimImageUrl(req, file) {
  if (!file || !file.filename) return '';
  return `${req.protocol}://${req.get('host')}/uploads/claims/${file.filename}`;
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

// Добавить товар в корзину
router.post('/add', authMiddleware, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const userId = req.user.id;
    const productId = String(req.body?.product_id || '').trim();
    const qtyRaw = Number(req.body?.quantity ?? 1);
    const quantity = Number.isFinite(qtyRaw) && qtyRaw > 0 ? Math.floor(qtyRaw) : 1;

    if (!productId) {
      return res.status(400).json({ ok: false, error: 'product_id обязателен' });
    }

    const antifraud = await guardAction({
      queryable: client,
      tenantId: req.user?.tenant_id || null,
      userId,
      actionKey: 'cart.buy',
      details: {
        product_id: productId,
        quantity,
      },
    });
    if (!antifraud.allowed) {
      return res.status(429).json({
        ok: false,
        error: antifraud.reason || 'Слишком много попыток покупки. Повторите позже.',
        blocked_until: antifraud.blockedUntil || null,
      });
    }

    await client.query('BEGIN');
    const productQ = await client.query(
      `SELECT id, product_code, title, description, price, quantity, image_url, status
       FROM products
       WHERE id = $1
         AND EXISTS (
           SELECT 1
           FROM product_publication_queue q
           JOIN chats c ON c.id = q.channel_id
           WHERE q.product_id = products.id
             AND q.status = 'published'
             AND COALESCE(q.is_sent, false) = true
             AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
         )
       LIMIT 1
       FOR UPDATE`,
      [productId, req.user?.tenant_id || null]
    );
    if (productQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Товар не найден' });
    }

    const product = productQ.rows[0];
    if (product.status !== 'published') {
      await client.query('ROLLBACK');
      return res.status(400).json({ ok: false, error: 'Товар пока недоступен для покупки' });
    }

    const availableNow = Number(product.quantity) || 0;
    if (availableNow <= 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: 'Товар закончился',
        data: {
          available_to_add: 0,
          requested: quantity,
          in_stock: availableNow,
        },
      });
    }

    if (quantity > availableNow) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: `Можно купить не более ${availableNow} шт.`,
        data: {
          available_to_add: availableNow,
          requested: quantity,
          in_stock: availableNow,
        },
      });
    }

    const productUpd = await client.query(
      `UPDATE products
       SET quantity = quantity - $1,
           updated_at = now()
       WHERE id = $2
       RETURNING id, product_code, title, description, price, quantity, image_url, status`,
      [quantity, productId]
    );
    const updatedProduct = productUpd.rows[0];

    const existingQ = await client.query(
      `SELECT id, quantity, status
       FROM cart_items
       WHERE user_id = $1
         AND product_id = $2
         AND status = 'pending_processing'
       ORDER BY created_at DESC
       LIMIT 1
       FOR UPDATE`,
      [userId, productId]
    );

    let upsert;
    if (existingQ.rowCount > 0) {
      const existing = existingQ.rows[0];
      const newQty = (Number(existing.quantity) || 0) + quantity;
      upsert = await client.query(
        `UPDATE cart_items
         SET quantity = $1,
             status = 'pending_processing',
             reserved_sent_at = NULL,
             updated_at = now()
         WHERE id = $2
         RETURNING id, user_id, product_id, quantity, status, created_at, updated_at`,
        [newQty, existing.id]
      );
    } else {
      try {
        upsert = await client.query(
          `INSERT INTO cart_items (id, user_id, product_id, quantity, status, created_at, updated_at, reserved_sent_at)
           VALUES ($1, $2, $3, $4, 'pending_processing', now(), now(), NULL)
           RETURNING id, user_id, product_id, quantity, status, created_at, updated_at`,
          [uuidv4(), userId, productId, quantity]
        );
      } catch (insertErr) {
        const isLegacyUnique =
          String(insertErr?.code || '') === '23505' &&
          String(insertErr?.constraint || '') === 'cart_items_user_id_product_id_key';
        if (!isLegacyUnique) throw insertErr;

        // Fallback for legacy schema where cart_items still has UNIQUE(user_id, product_id).
        const existingAnyQ = await client.query(
          `SELECT id, quantity
           FROM cart_items
           WHERE user_id = $1
             AND product_id = $2
           ORDER BY updated_at DESC NULLS LAST, created_at DESC
           LIMIT 1
           FOR UPDATE`,
          [userId, productId]
        );
        if (existingAnyQ.rowCount === 0) throw insertErr;
        const existingAny = existingAnyQ.rows[0];
        const mergedQty = (Number(existingAny.quantity) || 0) + quantity;
        upsert = await client.query(
          `UPDATE cart_items
           SET quantity = $1,
               status = 'pending_processing',
               reserved_sent_at = NULL,
               updated_at = now()
           WHERE id = $2
           RETURNING id, user_id, product_id, quantity, status, created_at, updated_at`,
          [mergedQty, existingAny.id]
        );
      }
    }
    const cartItem = upsert.rows[0];

    const reservationQ = await client.query(
      `SELECT id
       FROM reservations
       WHERE cart_item_id = $1
       LIMIT 1
       FOR UPDATE`,
      [cartItem.id]
    );
    if (reservationQ.rowCount > 0) {
      await client.query(
        `UPDATE reservations
         SET user_id = $1,
             product_id = $2,
             quantity = $3,
             is_fulfilled = false,
             is_sent = false,
             fulfilled_at = NULL,
             sent_at = NULL,
             reserved_channel_message_id = NULL,
             updated_at = now()
         WHERE id = $4`,
        [userId, productId, Number(cartItem.quantity), reservationQ.rows[0].id]
      );
    } else {
      await client.query(
        `INSERT INTO reservations (
           id, user_id, product_id, cart_item_id, quantity,
           is_fulfilled, is_sent, created_at, updated_at
         )
         VALUES ($1, $2, $3, $4, $5, false, false, now(), now())`,
        [uuidv4(), userId, productId, cartItem.id, Number(cartItem.quantity)]
      );
    }

    const msgUpdate = await client.query(
      `UPDATE messages
       SET text = $1,
           meta = jsonb_set(
             COALESCE(meta, '{}'::jsonb),
             '{quantity}',
             to_jsonb($2::int),
             true
           )
       WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
         AND COALESCE(meta->>'product_id', '') = $3
       RETURNING id, chat_id, sender_id, text, meta, created_at`,
      [productMessageText(updatedProduct), Number(updatedProduct.quantity), productId]
    );

    await client.query('COMMIT');

    const io = req.app.get('io');
    if (io && msgUpdate.rowCount > 0) {
      for (const message of msgUpdate.rows) {
        io.to(`chat:${message.chat_id}`).emit('chat:message', {
          chatId: message.chat_id,
          message,
        });
        emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
          chatId: message.chat_id,
        });
      }
    }

    emitCartUpdated(req, userId, {
      product_id: productId,
      cart_item_id: cartItem.id,
      status: cartItem.status,
      available_in_stock: Number(updatedProduct.quantity),
      reason: 'item_added',
    });

    return res.status(201).json({
      ok: true,
      data: {
        item: cartItem,
        product: updatedProduct,
        available_to_add: Number(updatedProduct.quantity),
      },
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('cart.add error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

// Корзина пользователя и суммы
router.get('/', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const result = await db.query(
      `SELECT c.id,
              c.product_id,
              c.quantity,
              c.status,
              c.created_at,
              c.updated_at,
              p.product_code,
              p.title,
              p.description,
              p.price,
              p.image_url,
              delivery.delivery_date,
              delivery.courier_name,
              delivery.courier_code,
              delivery.eta_from,
              delivery.eta_to,
              delivery.delivery_status AS delivery_batch_status
       FROM cart_items c
       JOIN products p ON p.id = c.product_id
       LEFT JOIN LATERAL (
         SELECT b.delivery_date,
               cst.courier_name,
               cst.courier_code,
               cst.eta_from,
               cst.eta_to,
               cst.delivery_status
         FROM delivery_batch_items di
         JOIN delivery_batch_customers cst ON cst.id = di.batch_customer_id
         JOIN delivery_batches b ON b.id = di.batch_id
         WHERE di.cart_item_id = c.id
           AND cst.delivery_status IN (
             'preparing_delivery',
             'handing_to_courier',
             'in_delivery'
           )
         ORDER BY b.created_at DESC
         LIMIT 1
       ) AS delivery ON true
       WHERE c.user_id = $1
         AND c.status <> 'delivered'
       ORDER BY
         CASE c.status
           WHEN 'pending_processing' THEN 0
           WHEN 'processed' THEN 1
           WHEN 'preparing_delivery' THEN 2
           WHEN 'handing_to_courier' THEN 3
           WHEN 'in_delivery' THEN 4
           ELSE 5
         END,
         c.updated_at DESC,
         c.created_at DESC`,
      [userId]
    );

    const recentDeliveriesQ = await db.query(
      `WITH latest_batches AS (
         SELECT DISTINCT b.id,
                b.delivery_date,
                b.delivery_label,
                COALESCE(b.completed_at, b.updated_at, b.created_at) AS completed_at
         FROM delivery_batches b
         JOIN delivery_batch_customers cst ON cst.batch_id = b.id
         JOIN delivery_batch_items di ON di.batch_customer_id = cst.id
         JOIN cart_items c ON c.id = di.cart_item_id
         WHERE c.user_id = $1
           AND c.status = 'delivered'
           AND b.status = 'completed'
         ORDER BY COALESCE(b.completed_at, b.updated_at, b.created_at) DESC, b.id DESC
         LIMIT 2
       )
       SELECT lb.id::text AS batch_id,
              lb.delivery_date,
              lb.delivery_label,
              lb.completed_at,
              c.id AS cart_item_id,
              c.product_id,
              c.quantity,
              c.status,
              c.created_at,
              c.updated_at,
              p.product_code,
              p.title,
              p.description,
              p.price,
              p.image_url
       FROM latest_batches lb
       JOIN delivery_batch_items di ON di.batch_id = lb.id
       JOIN cart_items c ON c.id = di.cart_item_id
       JOIN products p ON p.id = c.product_id
       WHERE c.user_id = $1
         AND c.status = 'delivered'
       ORDER BY lb.completed_at DESC, c.updated_at DESC, c.created_at DESC`,
      [userId],
    );

    const claimsQ = await db.query(
      `SELECT cc.id,
              cc.user_id,
              cc.cart_item_id,
              cc.product_id,
              cc.delivery_batch_id,
              cc.claim_type,
              cc.status,
              cc.description,
              cc.image_url,
              cc.requested_amount,
              cc.approved_amount,
              cc.resolution_note,
              cc.handled_by,
              cc.handled_at,
              cc.settled_at,
              cc.created_at,
              cc.updated_at,
              p.title AS product_title,
              p.image_url AS product_image_url,
              COALESCE(NULLIF(BTRIM(handler.name), ''), NULLIF(BTRIM(handler.email), ''), '') AS handled_by_name
       FROM customer_claims cc
       LEFT JOIN products p ON p.id = cc.product_id
       LEFT JOIN users handler ON handler.id = cc.handled_by
       WHERE cc.user_id = $1
       ORDER BY cc.created_at DESC
       LIMIT 50`,
      [userId],
    );

    const grouped = new Map();
    for (const row of result.rows) {
      const normalized = {
        ...row,
        price: Number(row.price) || 0,
        quantity: Number(row.quantity) || 0,
      };
      normalized.line_total = normalized.price * normalized.quantity;

      const shouldAggregate =
        normalized.status === 'processed' || normalized.status === 'in_delivery';
      if (!shouldAggregate) {
        grouped.set(`single:${normalized.id}`, normalized);
        continue;
      }

      const key = `group:${normalized.product_id}:${normalized.status}`;
      if (!grouped.has(key)) {
        grouped.set(key, normalized);
        continue;
      }

      const existing = grouped.get(key);
      const mergedQuantity =
        (Number(existing.quantity) || 0) + (Number(normalized.quantity) || 0);
      const existingUpdatedAt = new Date(
        existing.updated_at || existing.created_at || 0,
      ).getTime();
      const nextUpdatedAt = new Date(
        normalized.updated_at || normalized.created_at || 0,
      ).getTime();

      grouped.set(key, {
        ...existing,
        quantity: mergedQuantity,
        line_total: (Number(existing.price) || 0) * mergedQuantity,
        updated_at:
          nextUpdatedAt > existingUpdatedAt
            ? normalized.updated_at
            : existing.updated_at,
        created_at:
          nextUpdatedAt > existingUpdatedAt
            ? normalized.created_at
            : existing.created_at,
        merged_item_ids: [
          ...(Array.isArray(existing.merged_item_ids)
            ? existing.merged_item_ids
            : [existing.id]),
          normalized.id,
        ],
      });
    }

    const items = Array.from(grouped.values()).sort((a, b) => {
      const statusOrder = {
        pending_processing: 0,
        processed: 1,
        in_delivery: 2,
      };
      const aOrder = statusOrder[a.status] ?? 3;
      const bOrder = statusOrder[b.status] ?? 3;
      if (aOrder != bOrder) return aOrder - bOrder;

      const aTime = new Date(a.updated_at || a.created_at || 0).getTime();
      const bTime = new Date(b.updated_at || b.created_at || 0).getTime();
      return bTime - aTime;
    });

    const totalSum = items.reduce((sum, item) => sum + item.line_total, 0);
    const processedStatuses = new Set([
      'processed',
      'preparing_delivery',
      'handing_to_courier',
      'in_delivery',
    ]);
    const processedSum = items
      .filter((item) => processedStatuses.has(item.status))
      .reduce((sum, item) => sum + item.line_total, 0);
    const approvedClaimsTotal = claimsQ.rows
      .filter((row) =>
        ['approved_return', 'approved_discount', 'settled'].includes(
          String(row.status || ''),
        ),
      )
      .reduce((sum, row) => sum + toMoney(row.approved_amount), 0);
    const adjustedProcessedSum = Math.max(0, toMoney(processedSum - approvedClaimsTotal));

    const recentDeliveriesMap = new Map();
    for (const row of recentDeliveriesQ.rows) {
      const batchId = String(row.batch_id || '').trim();
      if (!batchId) continue;
      const normalized = {
        ...row,
        id: row.cart_item_id,
        price: Number(row.price) || 0,
        quantity: Number(row.quantity) || 0,
      };
      normalized.line_total = normalized.price * normalized.quantity;
      if (!recentDeliveriesMap.has(batchId)) {
        recentDeliveriesMap.set(batchId, {
          batch_id: batchId,
          delivery_date: row.delivery_date,
          delivery_label: row.delivery_label,
          completed_at: row.completed_at,
          total_sum: 0,
          items_count: 0,
          items: [],
        });
      }
      const bucket = recentDeliveriesMap.get(batchId);
      bucket.total_sum += normalized.line_total;
      bucket.items_count += normalized.quantity;
      bucket.items.push(normalized);
    }

    const recentDeliveries = Array.from(recentDeliveriesMap.values()).sort((a, b) => {
      const aTime = new Date(a.completed_at || a.delivery_date || 0).getTime();
      const bTime = new Date(b.completed_at || b.delivery_date || 0).getTime();
      return bTime - aTime;
    });

    const claims = claimsQ.rows.map((row) => ({
      ...row,
      requested_amount: toMoney(row.requested_amount),
      approved_amount: toMoney(row.approved_amount),
    }));

    return res.json({
      ok: true,
      data: {
        items,
        total_sum: totalSum,
        processed_sum: adjustedProcessedSum,
        processed_sum_raw: toMoney(processedSum),
        claims_total: toMoney(approvedClaimsTotal),
        recent_deliveries: recentDeliveries,
        claims,
      },
    });
  } catch (err) {
    console.error('cart.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Отказ от товара пользователем (только пока не обработан)
router.delete('/items/:id', authMiddleware, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const userId = req.user.id;
    const cartItemId = String(req.params?.id || '').trim();
    if (!cartItemId) {
      return res.status(400).json({ ok: false, error: 'id позиции обязателен' });
    }

    await client.query('BEGIN');

    const itemQ = await client.query(
      `SELECT c.id,
              c.user_id,
              c.product_id,
              c.quantity,
              c.status,
              p.id AS p_id,
              p.product_code,
              p.title,
              p.description,
              p.price,
              p.quantity AS product_quantity,
              p.image_url,
              p.status AS product_status
       FROM cart_items c
       JOIN products p ON p.id = c.product_id
       WHERE c.id = $1
       LIMIT 1
       FOR UPDATE OF c, p`,
      [cartItemId]
    );

    if (itemQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Позиция не найдена' });
    }

    const item = itemQ.rows[0];
    if (String(item.user_id) !== String(userId)) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Это не ваша позиция корзины' });
    }

    if (String(item.status) !== 'pending_processing') {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: 'Отказ невозможен: товар уже обработан',
        data: { status: item.status },
      });
    }

    const reservationQ = await client.query(
      `SELECT id, reserved_channel_message_id
       FROM reservations
       WHERE cart_item_id = $1
       LIMIT 1
       FOR UPDATE`,
      [cartItemId]
    );

    const itemQuantity = Number(item.quantity) || 0;
    const requestedCancelRaw = Number(req.body?.quantity ?? itemQuantity);
    const cancelQuantity = Number.isFinite(requestedCancelRaw) && requestedCancelRaw > 0
      ? Math.min(itemQuantity, Math.floor(requestedCancelRaw))
      : itemQuantity;
    if (cancelQuantity <= 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({ ok: false, error: 'Некорректное количество для отказа' });
    }
    const remainingQuantity = Math.max(0, itemQuantity - cancelQuantity);

    const restored = await client.query(
      `UPDATE products
       SET quantity = quantity + $1,
           updated_at = now()
       WHERE id = $2
       RETURNING id, product_code, title, description, price, quantity, image_url, status`,
      [cancelQuantity, item.product_id]
    );
    const updatedProduct = restored.rows[0];

    let removedReservedMessage = null;
    let updatedReservedMessage = null;
    if (reservationQ.rowCount > 0) {
      const reservedMessageId = reservationQ.rows[0].reserved_channel_message_id;
      if (remainingQuantity <= 0) {
        if (reservedMessageId) {
          const removedMsg = await client.query(
            `DELETE FROM messages
             WHERE id = $1
             RETURNING id, chat_id`,
            [reservedMessageId]
          );
          if (removedMsg.rowCount > 0) {
            removedReservedMessage = removedMsg.rows[0];
          }
        }
        await client.query('DELETE FROM reservations WHERE id = $1', [reservationQ.rows[0].id]);
      } else {
        await client.query(
          `UPDATE reservations
           SET quantity = $1,
               updated_at = now()
           WHERE id = $2`,
          [remainingQuantity, reservationQ.rows[0].id],
        );
        if (reservedMessageId) {
          const updatedMsg = await client.query(
            `UPDATE messages
             SET meta = jsonb_set(
                   COALESCE(meta, '{}'::jsonb),
                   '{quantity}',
                   to_jsonb($2::int),
                   true
                 )
             WHERE id = $1
             RETURNING id, chat_id, sender_id, text, meta, created_at`,
            [reservedMessageId, remainingQuantity],
          );
          if (updatedMsg.rowCount > 0) {
            updatedReservedMessage = updatedMsg.rows[0];
          }
        }
      }
    }

    if (remainingQuantity <= 0) {
      await client.query('DELETE FROM cart_items WHERE id = $1', [cartItemId]);
    } else {
      await client.query(
        `UPDATE cart_items
         SET quantity = $1,
             updated_at = now()
         WHERE id = $2`,
        [remainingQuantity, cartItemId],
      );
    }

    const msgUpdate = await client.query(
      `UPDATE messages
       SET text = $1,
           meta = jsonb_set(
             COALESCE(meta, '{}'::jsonb),
             '{quantity}',
             to_jsonb($2::int),
             true
           )
       WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
         AND COALESCE(meta->>'product_id', '') = $3
       RETURNING id, chat_id, sender_id, text, meta, created_at`,
      [productMessageText(updatedProduct), Number(updatedProduct.quantity), String(item.product_id)]
    );

    await client.query('COMMIT');

    const io = req.app.get('io');
    if (io) {
      for (const message of msgUpdate.rows) {
        io.to(`chat:${message.chat_id}`).emit('chat:message', {
          chatId: message.chat_id,
          message,
        });
        emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
          chatId: message.chat_id,
        });
      }
      if (updatedReservedMessage) {
        io.to(`chat:${updatedReservedMessage.chat_id}`).emit('chat:message', {
          chatId: updatedReservedMessage.chat_id,
          message: updatedReservedMessage,
        });
        emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
          chatId: updatedReservedMessage.chat_id,
        });
      }
      if (removedReservedMessage) {
        io.to(`chat:${removedReservedMessage.chat_id}`).emit('chat:message:deleted', {
          chatId: removedReservedMessage.chat_id,
          messageId: removedReservedMessage.id,
        });
        emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
          chatId: removedReservedMessage.chat_id,
        });
      }
    }

    emitCartUpdated(req, userId, {
      product_id: item.product_id,
      cart_item_id: cartItemId,
      status: remainingQuantity > 0 ? 'pending_processing' : 'cancelled',
      available_in_stock: Number(updatedProduct.quantity),
      reason: remainingQuantity > 0 ? 'item_cancelled_partial' : 'item_cancelled',
    });

    return res.json({
      ok: true,
      data: {
        cart_item_id: cartItemId,
        product_id: item.product_id,
        status: remainingQuantity > 0 ? 'pending_processing' : 'cancelled',
        restored_quantity: cancelQuantity,
        remaining_quantity: remainingQuantity,
        available_in_stock: Number(updatedProduct.quantity),
      },
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    console.error('cart.cancel error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.post('/claims/upload-image', authMiddleware, uploadClaimImage, async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ ok: false, error: 'Файл не получен' });
    }
    return res.status(201).json({
      ok: true,
      data: {
        image_url: toAbsoluteClaimImageUrl(req, req.file),
      },
    });
  } catch (err) {
    console.error('cart.claims.uploadImage error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Изменить статус товара в корзине (admin/creator)
router.patch(
  '/items/:id/status',
  authMiddleware,
  requireRole('admin', 'creator'),
  requireReservationFulfillPermission,
  async (req, res) => {
  try {
    const { id } = req.params;
    const status = String(req.body?.status || '').trim();
    if (!CART_STATUSES.includes(status)) {
      return res.status(400).json({ ok: false, error: 'Некорректный статус' });
    }

    const upd = await db.query(
      `UPDATE cart_items
       SET status = $1,
           updated_at = now()
       WHERE id = $2
       RETURNING id, user_id, product_id, quantity, status, created_at, updated_at`,
      [status, id]
    );
    if (upd.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Позиция не найдена' });
    }
    const item = upd.rows[0];
    emitCartUpdated(req, item.user_id, {
      product_id: item.product_id,
      cart_item_id: item.id,
      status: item.status,
      reason: 'status_changed',
    });
    return res.json({ ok: true, data: item });
  } catch (err) {
    console.error('cart.status error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Создать заявку на брак/скидку по доставленному товару
router.post('/claims', authMiddleware, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const userId = String(req.user?.id || '').trim();
    const tenantId = req.user?.tenant_id || null;
    const cartItemId = String(req.body?.cart_item_id || '').trim();
    const claimType = String(req.body?.claim_type || 'return')
      .trim()
      .toLowerCase();
    const description = String(req.body?.description || '').trim();
    const imageUrl = String(req.body?.image_url || '').trim();
    const requestedRaw = req.body?.requested_amount;

    if (!cartItemId) {
      return res.status(400).json({ ok: false, error: 'cart_item_id обязателен' });
    }
    if (!CLAIM_TYPES.has(claimType)) {
      return res.status(400).json({ ok: false, error: 'Некорректный тип заявки' });
    }
    if (description.length < 5) {
      return res.status(400).json({
        ok: false,
        error: 'Опишите проблему минимум в 5 символов',
      });
    }

    await client.query('BEGIN');
    const itemQ = await client.query(
      `SELECT c.id,
              c.user_id,
              c.product_id,
              c.quantity,
              c.status,
              p.title,
              p.price,
              p.image_url
       FROM cart_items c
       JOIN products p ON p.id = c.product_id
       WHERE c.id = $1
       LIMIT 1
       FOR UPDATE`,
      [cartItemId],
    );
    if (itemQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Товар не найден в корзине' });
    }
    const item = itemQ.rows[0];
    if (String(item.user_id) !== userId) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Это не ваш товар' });
    }
    if (String(item.status) !== 'delivered') {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: 'Заявку можно создать только по доставленному товару',
      });
    }

    const existingOpenQ = await client.query(
      `SELECT id, status
       FROM customer_claims
       WHERE cart_item_id = $1
         AND status IN ('pending', 'approved_return', 'approved_discount')
       ORDER BY created_at DESC
       LIMIT 1`,
      [cartItemId],
    );
    if (existingOpenQ.rowCount > 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error: 'По этому товару уже есть активная заявка',
      });
    }

    const lineTotal = toMoney(Number(item.price || 0) * Number(item.quantity || 0));
    const requestedAmountInput = toMoney(requestedRaw, lineTotal);
    const requestedAmount = Math.max(
      0,
      Math.min(lineTotal, Number.isFinite(requestedAmountInput) ? requestedAmountInput : lineTotal),
    );

    const batchQ = await client.query(
      `SELECT b.id
       FROM delivery_batch_items di
       JOIN delivery_batch_customers cst ON cst.id = di.batch_customer_id
       JOIN delivery_batches b ON b.id = di.batch_id
       WHERE di.cart_item_id = $1
         AND cst.user_id = $2
       ORDER BY COALESCE(b.completed_at, b.updated_at, b.created_at) DESC
       LIMIT 1`,
      [cartItemId, userId],
    );

    const insertQ = await client.query(
      `INSERT INTO customer_claims (
         id, tenant_id, user_id, cart_item_id, product_id, delivery_batch_id,
         claim_type, status, description, image_url,
         requested_amount, approved_amount, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5, $6,
         $7, 'pending', $8, $9,
         $10, 0, now(), now()
       )
       RETURNING *`,
      [
        uuidv4(),
        tenantId,
        userId,
        cartItemId,
        item.product_id,
        batchQ.rowCount > 0 ? batchQ.rows[0].id : null,
        claimType,
        description,
        imageUrl || null,
        requestedAmount,
      ],
    );

    await client.query('COMMIT');
    const claim = insertQ.rows[0];
    emitCartUpdated(req, userId, {
      cart_item_id: cartItemId,
      reason: 'claim_created',
      claim_id: claim.id,
    });
    emitClaimUpdated(req, claim, 'claim_created');
    return res.status(201).json({
      ok: true,
      data: {
        ...claim,
        requested_amount: toMoney(claim.requested_amount),
        approved_amount: toMoney(claim.approved_amount),
      },
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {}
    if (String(err?.code || '') === '23505') {
      return res.status(400).json({
        ok: false,
        error: 'По этому товару уже есть активная заявка',
      });
    }
    console.error('cart.claims.create error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

// Список заявок текущего клиента
router.get('/claims', authMiddleware, async (req, res) => {
  try {
    const userId = String(req.user?.id || '').trim();
    const result = await db.query(
      `SELECT cc.id,
              cc.user_id,
              cc.cart_item_id,
              cc.product_id,
              cc.delivery_batch_id,
              cc.claim_type,
              cc.status,
              cc.description,
              cc.image_url,
              cc.requested_amount,
              cc.approved_amount,
              cc.resolution_note,
              cc.handled_by,
              cc.handled_at,
              cc.settled_at,
              cc.created_at,
              cc.updated_at,
              p.title AS product_title,
              p.image_url AS product_image_url,
              COALESCE(NULLIF(BTRIM(handler.name), ''), NULLIF(BTRIM(handler.email), ''), '') AS handled_by_name
       FROM customer_claims cc
       LEFT JOIN products p ON p.id = cc.product_id
       LEFT JOIN users handler ON handler.id = cc.handled_by
       WHERE cc.user_id = $1
       ORDER BY cc.created_at DESC`,
      [userId],
    );
    return res.json({
      ok: true,
      data: result.rows.map((row) => ({
        ...row,
        requested_amount: toMoney(row.requested_amount),
        approved_amount: toMoney(row.approved_amount),
      })),
    });
  } catch (err) {
    console.error('cart.claims.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Админ/создатель: список заявок в tenant
router.get(
  '/claims/admin',
  authMiddleware,
  requireRole('admin', 'creator', 'tenant'),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const tenantId = req.user?.tenant_id || null;
      const status = String(req.query?.status || '')
        .trim()
        .toLowerCase();
      const statusFilter = CLAIM_STATUSES.has(status) ? status : null;
      const result = await db.query(
        `SELECT cc.id,
                cc.tenant_id,
                cc.user_id,
                cc.cart_item_id,
                cc.product_id,
                cc.delivery_batch_id,
                cc.claim_type,
                cc.status,
                cc.description,
                cc.image_url,
                cc.requested_amount,
                cc.approved_amount,
                cc.resolution_note,
                cc.handled_by,
                cc.handled_at,
                cc.settled_at,
                cc.created_at,
                cc.updated_at,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
                u.email AS customer_email,
                ph.phone AS customer_phone,
                p.title AS product_title,
                p.image_url AS product_image_url,
                COALESCE(NULLIF(BTRIM(handler.name), ''), NULLIF(BTRIM(handler.email), ''), '') AS handled_by_name
         FROM customer_claims cc
         JOIN users u ON u.id = cc.user_id
         LEFT JOIN LATERAL (
           SELECT phone
           FROM phones
           WHERE user_id = u.id
           ORDER BY created_at DESC
           LIMIT 1
         ) ph ON true
         LEFT JOIN products p ON p.id = cc.product_id
         LEFT JOIN users handler ON handler.id = cc.handled_by
         WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
           AND ($2::text IS NULL OR cc.status = $2::text)
         ORDER BY
           CASE cc.status
             WHEN 'pending' THEN 0
             WHEN 'approved_return' THEN 1
             WHEN 'approved_discount' THEN 2
             WHEN 'rejected' THEN 3
             WHEN 'settled' THEN 4
             ELSE 5
           END,
           cc.created_at DESC
         LIMIT 300`,
        [tenantId, statusFilter],
      );
      return res.json({
        ok: true,
        data: result.rows.map((row) => ({
          ...row,
          requested_amount: toMoney(row.requested_amount),
          approved_amount: toMoney(row.approved_amount),
        })),
      });
    } catch (err) {
      console.error('cart.claims.admin.list error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  },
);

function normalizeClaimDecision(raw) {
  const value = String(raw || '')
    .trim()
    .toLowerCase();
  if (value === 'approve_return' || value === 'approved_return') {
    return 'approved_return';
  }
  if (value === 'approve_discount' || value === 'approved_discount') {
    return 'approved_discount';
  }
  if (value === 'reject' || value === 'rejected') {
    return 'rejected';
  }
  if (value === 'settle' || value === 'settled') {
    return 'settled';
  }
  return '';
}

// Админ/создатель: решение по заявке
router.patch(
  '/claims/:id/review',
  authMiddleware,
  requireRole('admin', 'creator', 'tenant'),
  requireDeliveryManagePermission,
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      const claimId = String(req.params?.id || '').trim();
      const decision = normalizeClaimDecision(req.body?.decision);
      const resolutionNote = String(req.body?.resolution_note || '').trim();
      const approvedAmountInput = toMoney(req.body?.approved_amount, NaN);
      if (!claimId) {
        return res.status(400).json({ ok: false, error: 'id заявки обязателен' });
      }
      if (!decision) {
        return res.status(400).json({ ok: false, error: 'Некорректное решение' });
      }

      await client.query('BEGIN');
      const claimQ = await client.query(
        `SELECT cc.*
         FROM customer_claims cc
         WHERE cc.id = $1
           AND ($2::uuid IS NULL OR cc.tenant_id = $2::uuid)
         LIMIT 1
         FOR UPDATE`,
        [claimId, req.user?.tenant_id || null],
      );
      if (claimQ.rowCount === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ ok: false, error: 'Заявка не найдена' });
      }
      const claim = claimQ.rows[0];
      const currentStatus = String(claim.status || '');
      if (!CLAIM_STATUSES.has(currentStatus)) {
        await client.query('ROLLBACK');
        return res.status(400).json({ ok: false, error: 'Некорректный статус заявки' });
      }
      if (currentStatus === 'settled' && decision !== 'settled') {
        await client.query('ROLLBACK');
        return res.status(400).json({
          ok: false,
          error: 'Заявка уже закрыта',
        });
      }

      let nextApprovedAmount = toMoney(claim.approved_amount, 0);
      let settledAt = claim.settled_at || null;
      if (decision === 'approved_return' || decision === 'approved_discount') {
        if (Number.isFinite(approvedAmountInput) && approvedAmountInput > 0) {
          nextApprovedAmount = toMoney(approvedAmountInput);
        } else {
          nextApprovedAmount = toMoney(claim.requested_amount, 0);
        }
      } else if (decision === 'rejected') {
        nextApprovedAmount = 0;
      } else if (decision === 'settled') {
        if (currentStatus !== 'approved_return' && currentStatus !== 'approved_discount') {
          await client.query('ROLLBACK');
          return res.status(400).json({
            ok: false,
            error: 'Закрыть можно только подтвержденную заявку',
          });
        }
        settledAt = new Date().toISOString();
      }

      const upd = await client.query(
        `UPDATE customer_claims
         SET status = $2,
             approved_amount = $3,
             resolution_note = CASE WHEN $4::text <> '' THEN $4::text ELSE resolution_note END,
             handled_by = $5,
             handled_at = now(),
             settled_at = CASE
               WHEN $2::text = 'settled' THEN now()
               ELSE settled_at
             END,
             updated_at = now()
         WHERE id = $1
         RETURNING *`,
        [
          claimId,
          decision,
          nextApprovedAmount,
          resolutionNote,
          req.user?.id || null,
        ],
      );

      await client.query('COMMIT');
      const row = upd.rows[0];
      emitCartUpdated(req, row.user_id, {
        reason: 'claim_updated',
        claim_id: row.id,
      });
      emitClaimUpdated(req, row, 'claim_updated');
      return res.json({
        ok: true,
        data: {
          ...row,
          approved_amount: toMoney(row.approved_amount),
          requested_amount: toMoney(row.requested_amount),
          settled_at: settledAt,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('cart.claims.review error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  },
);

module.exports = router;
