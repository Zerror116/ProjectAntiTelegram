const { v4: uuidv4 } = require("uuid");

const db = require("../db");
const { emitToUser } = require("./socket");

const CATEGORIES = new Set([
  "chat",
  "support",
  "reserved",
  "delivery",
  "promo",
  "updates",
  "security",
]);
const PRIORITIES = new Set(["low", "normal", "high", "critical"]);
const CHANNELS = new Set(["push", "in_app", "email"]);
const DIGEST_MODES = new Set(["off", "daily_non_urgent", "daily_all_delayed"]);
const ENDPOINT_TRANSPORTS = new Set(["webpush", "fcm", "apns", "device_heartbeat"]);
const ENDPOINT_PLATFORMS = new Set([
  "web",
  "android",
  "ios",
  "macos",
  "windows",
  "linux",
  "unknown",
]);
const ENDPOINT_PERMISSION_STATES = new Set([
  "unknown",
  "unsupported",
  "default",
  "granted",
  "denied",
  "provisional",
]);

function normalizeRole(raw) {
  return String(raw || "").toLowerCase().trim();
}

function isCreatorRole(role) {
  return normalizeRole(role) === "creator";
}

function isClientRole(role) {
  return normalizeRole(role) === "client";
}

function isAdminRole(role) {
  return normalizeRole(role) === "admin";
}

function isWorkerRole(role) {
  return normalizeRole(role) === "worker";
}

function isTenantRole(role) {
  return normalizeRole(role) === "tenant";
}

function canAccessNotificationInbox(user) {
  return isCreatorRole(user?.role);
}

function hasReservedNotifications(role) {
  return isAdminRole(role) || isWorkerRole(role) || isCreatorRole(role);
}

function hasDeliveryNotifications(role) {
  return (
    isAdminRole(role) ||
    isWorkerRole(role) ||
    isTenantRole(role) ||
    isCreatorRole(role) ||
    isClientRole(role)
  );
}

function normalizeCategory(raw, fallback = "support") {
  const value = String(raw || "").toLowerCase().trim();
  return CATEGORIES.has(value) ? value : fallback;
}

function normalizePriority(raw, fallback = "normal") {
  const value = String(raw || "").toLowerCase().trim();
  return PRIORITIES.has(value) ? value : fallback;
}

function normalizeChannel(raw, fallback = "in_app") {
  const value = String(raw || "").toLowerCase().trim();
  return CHANNELS.has(value) ? value : fallback;
}

function normalizeDigestMode(raw, fallback = "daily_non_urgent") {
  const value = String(raw || "").toLowerCase().trim();
  return DIGEST_MODES.has(value) ? value : fallback;
}

function normalizeEndpointTransport(raw, fallback = "device_heartbeat") {
  const value = String(raw || "").toLowerCase().trim();
  return ENDPOINT_TRANSPORTS.has(value) ? value : fallback;
}

function normalizeEndpointPlatform(raw, fallback = "unknown") {
  const value = String(raw || "").toLowerCase().trim();
  return ENDPOINT_PLATFORMS.has(value) ? value : fallback;
}

function normalizePermissionState(raw, fallback = "unknown") {
  const value = String(raw || "").toLowerCase().trim();
  return ENDPOINT_PERMISSION_STATES.has(value) ? value : fallback;
}

function normalizeJsonMap(raw, fallback = {}) {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    return { ...raw };
  }
  return { ...fallback };
}

function normalizeBooleanMap(raw, allowedKeys, defaults = {}) {
  const source = normalizeJsonMap(raw, defaults);
  const next = {};
  for (const key of allowedKeys) {
    const fallbackValue = defaults[key] === true;
    next[key] = source[key] === undefined ? fallbackValue : source[key] === true;
  }
  return next;
}

function normalizeInteger(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value ?? "").trim(), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

function normalizeClock(raw) {
  const normalized = String(raw || "").trim();
  if (!normalized) return "";
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(normalized)) return "";
  return normalized;
}

const TIMEZONE_ALIAS_MAP = new Map([
  ["самара, стандартное время", "Europe/Samara"],
  ["samara standard time", "Europe/Samara"],
  ["азербайджан, стандартное время", "Asia/Baku"],
  ["azerbaijan standard time", "Asia/Baku"],
]);

function isValidTimeZone(raw) {
  const value = String(raw || "").trim();
  if (!value) return false;
  try {
    new Intl.DateTimeFormat("en-CA", {
      timeZone: value,
      year: "numeric",
    }).format(new Date());
    return true;
  } catch (_) {
    return false;
  }
}

function timeZoneFromOffsetString(raw) {
  const normalized = String(raw || "")
    .trim()
    .replace(/\s+/g, "")
    .toUpperCase();
  if (!normalized) return null;
  if (normalized === "UTC" || normalized === "GMT") {
    return "UTC";
  }
  const match = normalized.match(/^(?:UTC|GMT)?([+-])(\d{1,2})(?::?(\d{2}))?$/i);
  if (!match) return null;
  const sign = match[1] === "+" ? 1 : -1;
  const hours = Number(match[2]);
  const minutes = Number(match[3] || "0");
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) {
    return null;
  }
  if (hours > 14 || minutes > 59 || minutes !== 0) {
    return null;
  }
  if (hours === 0) {
    return "UTC";
  }
  const etcSign = sign > 0 ? "-" : "+";
  return `Etc/GMT${etcSign}${hours}`;
}

function canonicalizeNotificationTimeZone(raw) {
  const trimmed = String(raw || "").trim();
  if (!trimmed) return null;
  if (isValidTimeZone(trimmed)) {
    return trimmed;
  }
  const alias = TIMEZONE_ALIAS_MAP.get(trimmed.toLowerCase());
  if (alias && isValidTimeZone(alias)) {
    return alias;
  }
  const offsetZone = timeZoneFromOffsetString(trimmed);
  if (offsetZone && isValidTimeZone(offsetZone)) {
    return offsetZone;
  }
  return null;
}

function normalizeNotificationTimeZone(raw, fallback = "UTC") {
  return canonicalizeNotificationTimeZone(raw) || fallback;
}

function withinQuietHours({ enabled, from, to, now = new Date() }) {
  if (!enabled || !from || !to) return false;
  const [fromH, fromM] = from.split(":").map((x) => Number(x));
  const [toH, toM] = to.split(":").map((x) => Number(x));
  if (
    !Number.isInteger(fromH) ||
    !Number.isInteger(fromM) ||
    !Number.isInteger(toH) ||
    !Number.isInteger(toM)
  ) {
    return false;
  }

  const currentMinutes = now.getHours() * 60 + now.getMinutes();
  const fromMinutes = fromH * 60 + fromM;
  const toMinutes = toH * 60 + toM;

  if (fromMinutes === toMinutes) return true;
  if (fromMinutes < toMinutes) {
    return currentMinutes >= fromMinutes && currentMinutes < toMinutes;
  }
  return currentMinutes >= fromMinutes || currentMinutes < toMinutes;
}

function isNonUrgentCategory(category, priority) {
  const normalizedCategory = normalizeCategory(category, "support");
  const normalizedPriority = normalizePriority(priority, "normal");
  if (normalizedCategory === "promo" || normalizedCategory === "updates") {
    return true;
  }
  return normalizedPriority === "low";
}

function defaultCategoryPreferences(role) {
  const normalizedRole = normalizeRole(role);
  return {
    chat: true,
    support: true,
    reserved: hasReservedNotifications(normalizedRole),
    delivery: hasDeliveryNotifications(normalizedRole),
    promo: false,
    updates: true,
    security: true,
  };
}

function defaultChannelPreferences() {
  return {
    push: true,
    in_app: true,
    email: false,
  };
}

function defaultFrequencyCaps() {
  return {
    promo_per_day: 2,
    updates_per_day: 3,
    low_priority_per_day: 5,
  };
}

function defaultBadgePreferences() {
  return {
    count_chat: true,
    count_support: true,
    count_reserved: true,
    count_delivery: true,
    count_security: true,
    count_promo: false,
    count_updates: false,
  };
}

function buildDefaultPreferences(user) {
  return {
    categories: defaultCategoryPreferences(user?.role),
    channels: defaultChannelPreferences(),
    promo_opt_in: false,
    updates_opt_in: true,
    quiet_hours_enabled: false,
    quiet_from: "",
    quiet_to: "",
    digest_mode: "daily_non_urgent",
    frequency_caps: defaultFrequencyCaps(),
    badge_preferences: defaultBadgePreferences(),
  };
}

function lockedCategoriesForRole(role) {
  const normalizedRole = normalizeRole(role);
  if (isClientRole(normalizedRole)) {
    return new Set(["reserved", "delivery", "updates", "security"]);
  }
  if (isCreatorRole(normalizedRole)) {
    return new Set();
  }
  const locked = new Set(["updates", "security"]);
  if (hasReservedNotifications(normalizedRole)) locked.add("reserved");
  if (hasDeliveryNotifications(normalizedRole)) locked.add("delivery");
  return locked;
}

function normalizePreferencesForRole(user, rawPreferences) {
  const role = normalizeRole(user?.role);
  const defaults = buildDefaultPreferences(user);
  const normalized = {
    ...rawPreferences,
    categories: { ...rawPreferences.categories },
    channels: { ...rawPreferences.channels },
    frequency_caps: { ...rawPreferences.frequency_caps },
    badge_preferences: { ...rawPreferences.badge_preferences },
  };

  if (!isCreatorRole(role)) {
    normalized.quiet_hours_enabled = false;
    normalized.quiet_from = "";
    normalized.quiet_to = "";
    normalized.digest_mode = "off";
    normalized.frequency_caps = defaultFrequencyCaps();
    normalized.badge_preferences = defaultBadgePreferences();
  }

  if (isClientRole(role)) {
    const masterEnabled =
      normalized.channels.push === true ||
      normalized.channels.in_app === true ||
      normalized.channels.email === true ||
      normalized.categories.chat === true ||
      normalized.categories.support === true ||
      normalized.categories.promo === true ||
      normalized.categories.delivery === true ||
      normalized.categories.updates === true ||
      normalized.categories.security === true ||
      normalized.promo_opt_in === true ||
      normalized.updates_opt_in === true;

    normalized.categories = {
      ...normalized.categories,
      chat: masterEnabled ? normalized.categories.chat === true : false,
      support: masterEnabled ? normalized.categories.support === true : false,
      reserved: false,
      delivery: masterEnabled,
      promo: masterEnabled ? normalized.categories.promo === true : false,
      updates: masterEnabled,
      security: masterEnabled,
    };
    normalized.channels = {
      push: masterEnabled,
      in_app: masterEnabled,
      email: false,
    };
    normalized.promo_opt_in = masterEnabled && normalized.categories.promo === true;
    normalized.updates_opt_in = masterEnabled;
    return normalized;
  }

  normalized.promo_opt_in = isCreatorRole(role) ? normalized.promo_opt_in === true : false;
  if (!isCreatorRole(role)) {
    normalized.updates_opt_in = true;
  }

  const locked = lockedCategoriesForRole(role);
  for (const key of locked) {
    normalized.categories[key] = defaults.categories[key] === true;
  }

  if (!hasReservedNotifications(role)) {
    normalized.categories.reserved = false;
  }

  return normalized;
}

function sanitizePreferencesPatchForRole(user, patch = {}, current) {
  const role = normalizeRole(user?.role);
  const next = {};

  if (patch.categories && typeof patch.categories === "object" && !Array.isArray(patch.categories)) {
    next.categories = patch.categories;
  }
  if (patch.channels && typeof patch.channels === "object" && !Array.isArray(patch.channels)) {
    next.channels = patch.channels;
  }

  if (isClientRole(role)) {
    if (patch.promo_opt_in !== undefined) {
      next.promo_opt_in = patch.promo_opt_in === true;
    }
    return next;
  }

  if (isCreatorRole(role)) {
    if (patch.promo_opt_in !== undefined) {
      next.promo_opt_in = patch.promo_opt_in === true;
    }
    if (patch.updates_opt_in !== undefined) {
      next.updates_opt_in = patch.updates_opt_in !== false;
    }
    if (patch.quiet_hours_enabled !== undefined) {
      next.quiet_hours_enabled = patch.quiet_hours_enabled === true;
    }
    if (patch.quiet_from !== undefined) {
      next.quiet_from = patch.quiet_from;
    }
    if (patch.quiet_to !== undefined) {
      next.quiet_to = patch.quiet_to;
    }
    if (patch.digest_mode !== undefined) {
      next.digest_mode = patch.digest_mode;
    }
    if (patch.frequency_caps && typeof patch.frequency_caps === "object") {
      next.frequency_caps = patch.frequency_caps;
    }
    if (patch.badge_preferences && typeof patch.badge_preferences === "object") {
      next.badge_preferences = patch.badge_preferences;
    }
    return next;
  }

  return next;
}

async function getNotificationUser(userId) {
  const q = await db.query(
    `SELECT id, role, tenant_id
       FROM users
      WHERE id = $1
      LIMIT 1`,
    [userId],
  );
  return q.rows[0] || null;
}

function mergePreferences(defaults, row) {
  const categories = normalizeBooleanMap(
    row?.categories,
    Object.keys(defaults.categories),
    defaults.categories,
  );
  const channels = normalizeBooleanMap(
    row?.channels,
    Object.keys(defaults.channels),
    defaults.channels,
  );
  const badgePreferences = normalizeBooleanMap(
    row?.badge_preferences,
    Object.keys(defaults.badge_preferences),
    defaults.badge_preferences,
  );
  const frequencyCapsRaw = normalizeJsonMap(
    row?.frequency_caps,
    defaults.frequency_caps,
  );
  const frequencyCaps = {
    promo_per_day: normalizeInteger(
      frequencyCapsRaw.promo_per_day,
      defaults.frequency_caps.promo_per_day,
      0,
      100,
    ),
    updates_per_day: normalizeInteger(
      frequencyCapsRaw.updates_per_day,
      defaults.frequency_caps.updates_per_day,
      0,
      100,
    ),
    low_priority_per_day: normalizeInteger(
      frequencyCapsRaw.low_priority_per_day,
      defaults.frequency_caps.low_priority_per_day,
      0,
      200,
    ),
  };

  return {
    categories,
    channels,
    promo_opt_in: row?.promo_opt_in === true,
    updates_opt_in: row?.updates_opt_in !== false,
    quiet_hours_enabled: row?.quiet_hours_enabled === true,
    quiet_from: normalizeClock(row?.quiet_from),
    quiet_to: normalizeClock(row?.quiet_to),
    digest_mode: normalizeDigestMode(row?.digest_mode, defaults.digest_mode),
    frequency_caps: frequencyCaps,
    badge_preferences: badgePreferences,
  };
}

async function getRawNotificationProfile(userId) {
  const q = await db.query(
    `SELECT id,
            tenant_id,
            user_id,
            enabled_types,
            priorities,
            quiet_hours_enabled,
            quiet_from,
            quiet_to,
            test_mode,
            categories,
            channels,
            promo_opt_in,
            updates_opt_in,
            digest_mode,
            frequency_caps,
            badge_preferences,
            updated_at
       FROM smart_notification_profiles
      WHERE user_id = $1
      LIMIT 1`,
    [userId],
  );
  return q.rows[0] || null;
}

async function getNotificationPreferencesForUser(user) {
  const defaults = buildDefaultPreferences(user);
  const row = await getRawNotificationProfile(user.id);
  return normalizePreferencesForRole(user, {
    ...mergePreferences(defaults, row),
    updated_at: row?.updated_at || null,
  });
}

async function upsertNotificationPreferences({ user, patch = {} }) {
  const currentRow = await getRawNotificationProfile(user.id);
  const defaults = buildDefaultPreferences(user);
  const current = normalizePreferencesForRole(
    user,
    mergePreferences(defaults, currentRow),
  );
  const safePatch = sanitizePreferencesPatchForRole(user, patch, current);

  const categories = safePatch.categories
    ? normalizeBooleanMap(safePatch.categories, Object.keys(defaults.categories), current.categories)
    : current.categories;
  const channels = safePatch.channels
    ? normalizeBooleanMap(safePatch.channels, Object.keys(defaults.channels), current.channels)
    : current.channels;
  const badgePreferences = safePatch.badge_preferences
    ? normalizeBooleanMap(
        safePatch.badge_preferences,
        Object.keys(defaults.badge_preferences),
        current.badge_preferences,
      )
    : current.badge_preferences;
  const frequencyCaps = safePatch.frequency_caps
    ? {
        promo_per_day: normalizeInteger(
          safePatch.frequency_caps?.promo_per_day,
          current.frequency_caps.promo_per_day,
          0,
          100,
        ),
        updates_per_day: normalizeInteger(
          safePatch.frequency_caps?.updates_per_day,
          current.frequency_caps.updates_per_day,
          0,
          100,
        ),
        low_priority_per_day: normalizeInteger(
          safePatch.frequency_caps?.low_priority_per_day,
          current.frequency_caps.low_priority_per_day,
          0,
          200,
        ),
      }
    : current.frequency_caps;

  const quietHoursEnabled = safePatch.quiet_hours_enabled === undefined
    ? current.quiet_hours_enabled
    : safePatch.quiet_hours_enabled === true;
  const quietFrom = safePatch.quiet_from === undefined
    ? current.quiet_from
    : normalizeClock(safePatch.quiet_from);
  const quietTo = safePatch.quiet_to === undefined
    ? current.quiet_to
    : normalizeClock(safePatch.quiet_to);
  const digestMode = safePatch.digest_mode === undefined
    ? current.digest_mode
    : normalizeDigestMode(safePatch.digest_mode, current.digest_mode);
  const promoOptIn = safePatch.promo_opt_in === undefined
    ? current.promo_opt_in
    : safePatch.promo_opt_in === true;
  const updatesOptIn = safePatch.updates_opt_in === undefined
    ? current.updates_opt_in
    : safePatch.updates_opt_in !== false;

  const normalizedResult = normalizePreferencesForRole(user, {
    categories,
    channels,
    promo_opt_in: promoOptIn,
    updates_opt_in: updatesOptIn,
    quiet_hours_enabled: quietHoursEnabled,
    quiet_from: quietFrom,
    quiet_to: quietTo,
    digest_mode: digestMode,
    frequency_caps: frequencyCaps,
    badge_preferences: badgePreferences,
  });

  const result = await db.query(
    `INSERT INTO smart_notification_profiles (
       tenant_id,
       user_id,
       enabled_types,
       priorities,
       quiet_hours_enabled,
       quiet_from,
       quiet_to,
       test_mode,
       categories,
       channels,
       promo_opt_in,
       updates_opt_in,
       digest_mode,
       frequency_caps,
       badge_preferences,
       updated_at
     )
     VALUES (
       $1,
       $2,
       COALESCE($3::jsonb, '{"order": true, "support": true, "delivery": true}'::jsonb),
       COALESCE($4::jsonb, '{"order": "high", "support": "normal", "delivery": "high"}'::jsonb),
       $5,
       NULLIF($6, ''),
       NULLIF($7, ''),
       COALESCE($8, false),
       $9::jsonb,
       $10::jsonb,
       $11,
       $12,
       $13,
       $14::jsonb,
       $15::jsonb,
       now()
     )
     ON CONFLICT (user_id) DO UPDATE
     SET tenant_id = EXCLUDED.tenant_id,
         quiet_hours_enabled = EXCLUDED.quiet_hours_enabled,
         quiet_from = EXCLUDED.quiet_from,
         quiet_to = EXCLUDED.quiet_to,
         categories = EXCLUDED.categories,
         channels = EXCLUDED.channels,
         promo_opt_in = EXCLUDED.promo_opt_in,
         updates_opt_in = EXCLUDED.updates_opt_in,
         digest_mode = EXCLUDED.digest_mode,
         frequency_caps = EXCLUDED.frequency_caps,
         badge_preferences = EXCLUDED.badge_preferences,
         updated_at = now()
     RETURNING updated_at`,
    [
      user?.tenant_id || null,
      user.id,
      currentRow?.enabled_types ? JSON.stringify(currentRow.enabled_types) : null,
      currentRow?.priorities ? JSON.stringify(currentRow.priorities) : null,
      normalizedResult.quiet_hours_enabled,
      normalizedResult.quiet_from,
      normalizedResult.quiet_to,
      currentRow?.test_mode === true,
      JSON.stringify(normalizedResult.categories),
      JSON.stringify(normalizedResult.channels),
      normalizedResult.promo_opt_in,
      normalizedResult.updates_opt_in,
      normalizedResult.digest_mode,
      JSON.stringify(normalizedResult.frequency_caps),
      JSON.stringify(normalizedResult.badge_preferences),
    ],
  );

  return {
    ...normalizedResult,
    updated_at: result.rows?.[0]?.updated_at || null,
  };
}

async function upsertNotificationEndpoint({
  user,
  platform,
  transport,
  deviceKey,
  pushToken,
  endpoint,
  subscription,
  permissionState,
  capabilities,
  appVersion,
  locale,
  timezone,
  userAgent,
  testOnly = false,
}) {
  const normalizedPlatform = normalizeEndpointPlatform(platform);
  const normalizedTransport = normalizeEndpointTransport(transport);
  const normalizedDeviceKey = String(deviceKey || "").trim() || null;
  const normalizedPushToken = String(pushToken || "").trim() || null;
  const normalizedEndpoint = String(endpoint || "").trim() || null;
  const normalizedSubscription = normalizeJsonMap(subscription);
  const normalizedPermissionState = normalizePermissionState(permissionState);
  const normalizedCapabilities = normalizeJsonMap(capabilities);
  const normalizedAppVersion = String(appVersion || "").trim() || null;
  const normalizedLocale = String(locale || "").trim() || null;
  const normalizedTimezone = canonicalizeNotificationTimeZone(timezone);
  const normalizedUserAgent = String(userAgent || "").trim() || null;

  let existing = null;
  if (normalizedEndpoint) {
    const byEndpoint = await db.query(
      `SELECT id FROM notification_endpoints WHERE endpoint = $1 LIMIT 1`,
      [normalizedEndpoint],
    );
    existing = byEndpoint.rows[0] || null;
  }
  if (!existing && normalizedPushToken) {
    const byToken = await db.query(
      `SELECT id FROM notification_endpoints WHERE push_token = $1 LIMIT 1`,
      [normalizedPushToken],
    );
    existing = byToken.rows[0] || null;
  }
  if (!existing && normalizedDeviceKey) {
    const byDevice = await db.query(
      `SELECT id
         FROM notification_endpoints
        WHERE platform = $1
          AND transport = $2
          AND device_key = $3
        ORDER BY updated_at DESC NULLS LAST, created_at DESC
        LIMIT 1`,
      [normalizedPlatform, normalizedTransport, normalizedDeviceKey],
    );
    existing = byDevice.rows[0] || null;
  }
  if (!existing && normalizedDeviceKey) {
    const byScopedDevice = await db.query(
      `SELECT id
         FROM notification_endpoints
        WHERE user_id = $1
          AND platform = $2
          AND transport = $3
          AND device_key = $4
        LIMIT 1`,
      [user.id, normalizedPlatform, normalizedTransport, normalizedDeviceKey],
    );
    existing = byScopedDevice.rows[0] || null;
  }

  const values = [
    user?.tenant_id || null,
    user.id,
    normalizedPlatform,
    normalizedTransport,
    normalizedDeviceKey,
    normalizedPushToken,
    normalizedEndpoint,
    JSON.stringify(normalizedSubscription),
    normalizedPermissionState,
    JSON.stringify(normalizedCapabilities),
    normalizedAppVersion,
    normalizedLocale,
    normalizedTimezone,
    normalizedUserAgent,
    testOnly === true,
  ];

  if (existing?.id) {
    const updated = await db.query(
      `UPDATE notification_endpoints
          SET tenant_id = $1,
              user_id = $2,
              platform = $3,
              transport = $4,
              device_key = $5,
              push_token = $6,
              endpoint = $7,
              subscription = $8::jsonb,
              permission_state = $9,
              capabilities = $10::jsonb,
              app_version = $11,
              locale = $12,
              timezone = $13,
              user_agent = $14,
              test_only = $15,
              is_active = true,
              last_seen_at = now(),
              updated_at = now()
        WHERE id = $16
        RETURNING *`,
      [...values, existing.id],
    );
    return updated.rows[0] || null;
  }

  const inserted = await db.query(
    `INSERT INTO notification_endpoints (
       tenant_id,
       user_id,
       platform,
       transport,
       device_key,
       push_token,
       endpoint,
       subscription,
       permission_state,
       capabilities,
       app_version,
       locale,
       timezone,
       user_agent,
       test_only,
       is_active,
       last_seen_at,
       updated_at
     )
     VALUES (
       $1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10::jsonb, $11, $12, $13, $14, $15, true, now(), now()
     )
     RETURNING *`,
    values,
  );
  return inserted.rows[0] || null;
}

async function deactivateNotificationEndpoint({ userId, endpoint, pushToken, deviceKey, transport }) {
  const normalizedEndpoint = String(endpoint || "").trim();
  const normalizedPushToken = String(pushToken || "").trim();
  const normalizedDeviceKey = String(deviceKey || "").trim();
  const normalizedTransport = String(transport || "").trim().toLowerCase();
  const result = await db.query(
    `UPDATE notification_endpoints
        SET is_active = false,
            updated_at = now(),
            last_failure_at = CASE WHEN endpoint = $2 OR push_token = $3 THEN now() ELSE last_failure_at END
      WHERE user_id = $1
        AND (
          ($2 <> '' AND endpoint = $2) OR
          ($3 <> '' AND push_token = $3) OR
          ($4 <> '' AND device_key = $4 AND ($5 = '' OR transport = $5))
        )`,
    [userId, normalizedEndpoint, normalizedPushToken, normalizedDeviceKey, normalizedTransport],
  );
  return result.rowCount > 0;
}

async function markEndpointDeliveryState(endpointId, state, { errorMessage = "" } = {}) {
  const normalizedState = String(state || "").trim().toLowerCase();
  if (!endpointId) return;
  const isFailure = normalizedState === "failed";
  await db.query(
    `UPDATE notification_endpoints
        SET last_success_at = CASE WHEN $2::text IN ('sent', 'provider_accepted', 'delivered', 'opened') THEN now() ELSE last_success_at END,
            last_failure_at = CASE WHEN $3::boolean THEN now() ELSE last_failure_at END,
            last_failure_reason = CASE WHEN $3::boolean THEN NULLIF($4, '') ELSE last_failure_reason END,
            updated_at = now()
      WHERE id = $1`,
    [endpointId, normalizedState, isFailure, String(errorMessage || "")],
  );
}

async function countNonUrgentEventsForToday(userId, category) {
  const normalizedCategory = normalizeCategory(category, "promo");
  const q = await db.query(
    `SELECT COUNT(*)::int AS count
       FROM notification_inbox_items
      WHERE user_id = $1
        AND category = $2
        AND created_at >= date_trunc('day', now())`,
    [userId, normalizedCategory],
  );
  return Number(q.rows?.[0]?.count || 0) || 0;
}

async function computeChatUnreadCount(userId) {
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

async function computeNotificationBadgeCount(userId) {
  const user = await getNotificationUser(userId);
  if (!user) return 0;
  const preferences = await getNotificationPreferencesForUser(user);
  const badgePrefs = preferences.badge_preferences;
  if (
    isClientRole(user.role) &&
    Object.values(preferences.channels).every((value) => value != true)
  ) {
    return 0;
  }
  const chatUnread = badgePrefs.count_chat ? await computeChatUnreadCount(userId) : 0;
  const inboxCount = await computeNotificationInboxBadgeCount(userId, {
    user,
    preferences,
  });
  return chatUnread + inboxCount;
}

async function computeNotificationInboxBadgeCount(
  userId,
  { user: providedUser = null, preferences: providedPreferences = null } = {},
) {
  const user = providedUser || await getNotificationUser(userId);
  if (!user) return 0;
  const preferences =
    providedPreferences || await getNotificationPreferencesForUser(user);
  const badgePrefs = preferences.badge_preferences;
  const inboxQ = await db.query(
    `SELECT category, COUNT(*)::int AS count
       FROM notification_inbox_items
      WHERE user_id = $1
        AND status = 'unread'
        AND (expires_at IS NULL OR expires_at > now())
        AND category <> 'chat'
      GROUP BY category`,
    [userId],
  );
  let inboxCount = 0;
  for (const row of inboxQ.rows) {
    const category = normalizeCategory(row.category, "support");
    const count = Number(row.count || 0) || 0;
    if (category === "support" && badgePrefs.count_support) inboxCount += count;
    if (category === "reserved" && badgePrefs.count_reserved) inboxCount += count;
    if (category === "delivery" && badgePrefs.count_delivery) inboxCount += count;
    if (category === "security" && badgePrefs.count_security) inboxCount += count;
    if (category === "promo" && badgePrefs.count_promo) inboxCount += count;
    if (category === "updates" && badgePrefs.count_updates) inboxCount += count;
  }
  return inboxCount;
}

function buildSocketPayload(item, badgeCount, inboxUnreadCount = 0) {
  const media = normalizeJsonMap(item.media);
  const payload = normalizeJsonMap(item.payload);
  return {
    id: String(item.id || ""),
    category: normalizeCategory(item.category, "support"),
    priority: normalizePriority(item.priority, "normal"),
    title: String(item.title || "").trim(),
    body: String(item.body || "").trim(),
    deep_link: String(item.deep_link || "").trim() || null,
    media,
    payload,
    inbox_item_id: String(item.id || "").trim(),
    badge_count: badgeCount,
    inbox_unread_count: inboxUnreadCount,
    force_show: item.force_show === true,
    created_at: item.created_at || null,
    campaign_id: item.campaign_id ? String(item.campaign_id) : null,
    cta_label: String(payload.cta_label || "").trim() || null,
    version: String(payload.version || "").trim() || null,
    required_update: payload.required_update === true,
    thread_id: String(payload.thread_id || payload.chat_id || "").trim() || null,
    ttl_seconds: Number(item.ttl_seconds || 0) || 3600,
    collapse_key: String(item.collapse_key || "").trim() || null,
  };
}

function evaluatePushEligibility(item, preferences) {
  const category = normalizeCategory(item.category, "support");
  const priority = normalizePriority(item.priority, "normal");
  const payloadMeta = normalizeJsonMap(item.payload);
  const isTestPromo = category === "promo" && payloadMeta.test_only === true;
  const isDigestSummary =
    String(item.source_type || "").trim() === "notification_digest" ||
    payloadMeta.digest_summary === true;

  if (preferences.channels.push !== true) {
    return { allowed: false, state: "skipped", reason: "push_disabled" };
  }
  if (!isDigestSummary && !isTestPromo && preferences.categories[category] === false) {
    return { allowed: false, state: "skipped", reason: "category_disabled" };
  }
  if (
    !isDigestSummary &&
    category === "promo" &&
    !isTestPromo &&
    preferences.promo_opt_in !== true
  ) {
    return { allowed: false, state: "skipped", reason: "promo_opt_out" };
  }
  if (
    !isDigestSummary &&
    category === "updates" &&
    preferences.updates_opt_in === false
  ) {
    return { allowed: false, state: "skipped", reason: "updates_opt_out" };
  }
  if (
    !isDigestSummary &&
    isNonUrgentCategory(category, priority) &&
    withinQuietHours({
      enabled: preferences.quiet_hours_enabled,
      from: preferences.quiet_from,
      to: preferences.quiet_to,
    })
  ) {
    return { allowed: false, state: "skipped", reason: "quiet_hours" };
  }
  return {
    allowed: true,
    state: "queued",
    reason: "allowed",
    category,
    priority,
    isDigestSummary,
  };
}

async function maybeSendWebPushForItem(user, item, preferences) {
  const eligibility = evaluatePushEligibility(item, preferences);
  if (!eligibility.allowed) {
    return { sent: 0, state: eligibility.state, reason: eligibility.reason };
  }
  const category = eligibility.category;
  const priority = eligibility.priority;
  const isDigestSummary = eligibility.isDigestSummary === true;
  const payloadMeta = normalizeJsonMap(item.payload);
  const isTestPromo = category === "promo" && payloadMeta.test_only === true;

  if (!isDigestSummary && category === "promo") {
    const todayCount = await countNonUrgentEventsForToday(user.id, "promo");
    if (todayCount > preferences.frequency_caps.promo_per_day) {
      return { sent: 0, state: "skipped", reason: "frequency_cap" };
    }
  }
  if (!isDigestSummary && category === "updates") {
    const todayCount = await countNonUrgentEventsForToday(user.id, "updates");
    if (todayCount > preferences.frequency_caps.updates_per_day) {
      return { sent: 0, state: "skipped", reason: "frequency_cap" };
    }
  }
  if (
    !isDigestSummary &&
    priority === "low" &&
    category !== "promo" &&
    category !== "updates"
  ) {
    const todayCount = await countNonUrgentEventsForToday(user.id, category);
    if (todayCount > preferences.frequency_caps.low_priority_per_day) {
      return { sent: 0, state: "skipped", reason: "frequency_cap" };
    }
  }

  const badgeCount = await computeNotificationBadgeCount(user.id);
  const inboxUnreadCount = await computeNotificationInboxBadgeCount(user.id, {
    user,
    preferences,
  });
  const payload = buildSocketPayload(item, badgeCount, inboxUnreadCount);
  payload.type = category;
  payload.url = payload.deep_link || "/";
  payload.badgeCount = badgeCount;
  payload.tag = String(item.collapse_key || `${category}:${item.id}`);
  payload.data = {
    ...(payload.payload || {}),
    inboxItemId: String(item.id || "").trim(),
  };

  try {
    const { sendWebPushPayloadToUser } = require("./webPush");
    const sent = await sendWebPushPayloadToUser(user.id, payload);
    if (sent > 0) {
      return { sent, state: "sent", reason: "webpush" };
    }
  } catch (err) {
    return {
      sent: 0,
      state: "failed",
      reason: String(err?.message || err || "webpush_failed"),
    };
  }

  return { sent: 0, state: "skipped", reason: "no_push_endpoints" };
}

async function maybeSendNativePushForItem(user, item, preferences) {
  const eligibility = evaluatePushEligibility(item, preferences);
  if (!eligibility.allowed) {
    return { configured: true, skipped: eligibility.reason, results: [] };
  }

  const endpointsQ = await db.query(
    `SELECT *
       FROM notification_endpoints
      WHERE user_id = $1
        AND is_active = true
        AND transport = 'fcm'
        AND push_token IS NOT NULL
        AND btrim(push_token) <> ''
        AND permission_state IN ('granted', 'provisional')
      ORDER BY updated_at DESC NULLS LAST, created_at DESC`,
    [user.id],
  );
  const endpoints = endpointsQ.rows || [];
  if (!endpoints.length) {
    return {
      configured: true,
      skipped: "no_native_push_endpoints",
      results: [],
    };
  }

  const badgeCount = await computeNotificationBadgeCount(user.id);
  const payload = buildSocketPayload(item, badgeCount);
  const { sendFcmPayloadToEndpoints } = require("./nativePush");
  return sendFcmPayloadToEndpoints({
    endpoints,
    payload,
  });
}

async function createNotificationDelivery({
  inboxItemId,
  userId,
  endpointId = null,
  channel = "in_app",
  provider = null,
  state = "queued",
  errorMessage = "",
  metadata = {},
}) {
  const normalizedState = String(state || "queued").trim().toLowerCase();
  const q = await db.query(
    `INSERT INTO notification_deliveries (
       inbox_item_id,
       user_id,
       endpoint_id,
       channel,
       provider,
       state,
       error_message,
       metadata,
       sent_at,
       failed_at,
       delivered_at,
       updated_at
     )
     VALUES (
       $1, $2, $3, $4, $5, $6, NULLIF($7, ''), $8::jsonb,
       CASE WHEN $6::text IN ('sent', 'provider_accepted') THEN now() ELSE NULL END,
       CASE WHEN $6::text = 'failed' THEN now() ELSE NULL END,
       CASE WHEN $6::text IN ('delivered', 'opened') THEN now() ELSE NULL END,
       now()
     )
     RETURNING *`,
    [
      inboxItemId,
      userId,
      endpointId,
      normalizeChannel(channel, "in_app"),
      provider,
      normalizedState,
      String(errorMessage || ""),
      JSON.stringify(normalizeJsonMap(metadata)),
    ],
  );
  return q.rows[0] || null;
}

async function createNotificationInboxItem({
  user,
  category,
  priority = "normal",
  channel = "mixed",
  title,
  body,
  deepLink,
  media = {},
  payload = {},
  dedupeKey = "",
  collapseKey = "",
  ttlSeconds = 3600,
  sourceType = "generic",
  sourceId = "",
  campaignId = null,
  inboxVisibility = "default",
  forceShow = false,
  isActionable = true,
  emit = true,
  attemptPush = true,
}) {
  const normalizedCategory = normalizeCategory(category);
  const normalizedPriority = normalizePriority(priority, "normal");
  const normalizedTitle = String(title || "").trim() || "Новое уведомление";
  const normalizedBody = String(body || "").trim();
  const normalizedDeepLink = String(deepLink || "").trim() || null;
  const normalizedDedupeKey = String(dedupeKey || "").trim();
  const normalizedCollapseKey = String(collapseKey || "").trim() || null;
  const normalizedTtl = normalizeInteger(ttlSeconds, 3600, 60, 60 * 60 * 24 * 30);
  const expiresAt = new Date(Date.now() + normalizedTtl * 1000).toISOString();
  const mediaJson = JSON.stringify(normalizeJsonMap(media));
  const payloadJson = JSON.stringify(normalizeJsonMap(payload));

  let row = null;
  if (normalizedDedupeKey) {
    const existing = await db.query(
      `SELECT *
         FROM notification_inbox_items
        WHERE user_id = $1
          AND dedupe_key = $2
        LIMIT 1`,
      [user.id, normalizedDedupeKey],
    );
    row = existing.rows[0] || null;
  }

  if (row) {
    const updated = await db.query(
      `UPDATE notification_inbox_items
          SET title = $1,
              body = $2,
              deep_link = $3,
              media = $4::jsonb,
              payload = $5::jsonb,
              priority = $6,
              collapse_key = $7,
              ttl_seconds = $8,
              source_type = $9,
              source_id = NULLIF($10, ''),
              campaign_id = $11,
              force_show = $12,
              is_actionable = $13,
              expires_at = $14::timestamptz,
              updated_at = now(),
              status = CASE WHEN status = 'dismissed' THEN status ELSE 'unread' END,
              read_at = CASE WHEN status = 'dismissed' THEN read_at ELSE NULL END
        WHERE id = $15
        RETURNING *`,
      [
        normalizedTitle,
        normalizedBody,
        normalizedDeepLink,
        mediaJson,
        payloadJson,
        normalizedPriority,
        normalizedCollapseKey,
        normalizedTtl,
        String(sourceType || "generic").trim() || "generic",
        String(sourceId || "").trim(),
        campaignId,
        forceShow === true,
        isActionable === true,
        expiresAt,
        row.id,
      ],
    );
    row = updated.rows[0] || row;
  } else {
    const inserted = await db.query(
      `INSERT INTO notification_inbox_items (
         tenant_id,
         user_id,
         category,
         priority,
         channel,
         title,
         body,
         deep_link,
         media,
         payload,
         dedupe_key,
         collapse_key,
         ttl_seconds,
         source_type,
         source_id,
         campaign_id,
         inbox_visibility,
         force_show,
         is_actionable,
         expires_at,
         created_at,
         updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10::jsonb, NULLIF($11, ''), NULLIF($12, ''), $13, $14, NULLIF($15, ''), $16, $17, $18, $19, $20::timestamptz, now(), now()
       )
       RETURNING *`,
      [
        user?.tenant_id || null,
        user.id,
        normalizedCategory,
        normalizedPriority,
        String(channel || "mixed").trim() || "mixed",
        normalizedTitle,
        normalizedBody,
        normalizedDeepLink,
        mediaJson,
        payloadJson,
        normalizedDedupeKey,
        normalizedCollapseKey,
        normalizedTtl,
        String(sourceType || "generic").trim() || "generic",
        String(sourceId || "").trim(),
        campaignId,
        String(inboxVisibility || "default").trim() || "default",
        forceShow === true,
        isActionable === true,
        expiresAt,
      ],
    );
    row = inserted.rows[0] || null;
  }

  if (!row) return null;

  const preferences = await getNotificationPreferencesForUser(user);
  const payloadMeta = normalizeJsonMap(row.payload);
  const isTestPromo = normalizedCategory === "promo" && payloadMeta.test_only === true;
  const categoryEnabled = preferences.categories[normalizedCategory] !== false;
  const inAppAllowed =
    preferences.channels.in_app === true &&
    (isTestPromo || categoryEnabled) &&
    !(normalizedCategory === "promo" && !isTestPromo && preferences.promo_opt_in !== true) &&
    !(normalizedCategory === "updates" && preferences.updates_opt_in === false);

  await createNotificationDelivery({
    inboxItemId: row.id,
    userId: user.id,
    channel: "in_app",
    provider: "socket",
    state: inAppAllowed ? "queued" : "skipped",
    errorMessage: inAppAllowed ? "" : "in_app_disabled",
    metadata: { in_app_allowed: inAppAllowed },
  });

  if (attemptPush) {
    const pushPolicy = evaluatePushEligibility(row, preferences);
    if (!pushPolicy.allowed) {
      await createNotificationDelivery({
        inboxItemId: row.id,
        userId: user.id,
        channel: "push",
        provider: null,
        state: pushPolicy.state,
        errorMessage: "",
        metadata: pushPolicy,
      });
    } else {
      const webPushResult = await maybeSendWebPushForItem(user, row, preferences);
      const nativePushResult = await maybeSendNativePushForItem(
        user,
        row,
        preferences,
      );

      const hasWebPushSignal =
        webPushResult.sent > 0 ||
        webPushResult.state === "failed" ||
        webPushResult.reason !== "no_push_endpoints";
      if (hasWebPushSignal) {
        await createNotificationDelivery({
          inboxItemId: row.id,
          userId: user.id,
          channel: "push",
          provider: webPushResult.reason === "webpush" ? "webpush" : null,
          state: webPushResult.state,
          errorMessage: webPushResult.state === "failed"
            ? webPushResult.reason
            : "",
          metadata: webPushResult,
        });
      }

      if (Array.isArray(nativePushResult.results)) {
        for (const result of nativePushResult.results) {
          await createNotificationDelivery({
            inboxItemId: row.id,
            userId: user.id,
            endpointId: result.endpointId || null,
            channel: "push",
            provider: "fcm",
            state: result.state,
            errorMessage: result.errorMessage || "",
            metadata: result,
          });
          if (result.endpointId) {
            await markEndpointDeliveryState(result.endpointId, result.state, {
              errorMessage: result.errorMessage || "",
            });
            if (result.deactivateEndpoint === true) {
              await db.query(
                `UPDATE notification_endpoints
                    SET is_active = false,
                        updated_at = now(),
                        last_failure_at = now(),
                        last_failure_reason = NULLIF($2, '')
                  WHERE id = $1`,
                [result.endpointId, String(result.errorMessage || "")],
              );
            }
          }
        }
      }

      if (!hasWebPushSignal && !(nativePushResult.results || []).length) {
        await createNotificationDelivery({
          inboxItemId: row.id,
          userId: user.id,
          channel: "push",
          provider: null,
          state: "skipped",
          errorMessage: "",
          metadata: {
            reason: nativePushResult.configured === false
              ? "native_push_not_configured"
              : "no_push_endpoints",
          },
        });
      }
    }
  }

  if (emit && inAppAllowed) {
    const io = global.__projectPhoenixSocketIo;
    if (io) {
      const badgeCount = await computeNotificationBadgeCount(user.id);
      const inboxUnreadCount = await computeNotificationInboxBadgeCount(
        user.id,
        { user },
      );
      emitToUser(
        io,
        user.id,
        "notification:new",
        buildSocketPayload(row, badgeCount, inboxUnreadCount),
      );
      emitToUser(io, user.id, "notification:badge", {
        unread_count: badgeCount,
        inbox_unread_count: inboxUnreadCount,
      });
    }
  }

  return row;
}

async function listNotificationInbox({ userId, limit = 60, unreadOnly = false, category = "" }) {
  const normalizedLimit = normalizeInteger(limit, 60, 1, 200);
  const normalizedCategory = String(category || "").trim().toLowerCase();
  const q = await db.query(
    `SELECT *
       FROM notification_inbox_items
      WHERE user_id = $1
        AND ($2::boolean = false OR status = 'unread')
        AND ($3::text = '' OR category = $3::text)
        AND (expires_at IS NULL OR expires_at > now() OR status <> 'unread')
      ORDER BY created_at DESC
      LIMIT $4`,
    [userId, unreadOnly === true, normalizedCategory, normalizedLimit],
  );
  return q.rows;
}

async function markNotificationInboxItemRead({ userId, itemId }) {
  const q = await db.query(
    `UPDATE notification_inbox_items
        SET status = 'read',
            read_at = COALESCE(read_at, now()),
            updated_at = now()
      WHERE id = $1
        AND user_id = $2
      RETURNING *`,
    [itemId, userId],
  );
  const row = q.rows[0] || null;
  if (row) {
    const badgeCount = await computeNotificationBadgeCount(userId);
    const inboxUnreadCount = await computeNotificationInboxBadgeCount(userId);
    const io = global.__projectPhoenixSocketIo;
    if (io) {
      emitToUser(io, userId, "notification:read", {
        id: itemId,
        unread_count: badgeCount,
        inbox_unread_count: inboxUnreadCount,
      });
      emitToUser(io, userId, "notification:badge", {
        unread_count: badgeCount,
        inbox_unread_count: inboxUnreadCount,
      });
    }
  }
  return row;
}

async function markNotificationInboxItemOpened({ userId, itemId }) {
  const itemQ = await db.query(
    `UPDATE notification_inbox_items
        SET status = CASE WHEN status = 'dismissed' THEN status ELSE 'read' END,
            read_at = CASE WHEN status = 'dismissed' THEN read_at ELSE COALESCE(read_at, now()) END,
            updated_at = now()
      WHERE id = $1
        AND user_id = $2
      RETURNING *`,
    [itemId, userId],
  );
  const row = itemQ.rows[0] || null;
  if (!row) return null;

  const deliveryQ = await db.query(
    `SELECT id
       FROM notification_deliveries
      WHERE inbox_item_id = $1
        AND user_id = $2
        AND state IN ('queued', 'sent', 'provider_accepted', 'delivered')
      ORDER BY CASE WHEN channel = 'push' THEN 0 ELSE 1 END, created_at DESC
      LIMIT 1`,
    [itemId, userId],
  );
  const targetDeliveryId = deliveryQ.rows?.[0]?.id || null;
  if (targetDeliveryId) {
    await db.query(
      `UPDATE notification_deliveries
          SET state = 'opened',
              opened_at = COALESCE(opened_at, now()),
              delivered_at = COALESCE(delivered_at, now()),
              updated_at = now()
        WHERE id = $1`,
      [targetDeliveryId],
    );
  }

  const badgeCount = await computeNotificationBadgeCount(userId);
  const inboxUnreadCount = await computeNotificationInboxBadgeCount(userId);
  const io = global.__projectPhoenixSocketIo;
  if (io) {
    emitToUser(io, userId, "notification:read", {
      id: itemId,
      unread_count: badgeCount,
      inbox_unread_count: inboxUnreadCount,
    });
    emitToUser(io, userId, "notification:badge", {
      unread_count: badgeCount,
      inbox_unread_count: inboxUnreadCount,
    });
  }
  return row;
}

async function markAllNotificationInboxItemsRead({ userId }) {
  await db.query(
    `UPDATE notification_inbox_items
        SET status = 'read',
            read_at = COALESCE(read_at, now()),
            updated_at = now()
      WHERE user_id = $1
        AND status = 'unread'`,
    [userId],
  );
  const badgeCount = await computeNotificationBadgeCount(userId);
  const inboxUnreadCount = await computeNotificationInboxBadgeCount(userId);
  const io = global.__projectPhoenixSocketIo;
  if (io) {
    emitToUser(io, userId, "notification:badge", {
      unread_count: badgeCount,
      inbox_unread_count: inboxUnreadCount,
    });
  }
  return badgeCount;
}

async function markChatInboxItemsRead({ userId, chatId }) {
  const normalizedChatId = String(chatId || "").trim();
  if (!normalizedChatId) return 0;
  const q = await db.query(
    `UPDATE notification_inbox_items
        SET status = 'read',
            read_at = COALESCE(read_at, now()),
            updated_at = now()
      WHERE user_id = $1
        AND category = 'chat'
        AND status = 'unread'
        AND (
          payload->>'chat_id' = $2 OR
          payload->>'chatId' = $2
        )`,
    [userId, normalizedChatId],
  );
  return q.rowCount || 0;
}

async function syncLegacyWebPushEndpoint({ userId, tenantId = null, endpoint, subscription, userAgent = "" }) {
  const pseudoUser = { id: userId, tenant_id: tenantId, role: "client" };
  return upsertNotificationEndpoint({
    user: pseudoUser,
    platform: "web",
    transport: "webpush",
    deviceKey: endpoint,
    endpoint,
    subscription,
    permissionState: "granted",
    capabilities: {
      push: true,
      in_app: true,
      badge: true,
      media_rich: true,
    },
    userAgent,
  });
}

async function deactivateLegacyWebPushEndpoint({ userId, endpoint }) {
  return deactivateNotificationEndpoint({
    userId,
    endpoint,
    transport: "webpush",
  });
}

async function listPromotionCampaignsForAdmin(user) {
  const q = await db.query(
    `SELECT id,
            tenant_id,
            created_by,
            created_by_role,
            kind,
            status,
            title,
            body,
            deep_link,
            media,
            audience_filter,
            sent_count,
            error_message,
            created_at,
            updated_at,
            scheduled_at,
            sent_at,
            metadata
       FROM notification_campaigns
      WHERE created_by = $1
        AND kind = 'promo'
      ORDER BY created_at DESC
      LIMIT 50`,
    [user.id],
  );
  return q.rows;
}

async function getPromotionAnalyticsForCreator() {
  const [summaryQ, campaignsQ] = await Promise.all([
    db.query(
      `SELECT COUNT(*)::int AS campaigns_total,
              COUNT(*) FILTER (WHERE status = 'sent')::int AS campaigns_sent,
              COUNT(*) FILTER (WHERE status = 'error')::int AS campaigns_error,
              COALESCE(SUM(sent_count), 0)::int AS recipients_total
         FROM notification_campaigns
        WHERE kind = 'promo'`,
    ),
    db.query(
      `SELECT c.id,
              c.tenant_id,
              c.created_by,
              c.created_by_role,
              c.status,
              c.title,
              c.sent_count,
              c.error_message,
              c.created_at,
              c.sent_at,
              COUNT(d.*) FILTER (WHERE d.state IN ('sent', 'provider_accepted', 'delivered', 'opened'))::int AS deliveries_sent,
              COUNT(d.*) FILTER (WHERE d.state = 'failed')::int AS deliveries_failed,
              COUNT(d.*) FILTER (WHERE d.state = 'opened')::int AS deliveries_opened
         FROM notification_campaigns c
         LEFT JOIN notification_inbox_items i
           ON i.campaign_id = c.id
         LEFT JOIN notification_deliveries d
           ON d.inbox_item_id = i.id
        WHERE c.kind = 'promo'
        GROUP BY c.id
        ORDER BY c.created_at DESC
        LIMIT 100`,
    ),
  ]);
  return {
    summary: summaryQ.rows[0] || {
      campaigns_total: 0,
      campaigns_sent: 0,
      campaigns_error: 0,
      recipients_total: 0,
    },
    campaigns: campaignsQ.rows,
  };
}

async function createPromotionCampaign({
  actor,
  title,
  body,
  deepLink,
  media = {},
  testOnly = false,
}) {
  const normalizedTitle = String(title || "").trim() || "Акция Проект Феникс";
  const normalizedBody = String(body || "").trim() || "Новое предложение";
  const normalizedDeepLink = String(deepLink || "").trim() || "/";
  const inserted = await db.query(
    `INSERT INTO notification_campaigns (
       tenant_id,
       created_by,
       created_by_role,
       kind,
       status,
       title,
       body,
       deep_link,
       media,
       audience_filter,
       created_at,
       updated_at,
       metadata
     )
     VALUES (
       $1, $2, $3, $4, 'queued', $5, $6, $7, $8::jsonb, $9::jsonb, now(), now(), $10::jsonb
     )
     RETURNING *`,
    [
      actor?.tenant_id || null,
      actor.id,
      actor.role,
      testOnly ? "test" : "promo",
      normalizedTitle,
      normalizedBody,
      normalizedDeepLink,
      JSON.stringify(normalizeJsonMap(media)),
      JSON.stringify({ tenant_only: actor?.tenant_id || null, promo_opt_in_only: !testOnly }),
      JSON.stringify({ test_only: testOnly === true }),
    ],
  );
  return inserted.rows[0] || null;
}

async function resolvePromotionAudience({ actor, testOnly = false }) {
  if (testOnly) {
    const q = await db.query(
      `SELECT id, email, name, role, tenant_id
         FROM users
        WHERE id = $1
        LIMIT 1`,
      [actor.id],
    );
    return q.rows;
  }
  const q = await db.query(
    `SELECT u.id, u.email, u.name, u.role, u.tenant_id
       FROM users u
       LEFT JOIN smart_notification_profiles snp
         ON snp.user_id = u.id
      WHERE u.role = 'client'
        AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
        AND COALESCE(snp.promo_opt_in, false) = true`,
    [actor?.tenant_id || null],
  );
  return q.rows;
}

async function finalizeCampaign(campaignId, { status, sentCount = 0, errorMessage = "" }) {
  const q = await db.query(
    `UPDATE notification_campaigns
        SET status = $2,
            sent_count = $3,
            error_message = NULLIF($4, ''),
            sent_at = CASE WHEN $2::text = 'sent' THEN now() ELSE sent_at END,
            updated_at = now()
      WHERE id = $1
      RETURNING *`,
    [campaignId, String(status || "draft").trim().toLowerCase(), sentCount, String(errorMessage || "")],
  );
  return q.rows[0] || null;
}

async function dispatchPromotionCampaign({ actor, title, body, deepLink, media = {}, testOnly = false }) {
  const campaign = await createPromotionCampaign({
    actor,
    title,
    body,
    deepLink,
    media,
    testOnly,
  });
  if (!campaign) {
    throw new Error("campaign_create_failed");
  }

  const recipients = await resolvePromotionAudience({ actor, testOnly });
  let sentCount = 0;
  for (const recipient of recipients) {
    await createNotificationInboxItem({
      user: recipient,
      category: "promo",
      priority: testOnly ? "normal" : "low",
      channel: "mixed",
      title: campaign.title,
      body: campaign.body,
      deepLink: campaign.deep_link,
      media: campaign.media,
      payload: {
        campaign_id: campaign.id,
        test_only: testOnly === true,
      },
      dedupeKey: `${testOnly ? "promo-test" : "promo"}:${campaign.id}:${recipient.id}`,
      collapseKey: `promo:${campaign.id}`,
      ttlSeconds: 60 * 60 * 24 * 3,
      sourceType: "promotion_campaign",
      sourceId: campaign.id,
      campaignId: campaign.id,
      forceShow: testOnly === true,
      isActionable: true,
      emit: true,
      attemptPush: true,
    });
    sentCount += 1;
  }

  await finalizeCampaign(campaign.id, {
    status: "sent",
    sentCount,
  });

  const io = global.__projectPhoenixSocketIo;
  if (io) {
    emitToUser(io, actor.id, "notification:campaign-status", {
      campaign_id: campaign.id,
      status: "sent",
      sent_count: sentCount,
      test_only: testOnly === true,
    });
  }

  return {
    campaign_id: campaign.id,
    sent_count: sentCount,
    test_only: testOnly === true,
  };
}

function getLocalTimeParts(timeZone, now = new Date()) {
  const safeTimeZone = normalizeNotificationTimeZone(timeZone);
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: safeTimeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const parts = formatter.formatToParts(now);
  const map = {};
  for (const part of parts) {
    if (part.type === "literal") continue;
    map[part.type] = part.value;
  }
  return {
    year: Number(map.year || 0),
    month: Number(map.month || 0),
    day: Number(map.day || 0),
    hour: Number(map.hour || 0),
    minute: Number(map.minute || 0),
  };
}

function localDateStringFor(timeZone, now = new Date()) {
  const parts = getLocalTimeParts(timeZone, now);
  const year = String(parts.year || 0).padStart(4, "0");
  const month = String(parts.month || 0).padStart(2, "0");
  const day = String(parts.day || 0).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function localClockMinutesFor(timeZone, now = new Date()) {
  const parts = getLocalTimeParts(timeZone, now);
  return (parts.hour || 0) * 60 + (parts.minute || 0);
}

function clockToMinutes(rawClock, fallbackMinutes) {
  const normalized = normalizeClock(rawClock);
  if (!normalized) return fallbackMinutes;
  const [hours, minutes] = normalized.split(":").map((value) => Number(value));
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) {
    return fallbackMinutes;
  }
  return hours * 60 + minutes;
}

async function resolveNotificationTimezone(userId) {
  const endpointQ = await db.query(
    `SELECT id, timezone
       FROM notification_endpoints
      WHERE user_id = $1
        AND is_active = true
        AND timezone IS NOT NULL
        AND btrim(timezone) <> ''
      ORDER BY last_seen_at DESC NULLS LAST, updated_at DESC NULLS LAST, created_at DESC
      LIMIT 1`,
    [userId],
  );
  const endpoint = endpointQ.rows?.[0] || null;
  const rawTimezone = String(endpoint?.timezone || "").trim();
  const normalizedTimezone = canonicalizeNotificationTimeZone(rawTimezone);
  if (endpoint?.id && rawTimezone && normalizedTimezone && normalizedTimezone !== rawTimezone) {
    await db.query(
      `UPDATE notification_endpoints
          SET timezone = $2,
              updated_at = now()
        WHERE id = $1`,
      [endpoint.id, normalizedTimezone],
    );
  } else if (endpoint?.id && rawTimezone && !normalizedTimezone) {
    await db.query(
      `UPDATE notification_endpoints
          SET timezone = NULL,
              updated_at = now()
        WHERE id = $1`,
      [endpoint.id],
    );
  }
  return normalizedTimezone || "UTC";
}

async function recordNotificationDigestRun({
  userId,
  localDate,
  timezone,
  digestMode,
  itemCount,
  inboxItemId,
}) {
  await db.query(
    `INSERT INTO notification_digest_runs (
       user_id,
       local_date,
       timezone,
       digest_mode,
       item_count,
       inbox_item_id,
       sent_at,
       created_at
     )
     VALUES ($1, $2::date, $3, $4, $5, $6, now(), now())
     ON CONFLICT (user_id, local_date, digest_mode)
     DO UPDATE
        SET item_count = EXCLUDED.item_count,
            inbox_item_id = EXCLUDED.inbox_item_id,
            timezone = EXCLUDED.timezone,
            sent_at = EXCLUDED.sent_at`,
    [userId, localDate, timezone, digestMode, itemCount, inboxItemId || null],
  );
}

function shouldSendDigestNow(preferences, timeZone) {
  const localMinutes = localClockMinutesFor(timeZone);
  if (preferences.quiet_hours_enabled === true && normalizeClock(preferences.quiet_to)) {
    return localMinutes >= clockToMinutes(preferences.quiet_to, 10 * 60);
  }
  return localMinutes >= 10 * 60;
}

function buildDigestSummaryBody(rows = []) {
  const counts = new Map();
  for (const row of rows) {
    const category = normalizeCategory(row.category, "updates");
    counts.set(category, (counts.get(category) || 0) + 1);
  }
  const segments = [];
  if (counts.get("promo")) {
    segments.push(`акции: ${counts.get("promo")}`);
  }
  if (counts.get("updates")) {
    segments.push(`обновления: ${counts.get("updates")}`);
  }
  const lowPriorityCount = Array.from(counts.entries())
    .filter(([category]) => category !== "promo" && category !== "updates")
    .reduce((sum, [, value]) => sum + value, 0);
  if (lowPriorityCount > 0) {
    segments.push(`несрочные события: ${lowPriorityCount}`);
  }
  if (!segments.length) {
    return "Собрали задержанные несрочные уведомления в одну сводку.";
  }
  return `Собрали задержанные несрочные уведомления: ${segments.join(" • ")}.`;
}

async function runNotificationDigestSweep() {
  const usersQ = await db.query(
    `SELECT u.id, u.email, u.name, u.role, u.tenant_id
       FROM users u
       JOIN smart_notification_profiles snp
         ON snp.user_id = u.id
      WHERE u.role = 'creator'
        AND COALESCE(snp.digest_mode, 'off') <> 'off'
        AND u.is_active = true`,
  );

  for (const user of usersQ.rows) {
    try {
      const preferences = await getNotificationPreferencesForUser(user);
      if (preferences.digest_mode === "off") continue;

      const timezone = await resolveNotificationTimezone(user.id);
      if (!shouldSendDigestNow(preferences, timezone)) {
        continue;
      }

      const localDate = localDateStringFor(timezone);
      const alreadySentQ = await db.query(
        `SELECT 1
           FROM notification_digest_runs
          WHERE user_id = $1
            AND local_date = $2::date
            AND digest_mode = $3
          LIMIT 1`,
        [user.id, localDate, preferences.digest_mode],
      );
      if (alreadySentQ.rowCount > 0) continue;

      const lastRunQ = await db.query(
        `SELECT sent_at
           FROM notification_digest_runs
          WHERE user_id = $1
          ORDER BY sent_at DESC
          LIMIT 1`,
        [user.id],
      );
      const since = lastRunQ.rows?.[0]?.sent_at || new Date(Date.now() - 36 * 60 * 60 * 1000);

      const itemsQ = await db.query(
        `SELECT id, category, priority, title, created_at
           FROM notification_inbox_items
          WHERE user_id = $1
            AND status = 'unread'
            AND created_at > $2::timestamptz
            AND (expires_at IS NULL OR expires_at > now())
            AND COALESCE(source_type, '') <> 'notification_digest'
            AND COALESCE(payload->>'digest_summary', 'false') <> 'true'
            AND (
              category IN ('promo', 'updates') OR
              priority = 'low'
            )
          ORDER BY created_at DESC
          LIMIT 50`,
        [user.id, since],
      );
      const items = itemsQ.rows || [];
      if (!items.length) continue;

      const digestItem = await createNotificationInboxItem({
        user,
        category: "updates",
        priority: "normal",
        channel: "mixed",
        title: "Ежедневная сводка Феникс",
        body: buildDigestSummaryBody(items),
        deepLink: "/notifications",
        payload: {
          digest_summary: true,
          digest_mode: preferences.digest_mode,
          local_date: localDate,
          timezone,
          item_count: items.length,
          categories: items.reduce((acc, row) => {
            const category = normalizeCategory(row.category, "updates");
            acc[category] = (acc[category] || 0) + 1;
            return acc;
          }, {}),
          cta_label: "Открыть сводку",
        },
        dedupeKey: `digest:${localDate}`,
        collapseKey: `digest:${localDate}`,
        ttlSeconds: 60 * 60 * 24,
        sourceType: "notification_digest",
        sourceId: localDate,
        forceShow: false,
        isActionable: true,
        emit: true,
        attemptPush: true,
      });

      await recordNotificationDigestRun({
        userId: user.id,
        localDate,
        timezone,
        digestMode: preferences.digest_mode,
        itemCount: items.length,
        inboxItemId: digestItem?.id || null,
      });
    } catch (err) {
      console.error("runNotificationDigestSweep user error", {
        userId: user.id,
        message: err?.message || err,
      });
    }
  }
}

module.exports = {
  canAccessNotificationInbox,
  getNotificationPreferencesForUser,
  upsertNotificationPreferences,
  upsertNotificationEndpoint,
  deactivateNotificationEndpoint,
  computeNotificationBadgeCount,
  computeNotificationInboxBadgeCount,
  createNotificationInboxItem,
  listNotificationInbox,
  markNotificationInboxItemOpened,
  markNotificationInboxItemRead,
  markAllNotificationInboxItemsRead,
  markChatInboxItemsRead,
  syncLegacyWebPushEndpoint,
  deactivateLegacyWebPushEndpoint,
  listPromotionCampaignsForAdmin,
  getPromotionAnalyticsForCreator,
  dispatchPromotionCampaign,
  runNotificationDigestSweep,
  normalizeCategory,
  normalizePriority,
  normalizeChannel,
  normalizeDigestMode,
  withinQuietHours,
};
