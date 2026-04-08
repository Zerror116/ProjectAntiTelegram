const fs = require("fs");

let cachedMessaging = undefined;

function cleanString(value) {
  return String(value || "").trim();
}

function parseServiceAccount() {
  const inlineJson = cleanString(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
  if (inlineJson) {
    try {
      return JSON.parse(inlineJson);
    } catch (err) {
      console.error("nativePush.parseServiceAccount inline JSON error", err);
      return null;
    }
  }

  const inlineBase64 = cleanString(process.env.FIREBASE_SERVICE_ACCOUNT_BASE64);
  if (inlineBase64) {
    try {
      const decoded = Buffer.from(inlineBase64, "base64").toString("utf8");
      return JSON.parse(decoded);
    } catch (err) {
      console.error("nativePush.parseServiceAccount base64 error", err);
      return null;
    }
  }

  const filePath = cleanString(process.env.FIREBASE_SERVICE_ACCOUNT_PATH);
  if (filePath) {
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      return JSON.parse(raw);
    } catch (err) {
      console.error("nativePush.parseServiceAccount file error", err);
      return null;
    }
  }

  return null;
}

function normalizePrivateKey(rawKey) {
  const normalized = cleanString(rawKey);
  if (!normalized) return normalized;
  return normalized.replace(/\\n/g, "\n");
}

function getMessagingInstance() {
  if (cachedMessaging !== undefined) {
    return cachedMessaging;
  }

  const serviceAccount = parseServiceAccount();
  if (!serviceAccount) {
    cachedMessaging = null;
    return null;
  }

  try {
    const { initializeApp, cert, getApps } = require("firebase-admin/app");
    const { getMessaging } = require("firebase-admin/messaging");
    const existing = getApps();
    const app =
      existing[0] ||
      initializeApp({
        credential: cert({
          ...serviceAccount,
          privateKey: normalizePrivateKey(serviceAccount.private_key),
        }),
        projectId:
          cleanString(process.env.FIREBASE_PROJECT_ID) ||
          cleanString(serviceAccount.project_id) ||
          undefined,
      });
    cachedMessaging = getMessaging(app);
    return cachedMessaging;
  } catch (err) {
    console.error("nativePush.getMessagingInstance init error", err);
    cachedMessaging = null;
    return null;
  }
}

function isNativePushConfigured() {
  return getMessagingInstance() != null;
}

function normalizeStringMap(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {};
  }
  const next = {};
  for (const [key, value] of Object.entries(raw)) {
    if (!key) continue;
    if (value === null || value === undefined) continue;
    if (
      typeof value === "object" &&
      !Array.isArray(value)
    ) {
      next[key] = JSON.stringify(value);
      continue;
    }
    if (Array.isArray(value)) {
      next[key] = JSON.stringify(value);
      continue;
    }
    next[key] = String(value);
  }
  return next;
}

function normalizeCategory(rawCategory) {
  const category = cleanString(rawCategory).toLowerCase();
  switch (category) {
    case "chat":
    case "support":
    case "reserved":
    case "delivery":
    case "promo":
    case "updates":
    case "security":
      return category;
    default:
      return "support";
  }
}

function normalizePriority(rawPriority) {
  const priority = cleanString(rawPriority).toLowerCase();
  switch (priority) {
    case "low":
    case "normal":
    case "high":
    case "critical":
      return priority;
    default:
      return "normal";
  }
}

function androidChannelIdFor(category) {
  switch (normalizeCategory(category)) {
    case "chat":
      return "phoenix_messages";
    case "support":
      return "phoenix_support";
    case "reserved":
      return "phoenix_reserved";
    case "delivery":
      return "phoenix_delivery";
    case "promo":
      return "phoenix_promo";
    case "updates":
      return "phoenix_updates";
    case "security":
    default:
      return "phoenix_security";
  }
}

function androidPriorityFor(priority, category) {
  const normalizedPriority = normalizePriority(priority);
  const normalizedCategory = normalizeCategory(category);
  if (
    normalizedPriority === "critical" ||
    normalizedPriority === "high" ||
    normalizedCategory === "chat" ||
    normalizedCategory === "support" ||
    normalizedCategory === "security"
  ) {
    return "high";
  }
  return "normal";
}

function interruptionLevelFor(priority, category) {
  const normalizedPriority = normalizePriority(priority);
  const normalizedCategory = normalizeCategory(category);
  if (normalizedCategory === "security" || normalizedPriority === "critical") {
    return "time-sensitive";
  }
  if (
    normalizedCategory === "support" ||
    normalizedCategory === "delivery" ||
    normalizedPriority === "high"
  ) {
    return "active";
  }
  if (
    normalizedCategory === "promo" ||
    normalizedCategory === "updates" ||
    normalizedPriority === "low"
  ) {
    return "passive";
  }
  return "active";
}

function imageUrlFromPayload(payload) {
  const media = payload?.media && typeof payload.media === "object"
    ? payload.media
    : {};
  const raw = cleanString(
    media.image_url || media.url || media.thumbnail_url || "",
  );
  return raw || undefined;
}

function ttlString(ttlSeconds) {
  const parsed = Number.parseInt(String(ttlSeconds || "").trim(), 10);
  const seconds = Number.isFinite(parsed) && parsed > 0 ? parsed : 3600;
  return `${seconds}s`;
}

function collapseKeyFromPayload(payload) {
  return cleanString(payload?.collapse_key || payload?.tag || "");
}

function buildFcmData(payload) {
  const normalizedPayload = payload?.payload && typeof payload.payload === "object"
    ? payload.payload
    : {};
  return normalizeStringMap({
    id: payload?.id || "",
    category: payload?.category || "",
    priority: payload?.priority || "",
    title: payload?.title || "",
    body: payload?.body || "",
    deep_link: payload?.deep_link || "",
    inbox_item_id: payload?.inbox_item_id || "",
    badge_count: payload?.badge_count ?? 0,
    force_show: payload?.force_show === true ? "true" : "false",
    campaign_id: payload?.campaign_id || "",
    cta_label: payload?.cta_label || "",
    version: payload?.version || "",
    required_update: payload?.required_update === true ? "true" : "false",
    thread_id: payload?.thread_id || "",
    media: payload?.media || {},
    payload: normalizedPayload,
  });
}

function buildAndroidMessage(endpoint, payload) {
  const category = normalizeCategory(payload.category);
  const priority = normalizePriority(payload.priority);
  return {
    token: endpoint.push_token,
    data: buildFcmData(payload),
    notification: {
      title: cleanString(payload.title) || "Проект Феникс",
      body: cleanString(payload.body) || "Новое уведомление",
    },
    android: {
      priority: androidPriorityFor(priority, category),
      ttl: ttlString(payload.ttl_seconds),
      collapseKey: collapseKeyFromPayload(payload) || undefined,
      notification: {
        channelId: androidChannelIdFor(category),
        tag: collapseKeyFromPayload(payload) || undefined,
        imageUrl: imageUrlFromPayload(payload),
      },
    },
  };
}

function buildAppleMessage(endpoint, payload) {
  const category = normalizeCategory(payload.category);
  const priority = normalizePriority(payload.priority);
  const badgeCount = Number.parseInt(
    String(payload.badge_count ?? "").trim(),
    10,
  );
  return {
    token: endpoint.push_token,
    data: buildFcmData(payload),
    notification: {
      title: cleanString(payload.title) || "Проект Феникс",
      body: cleanString(payload.body) || "Новое уведомление",
    },
    apns: {
      headers: {
        "apns-priority":
          priority === "critical" || priority === "high" ? "10" : "5",
        "apns-push-type": "alert",
        ...(collapseKeyFromPayload(payload)
          ? { "apns-collapse-id": collapseKeyFromPayload(payload) }
          : {}),
      },
      payload: {
        aps: {
          sound: category === "promo" ? undefined : "default",
          badge: Number.isFinite(badgeCount) && badgeCount >= 0
            ? badgeCount
            : undefined,
          category: category,
          "thread-id": cleanString(payload.thread_id) || undefined,
          "interruption-level": interruptionLevelFor(priority, category),
        },
      },
      fcmOptions: {
        imageUrl: imageUrlFromPayload(payload),
      },
    },
  };
}

function buildMessageForEndpoint(endpoint, payload) {
  const platform = cleanString(endpoint?.platform).toLowerCase();
  if (platform === "ios" || platform === "macos") {
    return buildAppleMessage(endpoint, payload);
  }
  return buildAndroidMessage(endpoint, payload);
}

async function sendFcmPayloadToEndpoints({ endpoints = [], payload = {} }) {
  const messaging = getMessagingInstance();
  if (!messaging) {
    return {
      configured: false,
      results: [],
    };
  }

  const results = [];
  for (const endpoint of endpoints) {
    const token = cleanString(endpoint?.push_token);
    if (!token) continue;
    try {
      const message = buildMessageForEndpoint(endpoint, payload);
      const providerMessageId = await messaging.send(message, false);
      results.push({
        endpointId: endpoint.id || null,
        state: "provider_accepted",
        providerMessageId,
        errorMessage: "",
      });
    } catch (err) {
      const code = cleanString(err?.code || err?.errorInfo?.code);
      const message = cleanString(err?.message || err);
      const shouldDeactivate =
        code.includes("registration-token-not-registered") ||
        code.includes("invalid-argument") ||
        code.includes("invalid-registration-token");
      results.push({
        endpointId: endpoint.id || null,
        state: "failed",
        providerMessageId: null,
        errorMessage: message || code || "fcm_send_failed",
        deactivateEndpoint: shouldDeactivate,
      });
    }
  }

  return {
    configured: true,
    results,
  };
}

module.exports = {
  isNativePushConfigured,
  sendFcmPayloadToEndpoints,
};
