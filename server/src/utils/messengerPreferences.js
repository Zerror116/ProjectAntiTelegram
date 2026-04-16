const db = require("../db");

const DEFAULT_MESSENGER_PREFERENCES = Object.freeze({
  allow_unknown_dm_requests: true,
  allow_tenant_first_contact: true,
  send_read_receipts: true,
  default_disappearing_timer: "off",
  allow_listen_once_voice: true,
  playback_speed: "1.0",
  media_auto_download_images: "wifi_cellular",
  media_auto_download_audio: "wifi_cellular",
  media_auto_download_video: "wifi",
  media_auto_download_documents: "wifi",
  media_send_quality_wifi: "hd",
  media_send_quality_cellular: "standard",
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

function normalizeAutoDownload(raw) {
  const value = String(raw || "")
    .trim()
    .toLowerCase();
  if (["never", "wifi", "wifi_cellular"].includes(value)) return value;
  return "wifi";
}

function normalizeSendQuality(raw, fallback = "standard") {
  const value = String(raw || "")
    .trim()
    .toLowerCase();
  if (["standard", "hd", "file"].includes(value)) return value;
  return fallback;
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
    media_auto_download_images: normalizeAutoDownload(
      source.media_auto_download_images,
    ),
    media_auto_download_audio: normalizeAutoDownload(
      source.media_auto_download_audio,
    ),
    media_auto_download_video: normalizeAutoDownload(
      source.media_auto_download_video,
    ),
    media_auto_download_documents: normalizeAutoDownload(
      source.media_auto_download_documents,
    ),
    media_send_quality_wifi: normalizeSendQuality(
      source.media_send_quality_wifi,
      DEFAULT_MESSENGER_PREFERENCES.media_send_quality_wifi,
    ),
    media_send_quality_cellular: normalizeSendQuality(
      source.media_send_quality_cellular,
      DEFAULT_MESSENGER_PREFERENCES.media_send_quality_cellular,
    ),
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
            media_auto_download_images,
            media_auto_download_audio,
            media_auto_download_video,
            media_auto_download_documents,
            media_send_quality_wifi,
            media_send_quality_cellular,
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
    media_auto_download_images: Object.prototype.hasOwnProperty.call(
      patch,
      "media_auto_download_images",
    )
      ? normalizeAutoDownload(patch.media_auto_download_images)
      : current.media_auto_download_images,
    media_auto_download_audio: Object.prototype.hasOwnProperty.call(
      patch,
      "media_auto_download_audio",
    )
      ? normalizeAutoDownload(patch.media_auto_download_audio)
      : current.media_auto_download_audio,
    media_auto_download_video: Object.prototype.hasOwnProperty.call(
      patch,
      "media_auto_download_video",
    )
      ? normalizeAutoDownload(patch.media_auto_download_video)
      : current.media_auto_download_video,
    media_auto_download_documents: Object.prototype.hasOwnProperty.call(
      patch,
      "media_auto_download_documents",
    )
      ? normalizeAutoDownload(patch.media_auto_download_documents)
      : current.media_auto_download_documents,
    media_send_quality_wifi: Object.prototype.hasOwnProperty.call(
      patch,
      "media_send_quality_wifi",
    )
      ? normalizeSendQuality(
          patch.media_send_quality_wifi,
          current.media_send_quality_wifi,
        )
      : current.media_send_quality_wifi,
    media_send_quality_cellular: Object.prototype.hasOwnProperty.call(
      patch,
      "media_send_quality_cellular",
    )
      ? normalizeSendQuality(
          patch.media_send_quality_cellular,
          current.media_send_quality_cellular,
        )
      : current.media_send_quality_cellular,
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
       media_auto_download_images,
       media_auto_download_audio,
       media_auto_download_video,
       media_auto_download_documents,
       media_send_quality_wifi,
       media_send_quality_cellular,
       updated_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, now())
     ON CONFLICT (user_id)
     DO UPDATE
       SET allow_unknown_dm_requests = EXCLUDED.allow_unknown_dm_requests,
           allow_tenant_first_contact = EXCLUDED.allow_tenant_first_contact,
           send_read_receipts = EXCLUDED.send_read_receipts,
           default_disappearing_timer = EXCLUDED.default_disappearing_timer,
           allow_listen_once_voice = EXCLUDED.allow_listen_once_voice,
           playback_speed = EXCLUDED.playback_speed,
           media_auto_download_images = EXCLUDED.media_auto_download_images,
           media_auto_download_audio = EXCLUDED.media_auto_download_audio,
           media_auto_download_video = EXCLUDED.media_auto_download_video,
           media_auto_download_documents = EXCLUDED.media_auto_download_documents,
           media_send_quality_wifi = EXCLUDED.media_send_quality_wifi,
           media_send_quality_cellular = EXCLUDED.media_send_quality_cellular,
           updated_at = now()
     RETURNING user_id,
               allow_unknown_dm_requests,
               allow_tenant_first_contact,
               send_read_receipts,
               default_disappearing_timer,
               allow_listen_once_voice,
               playback_speed,
               media_auto_download_images,
               media_auto_download_audio,
               media_auto_download_video,
               media_auto_download_documents,
               media_send_quality_wifi,
               media_send_quality_cellular,
               updated_at`,
    [
      userId,
      next.allow_unknown_dm_requests,
      next.allow_tenant_first_contact,
      next.send_read_receipts,
      next.default_disappearing_timer,
      next.allow_listen_once_voice,
      next.playback_speed,
      next.media_auto_download_images,
      next.media_auto_download_audio,
      next.media_auto_download_video,
      next.media_auto_download_documents,
      next.media_send_quality_wifi,
      next.media_send_quality_cellular,
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
