const express = require("express");

const { authMiddleware } = require("../utils/auth");
const {
  isWebPushEnabled,
  getWebPushPublicKey,
  upsertWebPushSubscription,
  removeWebPushSubscription,
  sendTestWebPushToUser,
} = require("../utils/webPush");
const { computeNotificationBadgeCount } = require("../utils/notifications");

const router = express.Router();

router.get("/config", authMiddleware, async (req, res) => {
  return res.json({
    ok: true,
    enabled: isWebPushEnabled(),
    public_key: getWebPushPublicKey() || null,
  });
});

router.get("/badge-count", authMiddleware, async (req, res) => {
  try {
    const count = await computeNotificationBadgeCount(req.user.id);
    return res.json({ ok: true, unread_count: count });
  } catch (err) {
    console.error("webPush.badgeCount error", err);
    return res.status(500).json({ error: "Не удалось получить badge count" });
  }
});

router.post("/subscriptions", authMiddleware, async (req, res) => {
  if (!isWebPushEnabled()) {
    return res.status(503).json({ error: "Web push не настроен на сервере" });
  }
  try {
    const normalized = await upsertWebPushSubscription({
      userId: req.user.id,
      tenantId: req.user?.tenant_id || null,
      subscription: req.body?.subscription || req.body,
      userAgent: req.headers["user-agent"] || "",
    });
    return res.json({
      ok: true,
      endpoint: normalized.endpoint,
    });
  } catch (err) {
    const message = String(err?.message || "").trim();
    if (message === "invalid_subscription") {
      return res.status(400).json({ error: "Некорректная push-подписка" });
    }
    console.error("webPush.subscribe error", err);
    return res.status(500).json({ error: "Не удалось сохранить push-подписку" });
  }
});

router.post("/test", authMiddleware, async (req, res) => {
  if (!isWebPushEnabled()) {
    return res.status(503).json({ error: "Web push не настроен на сервере" });
  }
  try {
    const sent = await sendTestWebPushToUser(req.user.id);
    return res.json({ ok: true, sent });
  } catch (err) {
    console.error("webPush.test error", err);
    return res.status(500).json({ error: "Не удалось отправить тестовый push" });
  }
});

router.delete("/subscriptions", authMiddleware, async (req, res) => {
  try {
    const endpoint = String(
      req.body?.endpoint || req.query?.endpoint || "",
    ).trim();
    if (!endpoint) {
      return res.status(400).json({ error: "endpoint обязателен" });
    }
    await removeWebPushSubscription({
      userId: req.user.id,
      endpoint,
    });
    return res.json({ ok: true });
  } catch (err) {
    console.error("webPush.unsubscribe error", err);
    return res.status(500).json({ error: "Не удалось удалить push-подписку" });
  }
});

module.exports = router;
