// server/src/routes/admin.js
const express = require('express');
const router = express.Router();
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');
const db = require('../db'); // адаптируйте под ваш модуль БД

// Список пользователей
router.get('/users', requireAuth, requireRole('admin','creator'), async (req, res) => {
  try {
    const result = await db.query('SELECT id, email, role, created_at FROM users ORDER BY created_at DESC');
    res.json({ ok: true, data: result.rows });
  } catch (err) {
    res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// Назначить роль
router.post('/users/:id/role', requireAuth, requireRole('admin','creator'), async (req, res) => {
  const { id } = req.params;
  const { role } = req.body;
  const allowed = ['client','worker','admin','creator'];
  if (!allowed.includes(role)) return res.status(400).json({ error: 'Неправильная роль' });

  try {
    // Только creator может назначать creator
    if (role === 'creator' && req.user.role !== 'creator') {
      return res.status(403).json({ error: 'Только создатель способен на такое' });
    }
    await db.query('UPDATE users SET role = $1, updated_at = now() WHERE id = $2', [role, id]);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: 'Ошибка сервера' });
  }
});

module.exports = router;
