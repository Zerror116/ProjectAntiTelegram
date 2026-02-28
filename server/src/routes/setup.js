// server/src/routes/setup.js
const express = require("express");
const router = express.Router();
const { bootstrapDatabase } = require("../utils/bootstrap");

router.post("/", async (req, res) => {
  try {
    const result = await bootstrapDatabase();
    return res.json(result);
  } catch (err) {
    console.error("Setup error:", err);
    return res.status(500).json({ ok: false, error: String(err) });
  }
});

module.exports = router;
