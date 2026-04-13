const express = require("express");

const { authMiddleware: requireAuth } = require("../utils/auth");
const {
  getMessengerPreferencesForUser,
  upsertMessengerPreferencesForUser,
} = require("../utils/messengerPreferences");

const router = express.Router();

router.get("/preferences", requireAuth, async (req, res) => {
  try {
    const data = await getMessengerPreferencesForUser(req.user.id);
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("messenger.preferences.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.patch("/preferences", requireAuth, async (req, res) => {
  try {
    const data = await upsertMessengerPreferencesForUser(
      req.user.id,
      req.body || {},
    );
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("messenger.preferences.patch error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
