const express = require('express');
const router = express.Router();
const { pool } = require('../db');
const requireAuth = require('../middleware/requireAuth');

router.post('/update', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { name } = req.body;

    if (!name || name.trim().length === 0) {
      return res.status(400).json({
        ok: false,
        error: 'Name required'
      });
    }

    const updated = await pool.query(
      `UPDATE users
       SET name = $1,
           updated_at = now()
       WHERE id = $2
       RETURNING id, email, name, role, avatar_url,
                 COALESCE(avatar_focus_x, 0) AS avatar_focus_x,
                 COALESCE(avatar_focus_y, 0) AS avatar_focus_y,
                 COALESCE(avatar_zoom, 1) AS avatar_zoom`,
      [name.trim(), userId]
    );

    return res.json({
      ok: true,
      user: updated.rows[0] || null,
    });

  } catch (err) {
    console.error(err);

    return res.status(500).json({
      ok: false
    });
  }
});

module.exports = router;
