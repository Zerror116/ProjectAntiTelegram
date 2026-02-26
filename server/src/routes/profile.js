const express = require('express');
const router = express.Router();
const { pool } = require('../db');
const authMiddleware = require('../middleware/requireAuth');

/**
 * GET /api/profile
 * Получить профиль текущего пользователя
 */
router.get('/', authMiddleware, async (req, res) => {
  try {
    console.log('PROFILE REQUEST for user:', req.user.id);

    const result = await pool.query(`
      SELECT 
        u.id,
        u.email,
        u.name,
        u.role,
        p.phone,
        p.status AS phone_status,
        p.verified_at AS phone_verified_at
      FROM users u
      LEFT JOIN phones p ON p.user_id = u.id
      WHERE u.id = $1
      LIMIT 1
    `, [req.user.id]);

    if (result.rows.length === 0) {
      return res.status(404).json({
        ok: false,
        error: 'User not found'
      });
    }

    const row = result.rows[0];

    const user = {
      id: row.id,
      email: row.email,
      name: row.name || null,
      role: row.role || 'client',   // ← КРИТИЧЕСКИЙ FIX
      phone: row.phone || null,
      phone_status: row.phone_status || null,
      phone_verified_at: row.phone_verified_at || null
    };

    console.log('PROFILE RESPONSE:', user);

    return res.json({
      ok: true,
      user
    });

  } catch (err) {
    console.error('PROFILE ERROR:', err);

    return res.status(500).json({
      ok: false,
      error: 'Internal server error'
    });
  }
});

module.exports = router;