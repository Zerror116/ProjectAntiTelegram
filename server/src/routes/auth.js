// server/src/routes/auth.js
const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const validator = require('validator');
const jwt = require('jsonwebtoken');
const db = require('../db'); // предполагается, что db экспортирует функцию query
const { authMiddleware } = require('../utils/auth');
require('dotenv').config();

const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

// Настройки для Creator
const CREATOR_EMAIL = 'zerotwo02166@gmail.com';
const CREATOR_SECRET = process.env.CREATOR_SECRET || 'Макарова Лиза';

function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}

/**
 * POST /api/auth/check_email
 * body: { email }
 */
router.post('/check_email', async (req, res) => {
  try {
    const { email } = req.body || {};
    if (!email) return res.status(400).json({ error: 'email required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email' });
    }

    const existing = await db.query('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]);
    return res.json({ exists: existing.rowCount > 0 });
  } catch (err) {
    console.error('check_email error', err);
    return res.status(500).json({ error: 'Server error' });
  }
});

/**
 * POST /api/auth/register
 * body: { email, password, name?, phone?, secret? }
 *
 * Notes:
 * - If email equals CREATOR_EMAIL and correct secret provided, role becomes 'creator'
 * - Returns { token, user: { id, email, name, role } }
 */
router.post('/register', async (req, res) => {
  try {
    const { email, password, name, phone, secret } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }
    if (typeof password !== 'string' || password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    await db.query('BEGIN');

    const existing = await db.query('SELECT id FROM users WHERE email = $1', [normalizedEmail]);
    if (existing.rowCount > 0) {
      await db.query('ROLLBACK');
      return res.status(409).json({ error: 'Email already registered' });
    }

    let role = 'client';
    if (normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase()) {
      if (typeof secret === 'string' && secret === CREATOR_SECRET) {
        role = 'creator';
      } else {
        await db.query('ROLLBACK');
        return res.status(403).json({ error: 'Invalid secret for this email' });
      }
    }

    const password_hash = await bcrypt.hash(password, SALT_ROUNDS);
    const insertUser = await db.query(
      'INSERT INTO users (email, password_hash, name, role, created_at) VALUES ($1, $2, $3, $4, now()) RETURNING id, email, name, role',
      [normalizedEmail, password_hash, name || null, role]
    );
    const user = insertUser.rows[0];

    if (phone) {
      const normalizedPhone = String(phone).replace(/\D/g, '');
      if (normalizedPhone.length < 10) {
        await db.query('ROLLBACK');
        return res.status(400).json({ error: 'Invalid phone format' });
      }
      await db.query(
        `INSERT INTO phones (user_id, phone, status, created_at)
         VALUES ($1, $2, 'pending_verification', now())
         ON CONFLICT (user_id) DO UPDATE SET phone = $2, status = 'pending_verification', created_at = now()`,
        [user.id, normalizedPhone]
      );
    }

    await db.query('COMMIT');

    const token = signToken({ id: user.id, email: user.email, role: user.role });

    return res.status(201).json({
      token,
      user: { id: user.id, email: user.email, name: user.name, role: user.role }
    });
  } catch (err) {
    try { await db.query('ROLLBACK'); } catch (_) {}
    console.error('auth.register error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/auth/login
 * body: { email, password }
 *
 * Returns { token, user: { id, email, role } }
 */
router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Неверный логин или пароль' });
    }

    const userRes = await db.query('SELECT id, email, password_hash, role FROM users WHERE email = $1', [normalizedEmail]);
    const user = userRes.rows[0];
    if (!user) return res.status(401).json({ error: 'Неверные данные' });

    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) return res.status(401).json({ error: 'Неверные данные' });

    const token = signToken({ id: user.id, email: user.email, role: user.role });
    return res.json({
      token,
      user: { id: user.id, email: user.email, role: user.role }
    });
  } catch (err) {
    console.error('auth.login error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/logout', (req, res) => {
  // Здесь можно делать audit, удалять refresh-токены и т.д.
  res.json({ ok: true, message: 'Logged out (stateless JWT)' });
});

/**
 * POST /api/auth/delete_account (защищённый)
 * Удаляет текущий аккаунт пользователя.
 */
router.post('/delete_account', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const result = await db.query('DELETE FROM users WHERE id = $1 RETURNING id', [userId]);
    if (result.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error('auth.delete_account error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

/**
 * POST /api/auth/change_password (защищённый)
 */
router.post('/change_password', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { oldPassword, newPassword } = req.body || {};
    if (!oldPassword || !newPassword || newPassword.length < 8) {
      return res.status(400).json({ error: 'Old and new password (min 8 chars) required' });
    }

    const { rows } = await db.query('SELECT password_hash FROM users WHERE id=$1', [userId]);
    if (!rows.length) return res.status(404).json({ error: 'Пользователь не найден' });

    const currentHash = rows[0].password_hash;
    const match = await bcrypt.compare(oldPassword, currentHash);
    if (!match) return res.status(403).json({ error: 'Старый пароль неверный' });

    const newHash = await bcrypt.hash(newPassword, SALT_ROUNDS);
    await db.query('UPDATE users SET password_hash=$1 WHERE id=$2', [newHash, userId]);

    return res.json({ ok: true, message: 'Пароль изменён' });
  } catch (err) {
    console.error('auth.change_password error', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

module.exports = router;
