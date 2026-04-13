const db = require("../db");

const DEFAULT_MESSENGER_PREFERENCES = Object.freeze({
  allow_unknown_dm_requests: true,
  allow_tenant_first_contact: true,
  send_read_receipts: true,
  default_disappearing_timer: "off",
  allow_listen_once_voice: true,
  playback_speed: "1.0",
});

function normalizeTimer(raw) {
  const value = String(raw || "")
    .trim()
    .toLowerCase();
  if (["24h", "7d", "30d"].includes(value)) return value;
  return "off";
}

function normalizePlaybackSpeed(raw) {
  const value = String(raw || "")
    .trim()
    .toLowerCase();
  if (["1.0", "1.5", "2.0"].includes(value)) return value;
  return DEFAULT_MESSENGER_PREFERENCES.playback_speed;
}

function normalizeBool(raw, fallback) {
  if (typeof raw === "boolean") return raw;
  if (raw === 1 || raw === "1" || raw === "true") return true;
  if (raw === 0 || raw === "0" || raw === "false") return false;
  return fallback;
}

function normalizeMessengerPreferences(row) {
  const source = row && typeof row === "object" ? row : {};
  return {
    allow_unknown_dm_requests: normalizeBool(
      source.allow_unknown_dm_requests,
      DEFAULT_MESSENGER_PREFERENCES.allow_unknown_dm_requests,
    ),
    allow_tenant_first_contact: normalizeBool(
      source.allow_tenant_first_contact,
      DEFAULT_MESSENGER_PREFERENCES.allow_tenant_first_contact,
    ),
    send_read_receipts: normalizeBool(
      source.send_read_receipts,
      DEFAULT_MESSENGER_PREFERENCES.send_read_receipts,
    ),
    default_disappearing_timer: normalizeTimer(
      source.default_disappearing_timer,
    ),
    allow_listen_once_voice: normalizeBool(
      source.allow_listen_once_voice,
      DEFAULT_MESSENGER_PREFERENCES.allow_listen_once_voice,
    ),
    playback_speed: normalizePlaybackSpeed(source.playback_speed),
  };
}

async function getMessengerPreferencesForUser(userId) {
  const result = await db.query(
    `SELECT user_id,
            allow_unknown_dm_requests,
            allow_tenant_first_contact,
            send_read_receipts,
            default_disappearing_timer,
            allow_listen_once_voice,
            playback_speed,
            updated_at
     FROM user_messenger_preferences
     WHERE user_id = $1
     LIMIT 1`,
    [userId],
  );
  if (result.rowCount === 0) {
    return {
      ...DEFAULT_MESSENGER_PREFERENCES,
      updated_at: null,
    };
  }
  return {
    ...normalizeMessengerPreferences(result.rows[0]),
    updated_at: result.rows[0].updated_at || null,
  };
}

async function upsertMessengerPreferencesForUser(userId, patch = {}) {
  const current = await getMessengerPreferencesForUser(userId);
  const next = {
    allow_unknown_dm_requests: normalizeBool(
      patch.allow_unknown_dm_requests,
      current.allow_unknown_dm_requests,
    ),
    allow_tenant_first_contact: normalizeBool(
      patch.allow_tenant_first_contact,
      current.allow_tenant_first_contact,
    ),
    send_read_receipts: normalizeBool(
      patch.send_read_receipts,
      current.send_read_receipts,
    ),
    default_disappearing_timer: Object.prototype.hasOwnProperty.call(
      patch,
      "default_disappearing_timer",
    )
      ? normalizeTimer(patch.default_disappearing_timer)
      : current.default_disappearing_timer,
    allow_listen_once_voice: normalizeBool(
      patch.allow_listen_once_voice,
      current.allow_listen_once_voice,
    ),
    playback_speed: Object.prototype.hasOwnProperty.call(patch, "playback_speed")
      ? normalizePlaybackSpeed(patch.playback_speed)
      : current.playback_speed,
  };

  const result = await db.query(
    `INSERT INTO user_messenger_preferences (
       user_id,
       allow_unknown_dm_requests,
       allow_tenant_first_contact,
       send_read_receipts,
       default_disappearing_timer,
       allow_listen_once_voice,
       playback_speed,
       updated_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, now())
     ON CONFLICT (user_id)
     DO UPDATE
       SET allow_unknown_dm_requests = EXCLUDED.allow_unknown_dm_requests,
           allow_tenant_first_contact = EXCLUDED.allow_tenant_first_contact,
           send_read_receipts = EXCLUDED.send_read_receipts,
           default_disappearing_timer = EXCLUDED.default_disappearing_timer,
           allow_listen_once_voice = EXCLUDED.allow_listen_once_voice,
           playback_speed = EXCLUDED.playback_speed,
           updated_at = now()
     RETURNING user_id,
               allow_unknown_dm_requests,
               allow_tenant_first_contact,
               send_read_receipts,
               default_disappearing_timer,
               allow_listen_once_voice,
               playback_speed,
               updated_at`,
    [
      userId,
      next.allow_unknown_dm_requests,
      next.allow_tenant_first_contact,
      next.send_read_receipts,
      next.default_disappearing_timer,
      next.allow_listen_once_voice,
      next.playback_speed,
    ],
  );
  return {
    ...normalizeMessengerPreferences(result.rows[0]),
    updated_at: result.rows[0]?.updated_at || null,
  };
}

module.exports = {
  DEFAULT_MESSENGER_PREFERENCES,
  getMessengerPreferencesForUser,
  normalizeMessengerPreferences,
  upsertMessengerPreferencesForUser,
};
