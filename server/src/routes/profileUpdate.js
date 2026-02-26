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

    await pool.query(
      `UPDATE users SET name = $1 WHERE id = $2`,
      [name.trim(), userId]
    );

    return res.json({
      ok: true
    });

  } catch (err) {
    console.error(err);

    return res.status(500).json({
      ok: false
    });
  }
});

module.exports = router;