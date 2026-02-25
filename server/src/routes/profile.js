// server/src/routes/profile.js
const express = require('express');
const router = express.Router();
const db = require('../db');
const { authMiddleware } = require('../utils/auth');

// GET /api/profile
// Возвращаем user + phone (последняя запись) и статус телефона
router.get('/', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { rows } = await db.query(
      `SELECT u.id, u.email, u.name,
              p.phone, p.status as phone_status, p.verified_at
       FROM users u
       LEFT JOIN phones p ON p.user_id = u.id
       WHERE u.id = $1
       LIMIT 1`,
      [userId]
    );
    if (!rows.length) return res.status(404).json({ ok: false, error: 'User not found' });
    const row = rows[0];
    // Если phones может содержать несколько записей, можно выбрать последнюю по created_at; здесь предполагаем одна запись per user
    return res.json({ ok: true, user: {
      id: row.id,
      email: row.email,
      name: row.name || null,
      phone: row.phone || null,
      phone_status: row.phone_status || null,
      phone_verified_at: row.verified_at || null
    }});
  } catch (err) {
    console.error('profile.get error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// POST /api/profile/update
// body: { name }
router.post('/update', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { name } = req.body;
    if (typeof name !== 'string' || !name.trim()) return res.status(400).json({ ok: false, error: 'Name required' });

    const result = await db.query('UPDATE users SET name=$1 WHERE id=$2 RETURNING id, email, name', [name.trim(), userId]);
    if (!result.rowCount) return res.status(404).json({ ok: false, error: 'User not found' });
    return res.json({ ok: true, user: result.rows[0] });
  } catch (err) {
    console.error('profile.update error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

module.exports = router;
