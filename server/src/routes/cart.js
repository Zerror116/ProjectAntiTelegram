// server/src/routes/cart.js
const express = require('express');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();
const db = require('../db');
const { authMiddleware } = require('../utils/auth');
const { requireRole } = require('../utils/roles');

const CART_STATUSES = ['pending_processing', 'processed', 'in_delivery'];

function productMessageText(product) {
  const lines = [
    `🛒 ${product.title}`,
    product.description ? String(product.description).trim() : null,
    `ID товара: ${product.product_code ?? '—'}`,
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

    await client.query('BEGIN');
    const productQ = await client.query(
      `SELECT id, product_code, title, description, price, quantity, image_url, status
       FROM products
       WHERE id = $1
       LIMIT 1
       FOR UPDATE`,
      [productId]
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
      `SELECT id, quantity
       FROM cart_items
       WHERE user_id = $1 AND product_id = $2
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
      upsert = await client.query(
        `INSERT INTO cart_items (id, user_id, product_id, quantity, status, created_at, updated_at, reserved_sent_at)
         VALUES ($1, $2, $3, $4, 'pending_processing', now(), now(), NULL)
         RETURNING id, user_id, product_id, quantity, status, created_at, updated_at`,
        [uuidv4(), userId, productId, quantity]
      );
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
      }
    }

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
              p.image_url
       FROM cart_items c
       JOIN products p ON p.id = c.product_id
       WHERE c.user_id = $1
       ORDER BY c.created_at DESC`,
      [userId]
    );

    const items = result.rows.map((row) => ({
      ...row,
      line_total: Number(row.price) * Number(row.quantity),
    }));

    const totalSum = items.reduce((sum, item) => sum + item.line_total, 0);
    const processedSum = items
      .filter((item) => item.status === 'processed' || item.status === 'in_delivery')
      .reduce((sum, item) => sum + item.line_total, 0);

    return res.json({
      ok: true,
      data: {
        items,
        total_sum: totalSum,
        processed_sum: processedSum,
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

    const restored = await client.query(
      `UPDATE products
       SET quantity = quantity + $1,
           updated_at = now()
       WHERE id = $2
       RETURNING id, product_code, title, description, price, quantity, image_url, status`,
      [Number(item.quantity), item.product_id]
    );
    const updatedProduct = restored.rows[0];

    let removedReservedMessage = null;
    if (reservationQ.rowCount > 0) {
      const reservedMessageId = reservationQ.rows[0].reserved_channel_message_id;
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
    }

    await client.query('DELETE FROM cart_items WHERE id = $1', [cartItemId]);

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
      }
      if (removedReservedMessage) {
        io.to(`chat:${removedReservedMessage.chat_id}`).emit('chat:message:deleted', {
          chatId: removedReservedMessage.chat_id,
          messageId: removedReservedMessage.id,
        });
      }
    }

    return res.json({
      ok: true,
      data: {
        cart_item_id: cartItemId,
        product_id: item.product_id,
        status: 'cancelled',
        restored_quantity: Number(item.quantity),
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

// Изменить статус товара в корзине (admin/creator)
router.patch('/items/:id/status', authMiddleware, requireRole('admin', 'creator'), async (req, res) => {
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
    return res.json({ ok: true, data: upd.rows[0] });
  } catch (err) {
    console.error('cart.status error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

module.exports = router;
