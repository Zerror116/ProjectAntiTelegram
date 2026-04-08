const express = require("express");

const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const {
  dispatchPromotionCampaign,
  listPromotionCampaignsForAdmin,
  getPromotionAnalyticsForCreator,
} = require("../utils/notifications");

const router = express.Router();

function isCreatorBase(user) {
  return String(user?.role || "").toLowerCase().trim() === "creator";
}

function isAdminBase(user) {
  return String(user?.role || "").toLowerCase().trim() === "admin";
}

router.post("/promotions", requireAuth, requireRole("admin"), async (req, res) => {
  try {
    if (!isAdminBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только администратор может отправлять promo" });
    }
    if (isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Создатель может отправлять только test promo" });
    }
    const title = String(req.body?.title || "").trim();
    const body = String(req.body?.body || "").trim();
    if (!title || !body) {
      return res.status(400).json({ ok: false, error: "title и body обязательны" });
    }
    const data = await dispatchPromotionCampaign({
      actor: req.user,
      title,
      body,
      deepLink: req.body?.deep_link || "/",
      media: req.body?.media || {},
      testOnly: false,
    });
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("adminNotifications.promotions.post error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/promotions", requireAuth, requireRole("admin"), async (req, res) => {
  try {
    if (!isAdminBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только администратор может просматривать promo-кампании" });
    }
    if (isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Создатель не использует этот маршрут для real promo" });
    }
    const data = await listPromotionCampaignsForAdmin(req.user);
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("adminNotifications.promotions.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/analytics", requireAuth, requireRole("creator"), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только создатель видит аналитику" });
    }
    const data = await getPromotionAnalyticsForCreator();
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("adminNotifications.analytics.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
