const express = require("express");

const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const db = require("../db");
const {
  canAccessNotificationInbox,
  getNotificationPreferencesForUser,
  upsertNotificationPreferences,
  upsertNotificationEndpoint,
  deactivateNotificationEndpoint,
  computeNotificationBadgeCount,
  computeNotificationInboxBadgeCount,
  listNotificationInbox,
  markNotificationInboxItemOpened,
  markNotificationInboxItemRead,
  markAllNotificationInboxItemsRead,
  dispatchPromotionCampaign,
} = require("../utils/notifications");

const router = express.Router();

function isCreatorBase(user) {
  return String(user?.role || "").toLowerCase().trim() === "creator";
}

async function runNotificationsInEffectiveScope(req, fn) {
  if (req.user?.is_platform_creator === true) {
    return db.runWithPlatform(fn);
  }
  return fn();
}

router.get("/preferences", requireAuth, async (req, res) => {
  try {
    const data = await runNotificationsInEffectiveScope(req, async () =>
      getNotificationPreferencesForUser(req.user),
    );
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.preferences.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.patch("/preferences", requireAuth, async (req, res) => {
  try {
    const data = await runNotificationsInEffectiveScope(req, async () =>
      upsertNotificationPreferences({
        user: req.user,
        patch: req.body || {},
      }),
    );
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.preferences.patch error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/inbox", requireAuth, async (req, res) => {
  try {
    if (!canAccessNotificationInbox(req.user)) {
      return res.status(403).json({ ok: false, error: "Раздел событий доступен только создателю" });
    }
    const data = await runNotificationsInEffectiveScope(req, async () =>
      listNotificationInbox({
        userId: req.user.id,
        limit: req.query?.limit,
        unreadOnly: String(req.query?.status || "").trim().toLowerCase() === "unread",
        category: req.query?.category || "",
      }),
    );
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.inbox.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/inbox/:id/read", requireAuth, async (req, res) => {
  try {
    if (!canAccessNotificationInbox(req.user)) {
      return res.status(403).json({ ok: false, error: "Раздел событий доступен только создателю" });
    }
    const itemId = String(req.params?.id || "").trim();
    if (!itemId) {
      return res.status(400).json({ ok: false, error: "id обязателен" });
    }
    const data = await runNotificationsInEffectiveScope(req, async () =>
      markNotificationInboxItemRead({
        userId: req.user.id,
        itemId,
      }),
    );
    if (!data) {
      return res.status(404).json({ ok: false, error: "Уведомление не найдено" });
    }
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.inbox.read error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/inbox/:id/opened", requireAuth, async (req, res) => {
  try {
    const itemId = String(req.params?.id || "").trim();
    if (!itemId) {
      return res.status(400).json({ ok: false, error: "id обязателен" });
    }
    const data = await runNotificationsInEffectiveScope(req, async () =>
      markNotificationInboxItemOpened({
        userId: req.user.id,
        itemId,
      }),
    );
    if (!data) {
      return res.status(404).json({ ok: false, error: "Уведомление не найдено" });
    }
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.inbox.opened error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/inbox/read-all", requireAuth, async (req, res) => {
  try {
    if (!canAccessNotificationInbox(req.user)) {
      return res.status(403).json({ ok: false, error: "Раздел событий доступен только создателю" });
    }
    const unreadCount = await runNotificationsInEffectiveScope(req, async () =>
      markAllNotificationInboxItemsRead({
        userId: req.user.id,
      }),
    );
    return res.json({ ok: true, data: { unread_count: unreadCount } });
  } catch (err) {
    console.error("notifications.inbox.readAll error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/badge-count", requireAuth, async (req, res) => {
  try {
    const [unreadCount, inboxUnreadCount] = await runNotificationsInEffectiveScope(
      req,
      async () =>
        Promise.all([
          computeNotificationBadgeCount(req.user.id),
          computeNotificationInboxBadgeCount(req.user.id),
        ]),
    );
    return res.json({
      ok: true,
      unread_count: unreadCount,
      inbox_unread_count: inboxUnreadCount,
    });
  } catch (err) {
    console.error("notifications.badgeCount error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/endpoints/register", requireAuth, async (req, res) => {
  try {
    const data = await runNotificationsInEffectiveScope(req, async () =>
      upsertNotificationEndpoint({
        user: req.user,
        platform: req.body?.platform,
        transport: req.body?.transport,
        deviceKey: req.body?.device_key,
        pushToken: req.body?.push_token,
        endpoint: req.body?.endpoint,
        subscription: req.body?.subscription,
        permissionState: req.body?.permission_state,
        capabilities: req.body?.capabilities,
        appVersion: req.body?.app_version,
        locale: req.body?.locale,
        timezone: req.body?.timezone,
        userAgent: req.headers["user-agent"] || req.body?.user_agent || "",
        testOnly: req.body?.test_only === true,
      }),
    );
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.endpoints.register error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/endpoints/refresh", requireAuth, async (req, res) => {
  try {
    const data = await runNotificationsInEffectiveScope(req, async () =>
      upsertNotificationEndpoint({
        user: req.user,
        platform: req.body?.platform,
        transport: req.body?.transport,
        deviceKey: req.body?.device_key,
        pushToken: req.body?.push_token,
        endpoint: req.body?.endpoint,
        subscription: req.body?.subscription,
        permissionState: req.body?.permission_state,
        capabilities: req.body?.capabilities,
        appVersion: req.body?.app_version,
        locale: req.body?.locale,
        timezone: req.body?.timezone,
        userAgent: req.headers["user-agent"] || req.body?.user_agent || "",
        testOnly: req.body?.test_only === true,
      }),
    );
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.endpoints.refresh error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/endpoints/unregister", requireAuth, async (req, res) => {
  try {
    const ok = await runNotificationsInEffectiveScope(req, async () =>
      deactivateNotificationEndpoint({
        userId: req.user.id,
        endpoint: req.body?.endpoint,
        pushToken: req.body?.push_token,
        deviceKey: req.body?.device_key,
        transport: req.body?.transport,
      }),
    );
    return res.json({ ok: true, data: { deactivated: ok } });
  } catch (err) {
    console.error("notifications.endpoints.unregister error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/promotions/test", requireAuth, requireRole("creator"), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только создатель может отправлять тестовое promo" });
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
      testOnly: true,
    });
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("notifications.promotions.test error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
