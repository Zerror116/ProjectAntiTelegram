const webPush = require("web-push");

const db = require("../db");

let vapidConfigured = false;

function getWebPushConfig() {
  const publicKey = String(process.env.WEB_PUSH_PUBLIC_KEY || "").trim();
  const privateKey = String(process.env.WEB_PUSH_PRIVATE_KEY || "").trim();
  const subject = String(
    process.env.WEB_PUSH_SUBJECT || "mailto:admin@garphoenix.com",
  ).trim();
  return { publicKey, privateKey, subject };
}

function isWebPushEnabled() {
  const { publicKey, privateKey } = getWebPushConfig();
  return publicKey.length > 0 && privateKey.length > 0;
}

function ensureWebPushConfigured() {
  if (vapidConfigured) return true;
  const { publicKey, privateKey, subject } = getWebPushConfig();
  if (!publicKey || !privateKey) return false;
  webPush.setVapidDetails(subject, publicKey, privateKey);
  vapidConfigured = true;
  return true;
}

function getWebPushPublicKey() {
  return getWebPushConfig().publicKey;
}

function normalizeWebPushSubscription(raw) {
  const map = raw && typeof raw === "object" ? raw : {};
  const endpoint = String(map.endpoint || "").trim();
  const keys =
    map.keys && typeof map.keys === "object" && !Array.isArray(map.keys)
      ? map.keys
      : {};
  const p256dh = String(keys.p256dh || "").trim();
  const auth = String(keys.auth || "").trim();
  if (!endpoint || !p256dh || !auth) {
    return null;
  }
  return {
    endpoint,
    expirationTime:
      map.expirationTime === null || map.expirationTime === undefined
        ? null
        : Number(map.expirationTime) || null,
    keys: {
      p256dh,
      auth,
    },
  };
}

async function upsertWebPushSubscription({
  userId,
  subscription,
  userAgent = "",
}) {
  const normalized = normalizeWebPushSubscription(subscription);
  if (!normalized) {
    throw new Error("invalid_subscription");
  }
  await db.query(
    `INSERT INTO web_push_subscriptions (
        user_id,
        endpoint,
        subscription,
        user_agent,
        is_active,
        updated_at,
        last_seen_at
      )
      VALUES ($1, $2, $3::jsonb, $4, true, now(), now())
      ON CONFLICT (endpoint)
      DO UPDATE SET
        user_id = EXCLUDED.user_id,
        subscription = EXCLUDED.subscription,
        user_agent = EXCLUDED.user_agent,
        is_active = true,
        updated_at = now(),
        last_seen_at = now()`,
    [userId, normalized.endpoint, JSON.stringify(normalized), userAgent],
  );
  return normalized;
}

async function removeWebPushSubscription({ userId, endpoint }) {
  const normalizedEndpoint = String(endpoint || "").trim();
  if (!normalizedEndpoint) return false;
  const result = await db.query(
    `DELETE FROM web_push_subscriptions
      WHERE user_id = $1
        AND endpoint = $2`,
    [userId, normalizedEndpoint],
  );
  return result.rowCount > 0;
}

async function deactivateWebPushSubscription(endpoint) {
  const normalizedEndpoint = String(endpoint || "").trim();
  if (!normalizedEndpoint) return;
  await db.query(
    `UPDATE web_push_subscriptions
        SET is_active = false,
            updated_at = now()
      WHERE endpoint = $1`,
    [normalizedEndpoint],
  );
}

function buildMessagePreview(message) {
  const text = String(message?.text || "").trim();
  if (text) {
    return text.replace(/\s+/g, " ").slice(0, 120);
  }
  const meta = message?.meta && typeof message.meta === "object"
    ? message.meta
    : {};
  const title = String(meta.title || "").trim();
  if (title) return title.slice(0, 120);
  const mediaType = String(meta.media_type || meta.kind || "").trim().toLowerCase();
  if (mediaType.includes("voice")) return "Новое голосовое сообщение";
  if (mediaType.includes("video")) return "Новое видеосообщение";
  if (mediaType.includes("image") || mediaType.includes("photo")) {
    return "Новое фото";
  }
  return "Новое сообщение";
}

async function computeUnreadBadgeCount(userId) {
  const result = await db.query(
    `SELECT COUNT(*)::int AS unread_count
       FROM messages m
       JOIN chat_members cm
         ON cm.chat_id = m.chat_id
        AND cm.user_id = $1
      WHERE m.sender_id IS NOT NULL
        AND m.sender_id <> $1
        AND NOT EXISTS (
          SELECT 1
            FROM message_reads mr
           WHERE mr.message_id = m.id
             AND mr.user_id = $1
        )
        AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
        AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false`,
    [userId, String(userId)],
  );
  return Number(result.rows?.[0]?.unread_count || 0) || 0;
}

async function resolveChatPushRecipients({ chatId, senderId, explicitUserIds = [] }) {
  const recipientIds = new Set();
  for (const userId of explicitUserIds) {
    const normalized = String(userId || "").trim();
    if (normalized) recipientIds.add(normalized);
  }
  if (chatId) {
    const membersQ = await db.query(
      `SELECT user_id
         FROM chat_members
        WHERE chat_id = $1`,
      [chatId],
    );
    for (const row of membersQ.rows) {
      const memberId = String(row.user_id || "").trim();
      if (memberId) recipientIds.add(memberId);
    }
  }
  const normalizedSenderId = String(senderId || "").trim();
  if (normalizedSenderId) {
    recipientIds.delete(normalizedSenderId);
  }
  return Array.from(recipientIds);
}

async function sendPayloadToUserSubscriptions(userId, payload) {
  if (!ensureWebPushConfigured()) return 0;
  const subscriptionsQ = await db.query(
    `SELECT endpoint, subscription
       FROM web_push_subscriptions
      WHERE user_id = $1
        AND is_active = true`,
    [userId],
  );
  if (subscriptionsQ.rowCount === 0) return 0;

  let sent = 0;
  for (const row of subscriptionsQ.rows) {
    try {
      await webPush.sendNotification(row.subscription, JSON.stringify(payload), {
        TTL: 60,
        urgency: "high",
      });
      sent += 1;
    } catch (err) {
      const statusCode = Number(err?.statusCode || 0);
      if (statusCode === 404 || statusCode === 410) {
        await deactivateWebPushSubscription(row.endpoint);
        continue;
      }
      console.error("webPush.sendNotification error:", {
        message: err?.message || String(err),
        statusCode,
        body: err?.body || null,
        endpoint: String(row.endpoint || "").slice(0, 120),
      });
    }
  }
  return sent;
}

async function sendWebPushPayloadToUser(userId, payload) {
  return sendPayloadToUserSubscriptions(userId, payload);
}

async function sendTestWebPushToUser(userId) {
  const unreadCount = await computeUnreadBadgeCount(userId);
  return sendPayloadToUserSubscriptions(userId, {
    type: "test",
    title: "Проект Феникс",
    body: "Тестовое push-уведомление доставлено с сервера.",
    tag: "projectphoenix-test-push",
    url: "/",
    badgeCount: unreadCount,
    forceShow: true,
    data: {
      test: true,
      sentAt: new Date().toISOString(),
    },
  });
}

async function queueChatMessageWebPushForRooms({ rooms = [], payload = {} }) {
  if (!ensureWebPushConfigured()) return;
  const normalizedRooms = Array.isArray(rooms) ? rooms : [];
  if (!normalizedRooms.length) return;

  const message =
    payload && typeof payload.message === "object" ? payload.message : null;
  if (!message) return;

  const chatId = String(payload.chatId || message.chat_id || "").trim();
  const senderId = String(message.sender_id || "").trim();

  const explicitUserIds = normalizedRooms
    .map((room) => {
      const value = String(room || "").trim();
      if (!value.startsWith("user:")) return "";
      return value.slice("user:".length).trim();
    })
    .filter(Boolean);

  const recipientIds = await resolveChatPushRecipients({
    chatId,
    senderId,
    explicitUserIds,
  });
  if (!recipientIds.length) return;

  const senderName = String(message.sender_name || "").trim() || "Новое сообщение";
  const preview = buildMessagePreview(message);

  for (const recipientUserId of recipientIds) {
    const unreadCount = await computeUnreadBadgeCount(recipientUserId);
    await sendPayloadToUserSubscriptions(recipientUserId, {
      type: "chat-message",
      title: senderName,
      body: preview,
      tag: chatId ? `chat:${chatId}` : "chat-message",
      url: "/",
      badgeCount: unreadCount,
      data: {
        chatId: chatId || null,
        messageId: String(message.id || "").trim() || null,
      },
    });
  }
}

module.exports = {
  isWebPushEnabled,
  getWebPushPublicKey,
  normalizeWebPushSubscription,
  upsertWebPushSubscription,
  removeWebPushSubscription,
  computeUnreadBadgeCount,
  sendWebPushPayloadToUser,
  sendTestWebPushToUser,
  queueChatMessageWebPushForRooms,
};
