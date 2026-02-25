// server/src/routes/phones.js
const express = require('express');
const router = express.Router();
const db = require('../db'); // pg client instance
const bcrypt = require('bcrypt');
const { authMiddleware: requireAuth, requireAdmin } = require('../utils/auth');

// Клиент: отправляет номер после регистрации
router.post('/request', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { phone } = req.body;
    if (!phone) return res.status(400).json({ error: 'Phone required' });

    // Нормализуем номер: оставляем только цифры
    const normalized = String(phone).replace(/\D/g, '');
    if (normalized.length < 10) return res.status(400).json({ error: 'Invalid phone format' });

    // Сначала пробуем обновить существующую запись
    const upd = await db.query(
      `UPDATE phones
       SET phone = $1, status = 'pending_verification', created_at = now()
       WHERE user_id = $2
       RETURNING id, phone, status`,
      [normalized, userId]
    );

    if (upd.rowCount > 0) {
      const phoneRow = upd.rows[0];
      return res.json({ ok: true, message: 'Phone updated as pending verification', phone: phoneRow });
    }

    // Если не было обновления — вставляем новую запись
    const insert = await db.query(
      `INSERT INTO phones (user_id, phone, status, created_at)
       VALUES ($1, $2, 'pending_verification', now())
       RETURNING id, phone, status`,
      [userId, normalized]
    );

    const phoneRow = insert.rows[0];
    return res.json({ ok: true, message: 'Phone saved as pending verification', phone: phoneRow });
  } catch (err) {
    console.error('phones.request error', err);
    return res.status(500).json({ error: 'Server error' });
  }
});

// Клиент: смена номера (требует подтверждения пароля)
router.post('/change', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { password, phone } = req.body;
    if (!password || !phone) return res.status(400).json({ error: 'password and phone required' });

    // Получаем хеш пароля пользователя
    const userRes = await db.query('SELECT password_hash FROM users WHERE id=$1', [userId]);
    if (!userRes.rowCount) return res.status(404).json({ error: 'User not found' });
    const passwordHash = userRes.rows[0].password_hash;

    const match = await bcrypt.compare(password, passwordHash);
    if (!match) return res.status(403).json({ error: 'Invalid password' });

    // Нормализуем телефон
    const normalized = String(phone).replace(/\D/g, '');
    if (normalized.length < 10) return res.status(400).json({ error: 'Invalid phone format' });

    // Сначала пробуем обновить существующую запись
    const upd = await db.query(
      `UPDATE phones
       SET phone = $1, status = 'pending_verification', created_at = now()
       WHERE user_id = $2
       RETURNING id, phone, status`,
      [normalized, userId]
    );

    if (upd.rowCount > 0) {
      const phoneRow = upd.rows[0];
      return res.json({ ok: true, message: 'Phone updated as pending verification', phone: phoneRow });
    }

    // Если не было обновления — вставляем новую запись
    const insert = await db.query(
      `INSERT INTO phones (user_id, phone, status, created_at)
       VALUES ($1, $2, 'pending_verification', now())
       RETURNING id, phone, status`,
      [userId, normalized]
    );

    const phoneRow = insert.rows[0];
    return res.json({ ok: true, message: 'Phone change requested', phone: phoneRow });
  } catch (err) {
    console.error('phones.change error', err);
    return res.status(500).json({ error: 'Server error' });
  }
});

// Admin: получить список pending номеров
router.get('/admin/pending', requireAdmin, async (req, res) => {
  try {
    const { rows } = await db.query(
      `SELECT p.id, p.user_id, p.phone, p.created_at, u.email
       FROM phones p
       JOIN users u ON u.id = p.user_id
       WHERE p.status = 'pending_verification'
       ORDER BY p.created_at ASC`
    );
    res.json({ ok: true, data: rows });
  } catch (err) {
    console.error('phones.admin.pending error', err);
    res.status(500).json({ error: 'Server error' });
  }
});

// Admin: подтвердить номер (пометить verified)
router.post('/admin/verify', requireAdmin, async (req, res) => {
  try {
    const { phoneId } = req.body;
    if (!phoneId) return res.status(400).json({ error: 'phoneId required' });

    const result = await db.query(
      `UPDATE phones SET status='verified', verified_at = now() WHERE id=$1 RETURNING user_id, phone`,
      [phoneId]
    );
    if (!result.rowCount) return res.status(404).json({ error: 'Phone not found' });

    const { user_id, phone } = result.rows[0];
    // audit
    await db.query(
      `INSERT INTO admin_actions (admin_id, action, target_user_id, target_phone, details) VALUES ($1,$2,$3,$4,$5)`,
      [req.user.id, 'verify_phone', user_id, phone, JSON.stringify({ phoneId })]
    );

    res.json({ ok: true });
  } catch (err) {
    console.error('phones.admin.verify error', err);
    res.status(500).json({ error: 'Server error' });
  }
});

// Admin: удалить номер и аккаунт пользователя
router.post('/admin/delete', requireAdmin, async (req, res) => {
  try {
    const { phoneId } = req.body;
    if (!phoneId) return res.status(400).json({ error: 'phoneId required' });

    // Получаем данные для аудита
    const { rows } = await db.query('SELECT user_id, phone FROM phones WHERE id=$1', [phoneId]);
    if (!rows.length) return res.status(404).json({ error: 'Phone not found' });
    const { user_id, phone } = rows[0];

    // Удаляем пользователя (CASCADE удалит phones, devices, tokens)
    await db.query('DELETE FROM users WHERE id=$1', [user_id]);

    // audit
    await db.query(
      `INSERT INTO admin_actions (admin_id, action, target_user_id, target_phone, details) VALUES ($1,$2,$3,$4,$5)`,
      [req.user.id, 'delete_phone_and_user', user_id, phone, JSON.stringify({ phoneId })]
    );

    res.json({ ok: true });
  } catch (err) {
    console.error('phones.admin.delete error', err);
    res.status(500).json({ error: 'Server error' });
  }
});

module.exports = router;
