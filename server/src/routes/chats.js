// server/src/routes/chats.js
const express = require("express");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4, validate: uuidValidate } = require("uuid");

const router = express.Router();
const db = require("../db");
const { authMiddleware: requireAuth } = require("../utils/auth");
const { requireRole } = require("../utils/roles");
const { requireChatPermission } = require("../utils/permissions");
const { resolvePermissionSet, hasPermission } = require("../utils/flexibleRoles");
const { emitToTenant, emitToUser } = require("../utils/socket");
const { guardAction } = require("../utils/antifraud");
const { createRateGuard } = require("../utils/rateGuard");
const { buildSupportTemplateAutoReply } = require("../utils/supportAutoReply");
const {
  markChatInboxItemsRead,
  computeNotificationBadgeCount,
} = require("../utils/notifications");
const {
  encryptMessageText,
  decryptMessageText,
  decryptMessageRow,
} = require("../utils/messageCrypto");
const {
  normalizeKeyVersion,
  buildSecretKeyring,
  resolveSecretCandidates,
} = require("../utils/secretKeyring");
const {
  getMessengerPreferencesForUser,
} = require("../utils/messengerPreferences");

const chatImageUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "chat_media",
  "images",
);
const chatVoiceUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "chat_media",
  "voice",
);
const chatVideoUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "chat_media",
  "video",
);
const chatFileUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "chat_media",
  "files",
);
fs.mkdirSync(chatImageUploadsDir, { recursive: true });
fs.mkdirSync(chatVoiceUploadsDir, { recursive: true });
fs.mkdirSync(chatVideoUploadsDir, { recursive: true });
fs.mkdirSync(chatFileUploadsDir, { recursive: true });

const CHAT_MEDIA_TOKEN_TTL_SECONDS = Math.max(
  60,
  Number(process.env.CHAT_MEDIA_TOKEN_TTL_SECONDS || 2 * 60 * 60),
);
const CHAT_MEDIA_KEYRING = buildSecretKeyring({
  purpose: "chat-media",
  currentVersion:
    process.env.CHAT_MEDIA_TOKEN_SECRET_VERSION ||
    process.env.CHAT_MEDIA_TOKEN_KEY_VERSION ||
    "v1",
  singleSecret:
    process.env.CHAT_MEDIA_TOKEN_SECRET || process.env.JWT_SECRET || "",
  keyringString:
    process.env.CHAT_MEDIA_TOKEN_KEYRING ||
    process.env.CHAT_MEDIA_TOKEN_SECRETS ||
    "",
  keyringJson:
    process.env.CHAT_MEDIA_TOKEN_KEYS_JSON ||
    process.env.CHAT_MEDIA_SECRETS_JSON ||
    "",
  requiredInProduction: true,
  devFallbackSecret: "dev-chat-media-secret",
});

const CHAT_MEDIA_MARKERS = Object.freeze({
  image: "/uploads/chat_media/images/",
  voice: "/uploads/chat_media/voice/",
  video: "/uploads/chat_media/video/",
  file: "/uploads/chat_media/files/",
});

const DIRECT_REQUEST_COOLDOWN_HOURS = Math.max(
  1,
  Number(process.env.DIRECT_REQUEST_COOLDOWN_HOURS || 12),
);

const CHAT_MEDIA_MAX_FILE_SIZE_BYTES = Math.max(
  8 * 1024 * 1024,
  Number(process.env.CHAT_MEDIA_MAX_FILE_SIZE_BYTES || 64 * 1024 * 1024),
);
const CHAT_MEDIA_MAX_FILE_SIZE_MB = Math.max(
  8,
  Math.round(CHAT_MEDIA_MAX_FILE_SIZE_BYTES / (1024 * 1024)),
);
const ATTACHMENT_QUALITY_MODES = new Set(["standard", "hd", "file"]);
const ATTACHMENT_TYPES = new Set(["image", "voice", "video", "file"]);
const CHAT_STATE_UUID_FIELDS = new Set([
  "last_read_message_id",
  "last_seen_message_id",
  "scroll_anchor_message_id",
]);

function parsePositiveMediaNumber(raw, { round = true } = {}) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return null;
  return round ? Math.round(value) : Number(value.toFixed(4));
}

function normalizeAttachmentQualityMode(raw) {
  const value = String(raw || "")
    .trim()
    .toLowerCase();
  return ATTACHMENT_QUALITY_MODES.has(value) ? value : "standard";
}

function normalizeAttachmentType(raw) {
  const value = String(raw || "")
    .trim()
    .toLowerCase();
  return ATTACHMENT_TYPES.has(value) ? value : "";
}

function resolveAttachmentQualityMode(raw, attachmentType) {
  const normalizedType = normalizeAttachmentType(attachmentType);
  const normalizedRaw = String(raw || "")
    .trim()
    .toLowerCase();
  if (ATTACHMENT_QUALITY_MODES.has(normalizedRaw)) {
    return {
      qualityMode: normalizedRaw,
      defaulted: false,
      reasonCode: null,
    };
  }
  return {
    qualityMode: normalizedType == "file" ? "file" : "standard",
    defaulted: true,
    reasonCode: normalizedRaw ? "invalid_quality_mode" : "missing_quality_mode",
  };
}

function normalizeUuidPatchField(raw) {
  const value = String(raw || "").trim();
  if (!value) {
    return { accepted: true, value: null, reasonCode: null };
  }
  if (uuidValidate(value)) {
    return { accepted: true, value, reasonCode: null };
  }
  return { accepted: false, value: null, reasonCode: "invalid_uuid" };
}

function sanitizeChatStatePatch(rawPatch, { logPrefix = "chats.state.patch" } = {}) {
  const patch =
    rawPatch && typeof rawPatch === "object" && !Array.isArray(rawPatch)
      ? rawPatch
      : {};
  const normalized = {};
  const dropped = [];

  for (const field of CHAT_STATE_UUID_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(patch, field)) continue;
    const normalizedField = normalizeUuidPatchField(patch[field]);
    if (normalizedField.accepted) {
      normalized[field] = normalizedField.value;
    } else {
      dropped.push({
        field,
        reasonCode: normalizedField.reasonCode,
      });
    }
  }

  if (Object.prototype.hasOwnProperty.call(patch, "draft_text")) {
    normalized.draft_text = patch.draft_text;
  }
  if (Object.prototype.hasOwnProperty.call(patch, "draft_updated_at")) {
    normalized.draft_updated_at = patch.draft_updated_at;
  }
  if (Object.prototype.hasOwnProperty.call(patch, "scroll_anchor_offset")) {
    normalized.scroll_anchor_offset = patch.scroll_anchor_offset;
  }

  if (dropped.length > 0) {
    console.warn(`${logPrefix}: dropped invalid state patch fields`, dropped);
  }

  return { patch: normalized, dropped };
}

function isVoiceMimeAllowed(mimeRaw, originalNameRaw) {
  const mime = String(mimeRaw || "").toLowerCase().trim();
  const originalName = String(originalNameRaw || "").toLowerCase().trim();
  if (mime.startsWith("audio/")) return true;
  if (mime === "application/octet-stream") return true;
  // Some browsers (especially web blob uploads) label voice webm as video/webm.
  if (mime === "video/webm" || mime.startsWith("video/webm;")) return true;
  // Safari/iOS may wrap audio-only recordings in an mp4 container.
  if (mime === "video/mp4" || mime.startsWith("video/mp4;")) return true;
  if (!mime) {
    const ext = path.extname(originalName || "");
    if (
      [".webm", ".m4a", ".aac", ".wav", ".mp3", ".ogg", ".opus", ".mp4"].includes(
        ext,
      )
    ) {
      return true;
    }
  }
  return false;
}

function isVideoMimeAllowed(mimeRaw, originalNameRaw) {
  const mime = String(mimeRaw || "").toLowerCase().trim();
  const originalName = String(originalNameRaw || "").toLowerCase().trim();
  if (mime.startsWith("video/")) return true;
  if (mime === "application/octet-stream") return true;
  if (mime === "application/mp4" || mime.startsWith("application/mp4;")) {
    return true;
  }
  if (mime === "audio/mp4" || mime.startsWith("audio/mp4;")) {
    return true;
  }
  if (mime === "audio/quicktime" || mime.startsWith("audio/quicktime;")) {
    return true;
  }
  if (!mime) {
    const ext = path.extname(originalName || "");
    if ([".mp4", ".m4v", ".mov", ".webm"].includes(ext)) {
      return true;
    }
  }
  return false;
}

const chatMediaUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, file, cb) => {
      if (file.fieldname === "image") {
        cb(null, chatImageUploadsDir);
        return;
      }
      if (file.fieldname === "voice") {
        cb(null, chatVoiceUploadsDir);
        return;
      }
      if (file.fieldname === "video") {
        cb(null, chatVideoUploadsDir);
        return;
      }
      if (file.fieldname === "file") {
        cb(null, chatFileUploadsDir);
        return;
      }
      cb(new Error("Некорректный тип вложения"));
    },
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      const fallbackExt = file.fieldname === "voice"
        ? ".m4a"
        : file.fieldname === "video"
        ? ".mp4"
        : file.fieldname === "file"
        ? ".bin"
        : ".jpg";
      const safeExt = ext && ext.length <= 10 ? ext : fallbackExt;
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: CHAT_MEDIA_MAX_FILE_SIZE_BYTES },
  fileFilter: (_req, file, cb) => {
    const mime = String(file.mimetype || "").toLowerCase().trim();
    if (file.fieldname === "image") {
      if (mime.startsWith("image/")) {
        cb(null, true);
        return;
      }
      cb(new Error("Можно загружать только изображения"));
      return;
    }
    if (file.fieldname === "voice") {
      if (isVoiceMimeAllowed(mime, file.originalname)) {
        cb(null, true);
        return;
      }
      console.warn("[chat-media] rejected voice mime", {
        mime,
        name: file.originalname || "",
      });
      cb(new Error("Можно загружать только аудиофайлы"));
      return;
    }
    if (file.fieldname === "video") {
      if (isVideoMimeAllowed(mime, file.originalname)) {
        cb(null, true);
        return;
      }
      cb(new Error("Можно загружать только видеофайлы"));
      return;
    }
    if (file.fieldname === "file") {
      cb(null, true);
      return;
    }
    cb(new Error("Некорректный тип вложения"));
  },
});

const directSearchRateGuard = createRateGuard({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_DIRECT_SEARCH_MAX || 35),
  blockMs: 30 * 1000,
  message: "Слишком часто ищете пользователей. Повторите через несколько секунд.",
  keyResolver: (req) =>
    [
      req.ip || "",
      req.user?.tenant_id || "",
      req.user?.id || "",
      "direct-search",
    ].join("|"),
});

const directOpenRateGuard = createRateGuard({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_DIRECT_OPEN_MAX || 20),
  blockMs: 45 * 1000,
  message: "Слишком много попыток открыть ЛС. Повторите позже.",
  keyResolver: (req) =>
    [req.ip || "", req.user?.tenant_id || "", req.user?.id || "", "direct-open"].join(
      "|",
    ),
});

function uploadChatMedia(req, res, next) {
  chatMediaUpload.fields([
    { name: "image", maxCount: 10 },
    { name: "voice", maxCount: 1 },
    { name: "video", maxCount: 10 },
    { name: "file", maxCount: 10 },
  ])(req, res, (err) => {
    if (!err) return next();
    console.warn("[chat-media] upload error", {
      code: err?.code || null,
      field: err?.field || null,
      message: err?.message || "unknown",
      contentType: req.headers?.["content-type"] || "",
      userAgent: req.headers?.["user-agent"] || "",
      origin: req.headers?.origin || "",
      chatId: req.params?.chatId || "",
      userId: req.user?.id || "",
    });
    if (err instanceof multer.MulterError && err.code === "LIMIT_FILE_SIZE") {
      return res.status(400).json({
        ok: false,
        error: `Размер вложения не должен превышать ${CHAT_MEDIA_MAX_FILE_SIZE_MB}MB`,
      });
    }
    return res.status(400).json({
      ok: false,
      error: err.message || "Некорректный файл",
    });
  });
}

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function normalizeRole(role) {
  const normalized = String(role || "client")
    .toLowerCase()
    .trim();
  // Арендатор имеет права администратора внутри своего tenant.
  if (normalized === "tenant") return "admin";
  return normalized;
}

function normalizeVisibility(chatType, settings) {
  if (chatType !== "channel") {
    return chatType === "private" ? "private" : "public";
  }
  const visibility = String(settings.visibility || "public")
    .toLowerCase()
    .trim();
  return visibility === "private" ? "private" : "public";
}

function parseBlacklistedUserIds(settings) {
  if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
    return [];
  }
  const raw = Array.isArray(settings.blacklisted_user_ids)
    ? settings.blacklisted_user_ids
    : [];
  const unique = new Set();
  for (const item of raw) {
    const value = String(item || "").trim();
    if (!value) continue;
    unique.add(value);
  }
  return Array.from(unique);
}

function isUserBlacklisted(settings, userId) {
  const userIdText = String(userId || "").trim();
  if (!userIdText) return false;
  return parseBlacklistedUserIds(settings).includes(userIdText);
}

function isBugReportsTitle(title) {
  return (
    String(title || "")
      .toLowerCase()
      .trim() === "баг-репорты"
  );
}

function isAdminOnlyChannel(chat, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  return (
    settings?.admin_only === true ||
    kind === "bug_reports" ||
    isBugReportsTitle(chat?.title)
  );
}

function isBugReportsChannel(chat, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  return kind === "bug_reports" || isBugReportsTitle(chat?.title);
}

function canAccessBugReportsChannel(role) {
  const raw = String(role || "")
    .toLowerCase()
    .trim();
  return raw === "admin" || raw === "creator";
}

function isReservedOrdersChannel(chat, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  const systemKey = String(settings?.system_key || "")
    .toLowerCase()
    .trim();
  return (
    kind === "reserved_orders" ||
    systemKey === "reserved_orders" ||
    String(chat?.title || "")
      .toLowerCase()
      .trim() === "забронированный товар"
  );
}

async function getChatAccessContext(chatId, userId, tenantId = null) {
  const chatQ = await db.query(
    `SELECT id, title, type, settings, tenant_id
     FROM chats
     WHERE id = $1
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
     LIMIT 1`,
    [chatId, tenantId || null],
  );
  if (chatQ.rowCount === 0) return null;

  const chat = chatQ.rows[0];
  const settings = normalizeSettings(chat.settings);
  const hasMembers =
    (
      await db.query("SELECT 1 FROM chat_members WHERE chat_id = $1 LIMIT 1", [
        chatId,
      ])
    ).rowCount > 0;
  let isMember =
    (
      await db.query(
        "SELECT 1 FROM chat_members WHERE chat_id = $1 AND user_id = $2 LIMIT 1",
        [chatId, userId],
      )
    ).rowCount > 0;

  const isSupportTicket =
    String(settings?.kind || "")
      .toLowerCase()
      .trim() === "support_ticket" || settings?.support_ticket === true;
  if (isSupportTicket) {
    const ticketQ = await db.query(
      `SELECT customer_id, assignee_id, status, archived_at
       FROM support_tickets
       WHERE chat_id = $1
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
       ORDER BY updated_at DESC
       LIMIT 1`,
      [chatId, tenantId || null],
    );
    if (ticketQ.rowCount > 0) {
      const ticket = ticketQ.rows[0];
      const userIdText = String(userId || "").trim();
      isMember =
        userIdText.length > 0 &&
        (String(ticket.customer_id || "").trim() === userIdText ||
          String(ticket.assignee_id || "").trim() === userIdText);
      return {
        chat,
        settings,
        visibility: normalizeVisibility(chat.type, settings),
        hasMembers,
        isMember,
        isBlacklisted: isUserBlacklisted(settings, userId),
        supportTicket: {
          customerId: String(ticket.customer_id || "").trim(),
          assigneeId: String(ticket.assignee_id || "").trim(),
          status: String(ticket.status || "").trim().toLowerCase(),
          archivedAt: ticket.archived_at || null,
        },
      };
    } else {
      isMember = false;
    }
  }

  let directRequest = null;
  if (
    chat.type === "private" &&
    String(settings?.kind || "").trim().toLowerCase() === "direct_message"
  ) {
    directRequest = await findDirectRequestByChatId(db.pool, chatId);
  }

  return {
    chat,
    settings,
    visibility: normalizeVisibility(chat.type, settings),
    hasMembers,
    isMember,
    isBlacklisted: isUserBlacklisted(settings, userId),
    viewerUserId: String(userId || "").trim(),
    directRequest,
    directRequestStatus: directRequestStatusForViewer(settings, userId),
  };
}

function canReadChat(context, userRole, permissions = {}) {
  if (!context) return false;
  const role = normalizeRole(userRole);

  if (context.chat.type === "channel") {
    if (context.isBlacklisted && !isAdminOrCreator(role)) {
      return false;
    }
    const reservedOrders = isReservedOrdersChannel(
      context.chat,
      context.settings,
    );
    if (reservedOrders && role === "client") {
      return false;
    }

    const adminOnly = isAdminOnlyChannel(context.chat, context.settings);
    if (adminOnly) {
      if (isBugReportsChannel(context.chat, context.settings)) {
        return canAccessBugReportsChannel(userRole);
      }
      return isAdminOrCreator(role);
    }
    if (context.visibility === "public") return true;
    if (context.isMember) return true;
    return (
      role === "worker" ||
      role === "admin" ||
      role === "tenant" ||
      role === "creator"
    );
  }

  if (isSupportTicketChatContext(context)) {
    if (!context.hasMembers) return false;
    if (context.isMember) return true;
    const status = String(context.supportTicket?.status || "")
      .toLowerCase()
      .trim();
    if (status !== "archived") return false;
    if (role === "admin" || role === "tenant" || role === "creator") {
      return true;
    }
    if (role === "worker") {
      return hasPermission(permissions, "chat.write.support");
    }
    return false;
  }

  if (context.chat.type === "private" && context.directRequestStatus) {
    if (context.directRequestStatus.status === "declined") {
      return false;
    }
  }

  if (context.hasMembers) return context.isMember;
  return true;
}

function canPostChat(context, userRole, permissions = {}) {
  if (!context) return false;
  const role = normalizeRole(userRole);

  if (context.chat.type === "channel") {
    if (role === "client") {
      return false;
    }
    if (context.isBlacklisted && !isAdminOrCreator(role)) {
      return false;
    }
    const reservedOrders = isReservedOrdersChannel(
      context.chat,
      context.settings,
    );
    if (reservedOrders && role === "client") {
      return false;
    }

    const adminOnly = isAdminOnlyChannel(context.chat, context.settings);
    if (adminOnly) {
      if (isBugReportsChannel(context.chat, context.settings)) {
        return canAccessBugReportsChannel(userRole);
      }
      return (
        isAdminOrCreator(role) ||
        hasPermission(permissions, "chat.write.public")
      );
    }
    // В публичных каналах постит только staff с правом chat.write.public
    if (context.visibility === "public") {
      return (
        isAdminOrCreator(role) ||
        hasPermission(permissions, "chat.write.public")
      );
    }
    // В приватных каналах: staff с chat.write.private или участники
    if (
      role === "worker" ||
      role === "admin" ||
      role === "tenant" ||
      role === "creator" ||
      hasPermission(permissions, "chat.write.private")
    )
      return true;
    return context.isMember;
  }

  if (isSupportTicketChatContext(context)) {
    if (!context.hasMembers) return false;
    const status = String(context.supportTicket?.status || "")
      .toLowerCase()
      .trim();
    if (status === "archived") {
      return false;
    }
    return context.isMember;
  }
  if (context.chat.type === "private" && context.directRequestStatus) {
    const status = context.directRequestStatus.status;
    if (status === "accepted") {
      return context.hasMembers ? context.isMember : true;
    }
    if (status === "pending") {
      const viewerId = String(context.directRequestStatus.pending_for || "").trim();
      const currentUserId = String(context.directRequest?.requester_id || "").trim();
      const pendingForCurrentUser = viewerId === String(context.viewerUserId || "").trim();
      if (pendingForCurrentUser) {
        return false;
      }
      return (
        currentUserId.length > 0 &&
        currentUserId === String(context.viewerUserId || "").trim() &&
        !context.directRequest?.first_message_id
      );
    }
    return false;
  }
  if (context.hasMembers) return context.isMember;
  // Открытые публичные чаты доступны только staff.
  // Клиенты пишут в поддержку и в приватные чаты, где они добавлены участниками.
  return (
    role === "worker" ||
    role === "admin" ||
    role === "creator" ||
    hasPermission(permissions, "chat.write.private")
  );
}

function isAdminOrCreator(role) {
  const normalized = normalizeRole(role);
  return normalized === "admin" || normalized === "tenant" || normalized === "creator";
}

function parseMeta(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function isStaffRole(role) {
  const normalized = normalizeRole(role);
  return (
    normalized === "worker" ||
    normalized === "admin" ||
    normalized === "tenant" ||
    normalized === "creator"
  );
}

function supportTicketIdFromSettings(settings) {
  const raw = String(settings?.support_ticket_id || "").trim();
  return raw || null;
}

function isSupportTicketChatContext(context) {
  if (!context || context.chat?.type === "channel") return false;
  const kind = String(context.settings?.kind || "")
    .toLowerCase()
    .trim();
  return kind === "support_ticket" || context.settings?.support_ticket === true;
}

function isSystemMessage(meta) {
  const kind = String(meta?.kind || "")
    .toLowerCase()
    .trim();
  return kind.length > 0;
}

function normalizeReactionEmoji(raw) {
  const value = String(raw || "").trim();
  if (!value) return "";
  const bounded = Array.from(value).slice(0, 8).join("");
  return bounded.trim();
}

function normalizeReactionsByUser(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {};
  }
  const normalized = {};
  for (const [userIdRaw, emojiRaw] of Object.entries(raw)) {
    const userId = String(userIdRaw || "").trim();
    const emoji = normalizeReactionEmoji(emojiRaw);
    if (!userId || !emoji) continue;
    normalized[userId] = emoji;
  }
  return normalized;
}

function normalizePhoneDigits(raw) {
  return String(raw || "").replace(/\D/g, "").slice(0, 15);
}

function normalizePhoneCore10(raw) {
  const digits = normalizePhoneDigits(raw);
  if (digits.length < 10) return "";
  return digits.slice(-10);
}

function escapeLikePattern(raw) {
  return String(raw || "").replace(/[\\%_]/g, "\\$&");
}

function looksLikeEmail(raw) {
  const value = String(raw || "").trim();
  return value.includes("@") && value.length >= 5;
}

function parseBoolean(raw) {
  if (raw === true || raw === false) return raw;
  if (raw === 1 || raw === "1") return true;
  if (raw === 0 || raw === "0") return false;
  const value = String(raw || "")
    .toLowerCase()
    .trim();
  return value === "true" || value === "t" || value === "yes";
}

async function searchDirectTargets(client, requester, { query, limit = 8 }) {
  const requesterId = String(requester?.id || "").trim();
  const tenantId = requester?.tenant_id || null;
  const normalizedQuery = String(query || "").trim();
  if (!requesterId || !normalizedQuery) {
    return { tooShort: true, rows: [], exact: null };
  }

  const phoneDigits = normalizePhoneDigits(normalizedQuery);
  const phoneDigitsAlt =
    phoneDigits.startsWith("8") && phoneDigits.length > 1
      ? `7${phoneDigits.slice(1)}`
      : "";
  const phoneCore10 = normalizePhoneCore10(normalizedQuery);
  const isEmailQuery = looksLikeEmail(normalizedQuery);
  const isDigitsOnlyQuery = /^[0-9]+$/.test(normalizedQuery);
  const isFullPhoneQuery = phoneDigits.length >= 10;
  const canSearchText = normalizedQuery.length >= 2;
  const canSearchPhone = phoneDigits.length >= 4;

  if (!isEmailQuery && !canSearchText && !canSearchPhone) {
    return { tooShort: true, rows: [], exact: null };
  }

  const queryEscaped = escapeLikePattern(normalizedQuery);
  const queryContains = `%${queryEscaped}%`;
  const queryPrefix = `${queryEscaped}%`;
  const safeLimit = Math.max(1, Math.min(Number(limit) || 8, 20));
  const lowerQuery = normalizedQuery.toLowerCase();

  const rowsQ = await client.query(
    `WITH scope_users AS (
       SELECT u.id,
              u.email,
              u.name,
              u.role,
              u.tenant_id,
              p.phone,
              u.avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS avatar_zoom,
              uc.alias_name,
              uc.created_at AS contact_created_at,
              uc.updated_at AS contact_updated_at,
              COALESCE(uc.updated_at, uc.created_at) AS contact_recent_at,
              (uc.contact_user_id IS NOT NULL) AS is_in_contacts,
              regexp_replace(COALESCE(p.phone, ''), '[^0-9]', '', 'g') AS phone_digits,
              RIGHT(regexp_replace(COALESCE(p.phone, ''), '[^0-9]', '', 'g'), 10) AS phone_core10
       FROM users u
       LEFT JOIN phones p ON p.user_id = u.id
       LEFT JOIN user_contacts uc
         ON uc.user_id = $1
        AND uc.contact_user_id = u.id
        AND ($2::uuid IS NULL OR uc.tenant_id = $2::uuid)
       WHERE u.id <> $1
         AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
     ),
     ranked AS (
       SELECT su.*,
             CASE
                WHEN $4::boolean AND LOWER(COALESCE(su.email, '')) = $3::text THEN 900
                WHEN $6::boolean AND su.phone_core10 = $11::text THEN 890
                WHEN (NOT $12::boolean) AND COALESCE(su.name, '') ILIKE $8::text ESCAPE '\\' THEN 780
                WHEN (NOT $12::boolean) AND COALESCE(su.email, '') ILIKE $8::text ESCAPE '\\' THEN 770
                WHEN $9::boolean AND (
                  su.phone_digits LIKE ($5::text || '%')
                  OR ($13::text <> '' AND su.phone_digits LIKE ($13::text || '%'))
                ) THEN 760
                WHEN (NOT $12::boolean) AND COALESCE(su.name, '') ILIKE $7::text ESCAPE '\\' THEN 680
                WHEN (NOT $12::boolean) AND COALESCE(su.email, '') ILIKE $7::text ESCAPE '\\' THEN 670
                ELSE 0
              END AS score
       FROM scope_users su
     )
     SELECT id,
            email,
            name,
            role,
            tenant_id,
            phone,
            avatar_url,
            avatar_focus_x,
            avatar_focus_y,
            avatar_zoom,
            alias_name,
            contact_created_at,
            contact_updated_at,
            contact_recent_at,
            is_in_contacts,
            phone_digits,
            phone_core10,
            score
     FROM ranked
     WHERE score > 0
     ORDER BY score DESC,
              is_in_contacts DESC,
              contact_recent_at DESC NULLS LAST,
              COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(email), ''), id::text) ASC
     LIMIT $10`,
    [
      requesterId,
      tenantId,
      lowerQuery,
      isEmailQuery,
      phoneDigits,
      isFullPhoneQuery,
      queryContains,
      queryPrefix,
      canSearchPhone,
      safeLimit,
      phoneCore10,
      isDigitsOnlyQuery,
      phoneDigitsAlt,
    ],
  );

  const rows = rowsQ.rows || [];
  let exact = null;
  if (isEmailQuery) {
    exact =
      rows.find(
        (row) =>
          String(row.email || "")
            .toLowerCase()
            .trim() === lowerQuery,
      ) || null;
  }
  if (!exact && isFullPhoneQuery) {
    exact =
      rows.find((row) => {
        const rowCore10 = String(row.phone_core10 || "").trim();
        if (rowCore10.length === 10 && phoneCore10.length === 10) {
          return rowCore10 === phoneCore10;
        }
        const rowDigits = normalizePhoneDigits(row.phone);
        return rowDigits.length >= 10 && rowDigits === phoneDigits;
      }) || null;
  }

  return { tooShort: false, rows, exact };
}

async function resolveDirectTargetUser(client, requester, { userId, query }) {
  const requesterId = String(requester?.id || "").trim();
  const tenantId = requester?.tenant_id || null;
  if (!requesterId) return null;

  const byUserId = String(userId || "").trim();
  if (byUserId) {
    const q = await client.query(
      `SELECT u.id,
              u.email,
              u.name,
              u.role,
              u.tenant_id,
              p.phone,
              u.avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS avatar_zoom
       FROM users u
       LEFT JOIN phones p ON p.user_id = u.id
       WHERE u.id = $1
         AND u.id <> $2
         AND ($3::uuid IS NULL OR u.tenant_id = $3::uuid)
       LIMIT 1`,
      [byUserId, requesterId, tenantId],
    );
    if (q.rowCount > 0) return q.rows[0];

    // Fallback for legacy rows where users.tenant_id was not populated.
    // Access is constrained by tenant-related support/claim records.
    if (tenantId) {
      const legacyQ = await client.query(
        `SELECT u.id,
                u.email,
                u.name,
                u.role,
                u.tenant_id,
                p.phone,
                u.avatar_url,
                COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
                COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
                COALESCE(u.avatar_zoom, 1) AS avatar_zoom
         FROM users u
         LEFT JOIN phones p ON p.user_id = u.id
         WHERE u.id = $1
           AND u.id <> $2
           AND u.tenant_id IS NULL
           AND (
             EXISTS (
               SELECT 1
               FROM support_tickets st
               WHERE st.customer_id = u.id
                 AND (
                   st.tenant_id = $3::uuid
                   OR st.tenant_id IS NULL
                 )
               LIMIT 1
             )
             OR EXISTS (
               SELECT 1
               FROM customer_claims cc
               WHERE cc.user_id = u.id
                 AND (
                   cc.tenant_id = $3::uuid
                   OR cc.tenant_id IS NULL
                 )
               LIMIT 1
             )
           )
         LIMIT 1`,
        [byUserId, requesterId, tenantId],
      );
      if (legacyQ.rowCount > 0) return legacyQ.rows[0];
    }
    return null;
  }

  const normalizedQuery = String(query || "").trim();
  if (!normalizedQuery) return null;
  const search = await searchDirectTargets(client, requester, {
    query: normalizedQuery,
    limit: 10,
  });
  if (search.tooShort) return null;
  const isFullIdentifierQuery =
    looksLikeEmail(normalizedQuery) ||
    normalizePhoneDigits(normalizedQuery).length >= 10;
  if (search.exact) return search.exact;
  if (isFullIdentifierQuery) return null;
  return search.rows[0] || null;
}

function mapPeerInfo(row, { includeEmail = false } = {}) {
  if (!row) return null;
  const isInContacts = parseBoolean(row.is_in_contacts);
  const payload = {
    id: row.id,
    name: row.name || "",
    role: row.role || "",
    phone: row.phone || "",
    avatar_url: row.avatar_url || null,
    avatar_focus_x: Number(row.avatar_focus_x || 0),
    avatar_focus_y: Number(row.avatar_focus_y || 0),
    avatar_zoom: Number(row.avatar_zoom || 1),
    alias_name: row.alias_name || "",
    is_in_contacts: isInContacts,
    contact_created_at: row.contact_created_at || null,
    contact_updated_at: row.contact_updated_at || null,
    recent_at: row.recent_at || row.contact_recent_at || null,
  };
  if (includeEmail) {
    payload.email = row.email || "";
  }
  return payload;
}

async function getDirectUserCard(client, userId, tenantId = null) {
  const normalizedUserId = String(userId || "").trim();
  if (!normalizedUserId) return null;
  const q = await client.query(
    `SELECT u.id,
            u.name,
            p.phone,
            u.avatar_url,
            COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
            COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
            COALESCE(u.avatar_zoom, 1) AS avatar_zoom
     FROM users u
     LEFT JOIN phones p ON p.user_id = u.id
     WHERE u.id = $1
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid OR u.tenant_id IS NULL)
     LIMIT 1`,
    [normalizedUserId, tenantId || null],
  );
  return q.rowCount > 0 ? q.rows[0] : null;
}

async function getDirectAliasForViewer(
  client,
  viewerUserId,
  counterpartUserId,
  tenantId = null,
) {
  const viewerId = String(viewerUserId || "").trim();
  const counterpartId = String(counterpartUserId || "").trim();
  if (!viewerId || !counterpartId) return "";
  const q = await client.query(
    `SELECT alias_name
     FROM user_contacts
     WHERE user_id = $1
       AND contact_user_id = $2
       AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
     LIMIT 1`,
    [viewerId, counterpartId, tenantId || null],
  );
  return q.rowCount > 0 ? String(q.rows[0]?.alias_name || "").trim() : "";
}

function buildDirectChatPayloadForViewer(chat, counterpart, aliasName = "") {
  const settings = normalizeSettings(chat?.settings);
  const directRequestStatus = String(settings.direct_request_status || "")
    .trim()
    .toLowerCase();
  const directRequestPendingFor = String(settings.direct_request_pending_for || "")
    .trim();
  const directRequestCreatedBy = String(settings.direct_request_created_by || "")
    .trim();
  const directRequestId = String(settings.direct_request_id || "").trim();
  const directRequestFirstMessageSent =
    settings.direct_request_first_message_sent === true;
  const title =
    String(settings.saved_messages === true ||
      String(settings.kind || "").trim().toLowerCase() === "saved_messages"
      ? "Избранное"
      : aliasName || "").trim() ||
    String(counterpart?.name || "").trim() ||
    String(counterpart?.phone || "").trim() ||
    "Пользователь";
  return {
    ...chat,
    title: "",
    display_title: title,
    peer_user_id: counterpart?.id || null,
    peer_display_name: title,
    peer_name: counterpart?.name || "",
    peer_phone: counterpart?.phone || "",
    peer_avatar_url: counterpart?.avatar_url || null,
    peer_avatar_focus_x: Number(counterpart?.avatar_focus_x || 0),
    peer_avatar_focus_y: Number(counterpart?.avatar_focus_y || 0),
    peer_avatar_zoom: Number(counterpart?.avatar_zoom || 1),
    direct_request_status: directRequestStatus || null,
    direct_request_id: directRequestId || null,
    direct_request_pending_for: directRequestPendingFor || null,
    direct_request_created_by: directRequestCreatedBy || null,
    direct_request_first_message_sent: directRequestFirstMessageSent,
  };
}

function isSavedMessagesSettings(settings) {
  const normalized = normalizeSettings(settings);
  return (
    normalized.saved_messages === true ||
    String(normalized.kind || "").trim().toLowerCase() === "saved_messages"
  );
}

async function ensureSavedMessagesChat(client, user) {
  const userId = String(user?.id || "").trim();
  const tenantId = user?.tenant_id || null;
  if (!userId) return null;
  const userExistsQ = await client.query(
    `SELECT 1
     FROM users
     WHERE id = $1
     LIMIT 1`,
    [userId],
  );
  if (userExistsQ.rowCount === 0) {
    if (
      user?.is_platform_creator === true &&
      user?.is_creator_tenant_scoped === true
    ) {
      if (process.env.NODE_ENV !== "production") {
        console.info("ensureSavedMessagesChat skipped creator tenant shadow user", {
          userId,
          tenantId,
        });
      }
    }
    return null;
  }

  const existingQ = await client.query(
    `SELECT c.id, c.title, c.type, c.settings, c.created_at, c.updated_at
     FROM chats c
     JOIN chat_members cm ON cm.chat_id = c.id
     WHERE cm.user_id = $1
       AND c.type = 'private'
       AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
       AND (
         COALESCE((c.settings->>'saved_messages')::boolean, false) = true
         OR COALESCE(c.settings->>'kind', '') = 'saved_messages'
       )
     ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC
     LIMIT 1`,
    [userId, tenantId],
  );
  if (existingQ.rowCount > 0) {
    const chat = existingQ.rows[0];
    await client.query(
      `INSERT INTO user_chat_preferences (
         user_id, chat_id, hidden, pinned, pinned_at, created_at, updated_at
       )
       VALUES ($1, $2, false, true, now(), now(), now())
       ON CONFLICT (user_id, chat_id)
       DO UPDATE
         SET hidden = false,
             pinned = true,
             pinned_at = COALESCE(user_chat_preferences.pinned_at, now()),
             updated_at = now()`,
      [userId, chat.id],
    );
    return chat;
  }

  const settings = {
    kind: "saved_messages",
    saved_messages: true,
    visibility: "private",
  };
  const insertQ = await client.query(
    `INSERT INTO chats (
       id,
       title,
       type,
       created_by,
       tenant_id,
       settings,
       created_at,
       updated_at
     )
     VALUES ($1, $2, 'private', $3, $4, $5::jsonb, now(), now())
     RETURNING id, title, type, settings, created_at, updated_at`,
    [uuidv4(), "Избранное", userId, tenantId, JSON.stringify(settings)],
  );
  const chat = insertQ.rows[0];
  await client.query(
    `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
     VALUES ($1, $2, $3, now(), 'owner')
     ON CONFLICT (chat_id, user_id) DO NOTHING`,
    [uuidv4(), chat.id, userId],
  );
  await client.query(
    `INSERT INTO user_chat_preferences (
       user_id, chat_id, hidden, pinned, pinned_at, created_at, updated_at
     )
     VALUES ($1, $2, false, true, now(), now(), now())
     ON CONFLICT (user_id, chat_id)
     DO UPDATE
       SET hidden = false,
           pinned = true,
           pinned_at = COALESCE(user_chat_preferences.pinned_at, now()),
           updated_at = now()`,
    [userId, chat.id],
  );
  return chat;
}

async function findDirectRequestByChatId(client, chatId) {
  const q = await client.query(
    `SELECT id,
            tenant_id,
            chat_id,
            requester_id,
            target_user_id,
            status,
            first_message_id,
            cooldown_until,
            responded_at,
            created_at,
            updated_at
     FROM direct_message_requests
     WHERE chat_id = $1
     LIMIT 1`,
    [chatId],
  );
  return q.rowCount > 0 ? q.rows[0] : null;
}

async function findDirectRequestBetweenUsers(client, tenantId, requesterId, targetUserId) {
  const q = await client.query(
    `SELECT id,
            tenant_id,
            chat_id,
            requester_id,
            target_user_id,
            status,
            first_message_id,
            cooldown_until,
            responded_at,
            created_at,
            updated_at
     FROM direct_message_requests
     WHERE requester_id = $1
       AND target_user_id = $2
       AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
     ORDER BY updated_at DESC, created_at DESC
     LIMIT 1`,
    [requesterId, targetUserId, tenantId || null],
  );
  return q.rowCount > 0 ? q.rows[0] : null;
}

async function areUsersConnectedByContact(client, tenantId, leftUserId, rightUserId) {
  const q = await client.query(
    `SELECT 1
     FROM user_contacts
     WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND (
         (user_id = $2 AND contact_user_id = $3)
         OR (user_id = $3 AND contact_user_id = $2)
       )
     LIMIT 1`,
    [tenantId || null, leftUserId, rightUserId],
  );
  return q.rowCount > 0;
}

function directRequestStatusForViewer(settings, viewerUserId) {
  const normalized = normalizeSettings(settings);
  const status = String(normalized.direct_request_status || "")
    .trim()
    .toLowerCase();
  if (!status) return null;
  const pendingFor = String(normalized.direct_request_pending_for || "").trim();
  const createdBy = String(normalized.direct_request_created_by || "").trim();
  const firstMessageSent = normalized.direct_request_first_message_sent === true;
  return {
    status,
    pending_for: pendingFor || null,
    created_by: createdBy || null,
    first_message_sent: firstMessageSent,
    is_pending_for_me:
      status === "pending" &&
      pendingFor.length > 0 &&
      pendingFor === String(viewerUserId || "").trim(),
  };
}

function isDirectMessageSettings(settings) {
  const normalized = normalizeSettings(settings);
  return String(normalized.kind || "").trim().toLowerCase() === "direct_message";
}

function shouldEmitRealtimeActivity(chat, settings) {
  if (!chat) return false;
  if (chat.type !== "private") return false;
  if (isSavedMessagesSettings(settings)) return false;
  return isDirectMessageSettings(settings);
}

function toChatMediaUrl(req, file) {
  if (!file || !file.filename) return null;
  if (file.fieldname === "image") {
    return `${req.protocol}://${req.get("host")}/uploads/chat_media/images/${file.filename}`;
  }
  if (file.fieldname === "voice") {
    return `${req.protocol}://${req.get("host")}/uploads/chat_media/voice/${file.filename}`;
  }
  if (file.fieldname === "video") {
    return `${req.protocol}://${req.get("host")}/uploads/chat_media/video/${file.filename}`;
  }
  if (file.fieldname === "file") {
    return `${req.protocol}://${req.get("host")}/uploads/chat_media/files/${file.filename}`;
  }
  return null;
}

function extractChatMediaRef(rawUrl) {
  const url = String(rawUrl || "").trim();
  if (!url) return null;
  for (const [kind, marker] of Object.entries(CHAT_MEDIA_MARKERS)) {
    const markerIndex = url.indexOf(marker);
    if (markerIndex === -1) continue;
    const filename = decodeURIComponent(
      url.slice(markerIndex + marker.length).split(/[?#]/)[0].trim(),
    );
    if (!filename) return null;
    const normalized = path.basename(filename);
    if (
      normalized !== filename ||
      !/^[A-Za-z0-9._-]+$/.test(normalized) ||
      normalized.startsWith(".")
    ) {
      return null;
    }
    return {
      kind,
      marker,
      filename: normalized,
      canonicalPath: `${marker}${normalized}`,
    };
  }
  return null;
}

function signChatMediaAccess(pathValue, expUnixSeconds, secret) {
  return crypto
    .createHmac("sha256", String(secret || CHAT_MEDIA_KEYRING.currentSecret || ""))
    .update(`${pathValue}:${expUnixSeconds}`)
    .digest("hex");
}

function secureEqualHex(a, b) {
  const left = Buffer.from(String(a || ""), "utf8");
  const right = Buffer.from(String(b || ""), "utf8");
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

function buildSignedChatMediaUrl(req, rawUrl) {
  const ref = extractChatMediaRef(rawUrl);
  if (!ref) return rawUrl;
  const exp = Math.floor(Date.now() / 1000) + CHAT_MEDIA_TOKEN_TTL_SECONDS;
  const signingCandidate =
    resolveSecretCandidates(CHAT_MEDIA_KEYRING, CHAT_MEDIA_KEYRING.currentVersion)[0] ||
    null;
  const keyVersion = signingCandidate?.version || CHAT_MEDIA_KEYRING.currentVersion;
  const sig = signChatMediaAccess(
    ref.canonicalPath,
    exp,
    signingCandidate?.secret || CHAT_MEDIA_KEYRING.currentSecret,
  );
  return `${req.protocol}://${req.get("host")}/api/chats/media/${ref.kind}/${encodeURIComponent(ref.filename)}?exp=${exp}&kid=${encodeURIComponent(keyVersion)}&sig=${sig}`;
}

function decorateMessageMediaUrls(req, rawMessage) {
  if (!rawMessage || typeof rawMessage !== "object") return rawMessage;
  const message = { ...rawMessage };
  const meta = parseMeta(rawMessage.meta);
  const nextMeta = { ...meta };
  let changed = false;
  for (const key of ["image_url", "voice_url", "video_url", "file_url"]) {
    const value = String(nextMeta[key] || "").trim();
    if (!value) continue;
    const signed = buildSignedChatMediaUrl(req, value);
    if (signed !== value) {
      nextMeta[key] = signed;
      changed = true;
    }
  }
  if (changed) {
    message.meta = nextMeta;
  } else {
    message.meta = meta;
  }
  if (Array.isArray(rawMessage.attachments) && rawMessage.attachments.length > 0) {
    message.attachments = rawMessage.attachments.map((attachment) => {
      if (!attachment || typeof attachment !== "object" || Array.isArray(attachment)) {
        return attachment;
      }
      const nextAttachment = { ...attachment };
      const value = String(nextAttachment.storage_url || "").trim();
      if (value.length > 0) {
        nextAttachment.storage_url = buildSignedChatMediaUrl(req, value);
      }
      return nextAttachment;
    });
  }
  return message;
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function removeUploadedFiles(files) {
  for (const file of files) {
    removeUploadedFile(file);
  }
}

function removeChatMediaByUrl(raw) {
  const url = String(raw || "").trim();
  if (!url) return;

  const mappings = [
    {
      marker: "/uploads/chat_media/images/",
      baseDir: chatImageUploadsDir,
    },
    {
      marker: "/uploads/chat_media/voice/",
      baseDir: chatVoiceUploadsDir,
    },
    {
      marker: "/uploads/chat_media/video/",
      baseDir: chatVideoUploadsDir,
    },
    {
      marker: "/uploads/chat_media/files/",
      baseDir: chatFileUploadsDir,
    },
  ];

  for (const { marker, baseDir } of mappings) {
    const idx = url.indexOf(marker);
    if (idx === -1) continue;
    const filename = url.slice(idx + marker.length).split(/[?#]/)[0].trim();
    if (!filename) return;
    const fullPath = path.join(baseDir, filename);
    if (!fullPath.startsWith(baseDir)) return;
    fs.unlink(fullPath, () => {});
    return;
  }
}

async function loadMessageReactionsByUser(messageId) {
  const result = await db.query(
    `SELECT user_id::text AS user_id, emoji
     FROM message_reactions
     WHERE message_id = $1`,
    [messageId],
  );
  const reactions = {};
  for (const row of result.rows) {
    const userId = String(row.user_id || "").trim();
    const emoji = normalizeReactionEmoji(row.emoji);
    if (!userId || !emoji) continue;
    reactions[userId] = emoji;
  }
  return reactions;
}

function legacyAttachmentsFromMeta(meta) {
  const normalized = parseMeta(meta);
  const caption = String(normalized.caption || "").trim();
  const attachments = [];
  if (String(normalized.image_url || "").trim().length > 0) {
    attachments.push({
      attachment_type: "image",
      sort_order: 0,
      storage_url: String(normalized.image_url || "").trim(),
      width: parsePositiveMediaNumber(normalized.image_width),
      height: parsePositiveMediaNumber(normalized.image_height),
      aspect_ratio: parsePositiveMediaNumber(normalized.image_aspect_ratio, {
        round: false,
      }),
      preprocess_tag: String(normalized.image_preprocess || "").trim() || null,
      caption: caption.length > 0 ? caption : null,
    });
  }
  if (String(normalized.voice_url || "").trim().length > 0) {
    attachments.push({
      attachment_type: "voice",
      sort_order: attachments.length,
      storage_url: String(normalized.voice_url || "").trim(),
      duration_ms: parsePositiveMediaNumber(normalized.voice_duration_ms),
      mime_type: String(normalized.voice_mime_type || "").trim() || null,
      file_name: String(normalized.voice_file_name || "").trim() || null,
      is_listen_once: normalized.listen_once === true,
    });
  }
  if (String(normalized.video_url || "").trim().length > 0) {
    attachments.push({
      attachment_type: "video",
      sort_order: attachments.length,
      storage_url: String(normalized.video_url || "").trim(),
      duration_ms: parsePositiveMediaNumber(normalized.video_duration_ms),
      mime_type: String(normalized.video_mime_type || "").trim() || null,
      file_name: String(normalized.video_file_name || "").trim() || null,
      is_video_note: normalized.is_video_note === true,
    });
  }
  if (String(normalized.file_url || "").trim().length > 0) {
    attachments.push({
      attachment_type: "file",
      sort_order: attachments.length,
      storage_url: String(normalized.file_url || "").trim(),
      mime_type: String(normalized.file_mime_type || "").trim() || null,
      file_name: String(normalized.file_name || "").trim() || null,
      file_size: parsePositiveMediaNumber(normalized.file_size),
    });
  }
  return attachments;
}

async function loadMessageAttachmentsByMessageIds(messageIds) {
  const ids = Array.isArray(messageIds)
    ? messageIds
        .map((item) => String(item || "").trim())
        .filter(Boolean)
    : [];
  if (ids.length === 0) return new Map();
  const attachmentsQ = await db.query(
    `SELECT id,
            message_id::text AS message_id,
            attachment_type,
            sort_order,
            media_group_id,
            storage_url,
            file_name,
            mime_type,
            file_size,
            width,
            height,
            aspect_ratio,
            duration_ms,
            preprocess_tag,
            quality_mode,
            is_video_note,
            is_listen_once,
            created_at
     FROM message_attachments
     WHERE message_id = ANY($1::uuid[])
     ORDER BY message_id ASC, sort_order ASC, created_at ASC, id ASC`,
    [ids],
  );
  const byMessageId = new Map();
  for (const row of attachmentsQ.rows) {
    const messageId = String(row.message_id || "").trim();
    if (!messageId) continue;
    const current = byMessageId.get(messageId) || [];
    current.push({
      id: row.id,
      attachment_type: row.attachment_type,
      sort_order: Number(row.sort_order || 0),
      media_group_id: row.media_group_id || null,
      storage_url: row.storage_url || null,
      file_name: row.file_name || null,
      mime_type: row.mime_type || null,
      file_size: row.file_size == null ? null : Number(row.file_size),
      width: row.width == null ? null : Number(row.width),
      height: row.height == null ? null : Number(row.height),
      aspect_ratio: row.aspect_ratio == null ? null : Number(row.aspect_ratio),
      duration_ms: row.duration_ms == null ? null : Number(row.duration_ms),
      preprocess_tag: row.preprocess_tag || null,
      quality_mode: normalizeAttachmentQualityMode(row.quality_mode),
      is_video_note: row.is_video_note === true,
      is_listen_once: row.is_listen_once === true,
      created_at: row.created_at || null,
    });
    byMessageId.set(messageId, current);
  }
  return byMessageId;
}

async function upsertMessageAttachments({
  messageId,
  attachments,
}) {
  const normalizedMessageId = String(messageId || "").trim();
  if (!normalizedMessageId || !Array.isArray(attachments)) return;
  await db.query("DELETE FROM message_attachments WHERE message_id = $1", [
    normalizedMessageId,
  ]);
  for (let index = 0; index < attachments.length; index += 1) {
    const attachment = attachments[index];
    if (!attachment || typeof attachment !== "object") continue;
    const type = normalizeAttachmentType(attachment.attachment_type);
    const storageUrl = String(attachment.storage_url || "").trim();
    if (!type || !storageUrl) continue;
    const qualityResolution = resolveAttachmentQualityMode(
      attachment.quality_mode,
      type,
    );
    if (qualityResolution.defaulted) {
      console.warn("chats.attachments.quality.defaulted", {
        reason_code: qualityResolution.reasonCode,
        message_id: normalizedMessageId,
        attachment_type: type,
        sort_order: Number(attachment.sort_order ?? index) || 0,
      });
    }
    await db.query(
      `INSERT INTO message_attachments (
         id,
         message_id,
         attachment_type,
         sort_order,
         media_group_id,
         storage_url,
         file_name,
         mime_type,
         file_size,
         width,
         height,
         aspect_ratio,
         duration_ms,
         preprocess_tag,
         quality_mode,
         is_video_note,
         is_listen_once,
         created_at
       )
       VALUES (
         $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, now()
       )`,
      [
        uuidv4(),
        normalizedMessageId,
        type,
        Number(attachment.sort_order ?? index) || 0,
        attachment.media_group_id || null,
        storageUrl,
        attachment.file_name || null,
        attachment.mime_type || null,
        attachment.file_size == null ? null : Number(attachment.file_size),
        attachment.width == null ? null : Number(attachment.width),
        attachment.height == null ? null : Number(attachment.height),
        attachment.aspect_ratio == null
          ? null
          : Number(attachment.aspect_ratio),
        attachment.duration_ms == null ? null : Number(attachment.duration_ms),
        attachment.preprocess_tag || null,
        qualityResolution.qualityMode,
        attachment.is_video_note === true,
        attachment.is_listen_once === true,
      ],
    );
  }
}

async function maybeBindDirectRequestFirstMessage(chatId, messageId) {
  const normalizedChatId = String(chatId || "").trim();
  const normalizedMessageId = String(messageId || "").trim();
  if (!normalizedChatId || !normalizedMessageId) return;
  const updated = await db.query(
    `UPDATE direct_message_requests
     SET first_message_id = COALESCE(first_message_id, $2),
         updated_at = now()
     WHERE chat_id = $1
       AND status = 'pending'
       AND first_message_id IS NULL`,
    [normalizedChatId, normalizedMessageId],
  );
  if ((updated.rowCount || 0) > 0) {
    await db.query(
      `UPDATE chats
       SET settings = settings || $2::jsonb,
           updated_at = now()
       WHERE id = $1`,
      [
        normalizedChatId,
        JSON.stringify({
          direct_request_first_message_sent: true,
        }),
      ],
    );
  }
}

async function getHydratedMessageById(messageId, currentUserId) {
  const result = await db.query(
    `SELECT m.id,
            m.client_msg_id,
            m.chat_id,
            m.sender_id,
            m.text,
            m.meta,
            m.created_at,
            COALESCE((m.sender_id::text = $2::text), false) AS from_me,
            EXISTS(
              SELECT 1
              FROM message_reads mr
              WHERE mr.message_id = m.id
                AND mr.user_id = $2::uuid
            ) AS is_read_by_me,
            EXISTS(
              SELECT 1
              FROM message_reads mr
              WHERE mr.message_id = m.id
                AND mr.user_id <> m.sender_id
            ) AS read_by_others,
            (
              SELECT COUNT(*)
              FROM message_reads mr
              WHERE mr.message_id = m.id
                AND mr.user_id <> m.sender_id
            )::int AS read_count,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
            u.email AS sender_email,
            u.avatar_url AS sender_avatar_url,
            COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
            COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
            COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
     FROM messages m
     LEFT JOIN users u ON u.id = m.sender_id
     WHERE m.id = $1
     LIMIT 1`,
      [messageId, currentUserId ? String(currentUserId) : null],
  );
  const hydrated = decryptMessageRow(result.rows[0] || null);
  if (!hydrated) return null;
  const decorated = await attachReactionMapsToMessages([hydrated]);
  return decorated[0] || null;
}

async function attachReactionMapsToMessages(messages) {
  if (!Array.isArray(messages) || messages.length === 0) return messages;
  const ids = messages
    .map((message) => String(message?.id || "").trim())
    .filter(Boolean);
  if (ids.length === 0) return messages;
  const reactionsQ = await db.query(
    `SELECT message_id::text AS message_id,
            user_id::text AS user_id,
            emoji
     FROM message_reactions
     WHERE message_id = ANY($1::uuid[])`,
    [ids],
  );
  const byMessageId = new Map();
  for (const row of reactionsQ.rows) {
    const messageId = String(row.message_id || "").trim();
    const userId = String(row.user_id || "").trim();
    const emoji = normalizeReactionEmoji(row.emoji);
    if (!messageId || !userId || !emoji) continue;
    const current = byMessageId.get(messageId) || {};
    current[userId] = emoji;
    byMessageId.set(messageId, current);
  }
  const attachmentsByMessageId = await loadMessageAttachmentsByMessageIds(ids);
  return messages.map((message) => {
    const messageId = String(message?.id || "").trim();
    const meta = parseMeta(message?.meta);
    const reactionsByUser = byMessageId.get(messageId);
    const attachments =
      attachmentsByMessageId.get(messageId) || legacyAttachmentsFromMeta(meta);
    const nextMeta =
      !reactionsByUser || Object.keys(reactionsByUser).length === 0
        ? meta
        : {
            ...meta,
            reactions_by_user: reactionsByUser,
          };
    return {
      ...message,
      meta: nextMeta,
      attachments,
    };
  });
}

async function unhideChatInListForIncomingMessage(chatId, senderUserId = null) {
  const senderId = String(senderUserId || "").trim();
  if (senderId) {
    await db.query(
      `UPDATE user_chat_preferences
       SET hidden = false,
           updated_at = now()
       WHERE chat_id = $1
         AND hidden = true
         AND user_id <> $2`,
      [chatId, senderId],
    );
    return;
  }
  await db.query(
    `UPDATE user_chat_preferences
     SET hidden = false,
         updated_at = now()
     WHERE chat_id = $1
       AND hidden = true`,
    [chatId],
  );
}

async function finalizeCreatedMessage(req, chatId, messageId, currentUserId) {
  const responseMessageRaw = await getHydratedMessageById(
    messageId,
    currentUserId,
  );
  const responseMessage = decorateMessageMediaUrls(req, responseMessageRaw);
  if (!responseMessage) {
    throw new Error("Не удалось загрузить сообщение");
  }
  const broadcastMessageRaw = await getHydratedMessageById(messageId, null);
  const broadcastMessage = decorateMessageMediaUrls(req, broadcastMessageRaw);
  if (!broadcastMessage) {
    throw new Error("Не удалось подготовить событие сообщения");
  }

  await unhideChatInListForIncomingMessage(chatId, currentUserId || null);
  await db.query("UPDATE chats SET updated_at = now() WHERE id = $1", [chatId]);

  const io = req.app.get("io");
  if (io) {
    io.to(`chat:${chatId}`).emit("chat:message", {
      chatId,
      message: broadcastMessage,
    });
    emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
  }

  return responseMessage;
}

function normalizeSupportText(value) {
  return String(value || "").trim();
}

function isSupportCartSummaryQuestion(messageText) {
  const normalized = normalizeSupportText(messageText).toLowerCase();
  if (!normalized) return false;
  return normalized.includes("сум") && normalized.includes("корз");
}

async function computeSupportCartSummary(client, userId) {
  const rows = await client.query(
    `SELECT c.status, c.quantity, p.price
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     WHERE c.user_id = $1
       AND c.status IN ('pending_processing', 'processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')`,
    [userId],
  );
  const claimsRows = await client.query(
    `SELECT COALESCE(SUM(approved_amount), 0)::numeric AS claims_total
     FROM customer_claims
     WHERE user_id = $1
       AND status IN ('approved_return', 'approved_discount', 'settled')`,
    [userId],
  );

  let total = 0;
  let processed = 0;

  for (const row of rows.rows) {
    const quantity = Number(row.quantity || 0);
    const price = Number(row.price || 0);
    if (!Number.isFinite(quantity) || !Number.isFinite(price)) continue;
    const line = price * quantity;
    total += line;
    if (
      row.status === "processed" ||
      row.status === "preparing_delivery" ||
      row.status === "handing_to_courier" ||
      row.status === "in_delivery"
    ) {
      processed += line;
    }
  }

  const claimsTotal = Number(claimsRows.rows[0]?.claims_total || 0);
  const normalizedClaimsTotal = Number(claimsTotal.toFixed(2));
  const adjustedTotal = Math.max(0, Number((total - normalizedClaimsTotal).toFixed(2)));
  const adjustedProcessed = Math.max(
    0,
    Number((processed - normalizedClaimsTotal).toFixed(2)),
  );
  return {
    total: adjustedTotal,
    processed: adjustedProcessed,
    claims_total: normalizedClaimsTotal,
  };
}

async function syncSupportTicketOnMessage({
  chatId,
  senderId,
  senderRole,
  tenantId = null,
  supportTicketId = null,
  messageText = "",
}) {
  const ticketId = String(supportTicketId || "").trim();
  if (!ticketId) return { promptMessageId: null, autoReplyMessageId: null };

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    const ticketRes = await client.query(
      `SELECT id,
              chat_id,
              customer_id,
              assignee_id,
              assigned_role,
              category,
              subject,
              status
       FROM support_tickets
       WHERE id = $1
         AND chat_id = $2
         AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
       LIMIT 1
       FOR UPDATE`,
      [ticketId, chatId, tenantId || null],
    );

    if (ticketRes.rowCount === 0) {
      await client.query("ROLLBACK");
      return { promptMessageId: null, autoReplyMessageId: null };
    }

    const ticket = ticketRes.rows[0];
    const senderIdText = String(senderId || "").trim();
    const senderRoleNormalized = normalizeRole(senderRole);
    const senderIsCustomer = String(ticket.customer_id || "") === senderIdText;
    const senderIsAssignee =
      senderIdText.length > 0 &&
      String(ticket.assignee_id || "").trim() === senderIdText;
    let promptMessageId = null;
    let autoReplyMessageId = null;

    if (senderIsCustomer) {
      await client.query(
        `UPDATE support_tickets
         SET status = 'open',
             archived_at = NULL,
             archive_reason = NULL,
             resolved_at = NULL,
             resolved_by = NULL,
             last_customer_message_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [ticket.id],
      );

      const autoTemplateReply = await buildSupportTemplateAutoReply(client, {
        tenantId,
        category: ticket.category || "general",
        customerId: ticket.customer_id,
        subject: ticket.subject || "",
        messageText,
      });

      if (autoTemplateReply?.text) {
        const encryptedText = encryptMessageText(autoTemplateReply.text);
        const inserted = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, NULL, $3, $4::jsonb, now())
           RETURNING id`,
          [
            uuidv4(),
            chatId,
            encryptedText,
            JSON.stringify({
              kind: "support_bot_template_reply",
              support_ticket_id: ticket.id,
              support_category: ticket.category || "general",
              template_id: autoTemplateReply.template.id,
              template_title: autoTemplateReply.template.title,
              trigger_rule: autoTemplateReply.template.trigger_rule,
            }),
          ],
        );
        autoReplyMessageId = inserted.rows[0]?.id || null;
      } else if (isSupportCartSummaryQuestion(messageText)) {
        const sums = await computeSupportCartSummary(client, ticket.customer_id);
        const autoReplyText =
          `Общая сумма вашей корзины: ${sums.total} ₽. ` +
          `Обработано на сумму: ${sums.processed} ₽. ` +
          `Сумма брака: ${sums.claims_total} ₽.`;
        const autoReplyMeta = {
          kind: "support_bot_cart_summary",
          support_ticket_id: ticket.id,
          total_amount: sums.total,
          processed_amount: sums.processed,
          claims_total: sums.claims_total,
        };
        const encryptedText = encryptMessageText(autoReplyText);
        const inserted = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, NULL, $3, $4::jsonb, now())
           RETURNING id`,
          [uuidv4(), chatId, encryptedText, JSON.stringify(autoReplyMeta)],
        );
        autoReplyMessageId = inserted.rows[0]?.id || null;
      }
    } else if (isStaffRole(senderRoleNormalized)) {
      if (ticket.assignee_id && !senderIsAssignee) {
        await client.query("COMMIT");
        return { promptMessageId: null, autoReplyMessageId: null };
      }

      await client.query(
        `UPDATE support_tickets
         SET assignee_id = COALESCE(assignee_id, $1::uuid),
             assigned_role = CASE
               WHEN assignee_id IS NULL THEN $2
               ELSE assigned_role
             END,
             status = 'waiting_customer',
             archived_at = NULL,
             archive_reason = NULL,
             resolved_at = NULL,
             resolved_by = NULL,
             last_staff_message_at = now(),
             updated_at = now()
         WHERE id = $3`,
        [
          senderIdText || null,
          senderRoleNormalized || "admin",
          ticket.id,
        ],
      );
    }

    await client.query("COMMIT");
    return { promptMessageId, autoReplyMessageId };
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

async function insertMessageWithDedup({
  clientMsgId,
  chatId,
  senderId,
  text,
  metaJson = null,
}) {
  const encryptedText = encryptMessageText(text);
  const hasMeta = metaJson != null;
  const insertWithConflictSql = hasMeta
    ? `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, now())
       ON CONFLICT (client_msg_id) WHERE client_msg_id IS NOT NULL DO NOTHING
       RETURNING id`
    : `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, $4, $5, now())
       ON CONFLICT (client_msg_id) WHERE client_msg_id IS NOT NULL DO NOTHING
       RETURNING id`;
  const insertWithConflictParams = hasMeta
    ? [uuidv4(), clientMsgId, chatId, senderId, encryptedText, metaJson]
    : [uuidv4(), clientMsgId, chatId, senderId, encryptedText];

  const insertDirectSql = hasMeta
    ? `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, now())
       RETURNING id`
    : `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, $4, $5, now())
       RETURNING id`;
  const insertDirectParams = hasMeta
    ? [uuidv4(), clientMsgId, chatId, senderId, encryptedText, metaJson]
    : [uuidv4(), clientMsgId, chatId, senderId, encryptedText];

  if (!clientMsgId) {
    if (hasMeta) {
      return db.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, $3, $4, $5::jsonb, now())
         RETURNING id`,
        [uuidv4(), chatId, senderId, encryptedText, metaJson],
      );
    }
    return db.query(
      `INSERT INTO messages (id, chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, $4, now())
       RETURNING id`,
      [uuidv4(), chatId, senderId, encryptedText],
    );
  }

  try {
    const inserted = await db.query(insertWithConflictSql, insertWithConflictParams);
    if (inserted.rowCount > 0) return inserted;
  } catch (err) {
    if (String(err?.code || "") !== "42P10") throw err;
  }

  const existing = await db.query(
    `SELECT id
     FROM messages
     WHERE client_msg_id = $1
     LIMIT 1`,
    [clientMsgId],
  );
  if (existing.rowCount > 0) return existing;

  return db.query(insertDirectSql, insertDirectParams);
}

function parseCursorTimestamp(raw) {
  const value = String(raw || "").trim();
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString();
}

function parseCursorLimit(raw, fallback = 40) {
  const value = Number(raw);
  if (!Number.isFinite(value)) return fallback;
  return Math.max(1, Math.min(Math.trunc(value), 100));
}

function trimOptionalUuid(raw) {
  const value = String(raw || "").trim();
  if (!value) return null;
  return uuidValidate(value) ? value : null;
}

function trimOptionalText(raw, maxLength = 4000) {
  const value = String(raw || "");
  return value.length > maxLength ? value.slice(0, maxLength) : value;
}

function parseOptionalNumber(raw) {
  if (raw === null || raw === undefined || raw === "") return null;
  const value = Number(raw);
  if (!Number.isFinite(value)) return null;
  return value;
}

async function getUserChatState(userId, chatId) {
  const stateQ = await db.query(
    `SELECT user_id,
            chat_id,
            last_read_message_id,
            last_seen_message_id,
            draft_text,
            draft_updated_at,
            scroll_anchor_message_id,
            scroll_anchor_offset,
            created_at,
            updated_at
     FROM user_chat_state
     WHERE user_id = $1
       AND chat_id = $2
     LIMIT 1`,
    [userId, chatId],
  );
  return stateQ.rowCount > 0 ? stateQ.rows[0] : null;
}

async function upsertUserChatState(userId, chatId, patch = {}) {
  const columns = [];
  const values = [];
  const updates = [];
  let index = 3;

  const assign = (column, value) => {
    columns.push(column);
    values.push(value);
    updates.push(`${column} = EXCLUDED.${column}`);
    index += 1;
    return `$${index - 1}`;
  };

  if (Object.prototype.hasOwnProperty.call(patch, "last_read_message_id")) {
    const normalized = normalizeUuidPatchField(patch.last_read_message_id);
    if (normalized.accepted) {
      assign("last_read_message_id", normalized.value);
    }
  }
  if (Object.prototype.hasOwnProperty.call(patch, "last_seen_message_id")) {
    const normalized = normalizeUuidPatchField(patch.last_seen_message_id);
    if (normalized.accepted) {
      assign("last_seen_message_id", normalized.value);
    }
  }
  if (Object.prototype.hasOwnProperty.call(patch, "draft_text")) {
    assign("draft_text", trimOptionalText(patch.draft_text || "", 8000));
  }
  if (Object.prototype.hasOwnProperty.call(patch, "draft_updated_at")) {
    assign("draft_updated_at", patch.draft_updated_at || null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "scroll_anchor_message_id")) {
    const normalized = normalizeUuidPatchField(patch.scroll_anchor_message_id);
    if (normalized.accepted) {
      assign("scroll_anchor_message_id", normalized.value);
    }
  }
  if (Object.prototype.hasOwnProperty.call(patch, "scroll_anchor_offset")) {
    assign("scroll_anchor_offset", parseOptionalNumber(patch.scroll_anchor_offset));
  }

  if (columns.length === 0) {
    return getUserChatState(userId, chatId);
  }

  const insertColumns = ["user_id", "chat_id", ...columns, "created_at", "updated_at"];
  const insertValues = ["$1", "$2", ...columns.map((_, i) => `$${i + 3}`), "now()", "now()"];
  const result = await db.query(
    `INSERT INTO user_chat_state (${insertColumns.join(", ")})
     VALUES (${insertValues.join(", ")})
     ON CONFLICT (user_id, chat_id)
     DO UPDATE
       SET ${updates.join(", ")},
           updated_at = now()
     RETURNING user_id,
               chat_id,
               last_read_message_id,
               last_seen_message_id,
               draft_text,
               draft_updated_at,
               scroll_anchor_message_id,
               scroll_anchor_offset,
               created_at,
               updated_at`,
    [userId, chatId, ...values],
  );
  return result.rows[0] || null;
}

async function getVisibleMessageAnchor(chatId, userId, messageId) {
  const trimmedMessageId = String(messageId || "").trim();
  if (!trimmedMessageId) return null;
  const anchorQ = await db.query(
    `SELECT m.id,
            m.created_at
     FROM messages m
     WHERE m.chat_id = $1
       AND m.id = $2
       AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
     LIMIT 1`,
    [chatId, trimmedMessageId, String(userId || "")],
  );
  return anchorQ.rowCount > 0 ? anchorQ.rows[0] : null;
}

async function markChatMessagesRead(chatId, userId, visibleUntilMessageId = null) {
  const visibleAnchor = visibleUntilMessageId
    ? await getVisibleMessageAnchor(chatId, userId, visibleUntilMessageId)
    : null;

  const result = await db.query(
    `WITH unread AS (
       SELECT m.id, m.sender_id
       FROM messages m
     WHERE m.chat_id = $1
       AND (
         (m.sender_id IS NOT NULL AND m.sender_id <> $2)
         OR COALESCE(m.meta->>'kind', '') = 'reserved_order_item'
       )
       AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       AND NOT EXISTS (
         SELECT 1
         FROM message_reads mr
           WHERE mr.message_id = m.id
             AND mr.user_id = $2
       )
       AND (
         $3::uuid IS NULL
         OR m.created_at < $4::timestamptz
         OR (m.created_at = $4::timestamptz AND m.id <= $3::uuid)
       )
     ),
     inserted AS (
       INSERT INTO message_reads (message_id, user_id, chat_id, read_at)
       SELECT unread.id, $2, $1, now()
       FROM unread
       ON CONFLICT (message_id, user_id) DO NOTHING
       RETURNING message_id
     )
     SELECT unread.id::text AS message_id,
            unread.sender_id::text AS sender_id
     FROM inserted i
     JOIN unread ON unread.id = i.message_id`,
    [
      chatId,
      userId,
      visibleAnchor?.id || null,
      visibleAnchor?.created_at || null,
    ],
  );
  const lastReadMessageId =
    visibleAnchor?.id ||
    result.rows[result.rows.length - 1]?.message_id ||
    null;
  if (lastReadMessageId) {
    await upsertUserChatState(userId, chatId, {
      last_read_message_id: lastReadMessageId,
      last_seen_message_id: lastReadMessageId,
    });
  }
  return result.rows;
}

async function canPinInChat(user) {
  if (!user) return false;
  const role = normalizeRole(user.base_role || user.role);
  if (role === "creator" || role === "admin") return true;

  const resolved = await resolvePermissionSet(user, db);
  return hasPermission(resolved.permissions, "chat.pin");
}

async function getActivePinForUser(req, chatId, userId) {
  const pinQ = await db.query(
    `SELECT cp.id,
            cp.chat_id,
            cp.message_id,
            cp.pinned_by,
            cp.created_at,
            cp.updated_at,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS pinned_by_name
     FROM chat_pins cp
     JOIN messages m ON m.id = cp.message_id
     LEFT JOIN users u ON u.id = cp.pinned_by
     WHERE cp.chat_id = $1
       AND cp.is_active = true
       AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
     ORDER BY cp.updated_at DESC
     LIMIT 1`,
    [chatId, String(userId || "")],
  );
  if (pinQ.rowCount === 0) return null;
  const pin = pinQ.rows[0];
  const message = decorateMessageMediaUrls(
    req,
    await getHydratedMessageById(pin.message_id, userId),
  );
  if (!message) return null;
  return {
    id: pin.id,
    chat_id: pin.chat_id,
    message_id: pin.message_id,
    pinned_by: pin.pinned_by,
    pinned_by_name: pin.pinned_by_name,
    created_at: pin.created_at,
    updated_at: pin.updated_at,
    message,
  };
}

async function getFirstUnreadMessageId(chatId, userId) {
  const result = await db.query(
    `SELECT m.id::text AS id
     FROM messages m
     WHERE m.chat_id = $1
       AND (
         (m.sender_id IS NOT NULL AND m.sender_id <> $2)
         OR COALESCE(m.meta->>'kind', '') = 'reserved_order_item'
       )
       AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       AND NOT EXISTS (
         SELECT 1
         FROM message_reads mr
         WHERE mr.message_id = m.id
           AND mr.user_id = $2
       )
     ORDER BY m.created_at ASC, m.id ASC
     LIMIT 1`,
    [chatId, String(userId || "")],
  );
  return result.rows[0]?.id || null;
}

async function getChatUnreadCount(chatId, userId) {
  const result = await db.query(
    `SELECT COUNT(*)::int AS unread_count
     FROM messages m
     WHERE m.chat_id = $1
       AND (
         (m.sender_id IS NOT NULL AND m.sender_id <> $2)
         OR COALESCE(m.meta->>'kind', '') = 'reserved_order_item'
       )
       AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       AND NOT EXISTS (
         SELECT 1
         FROM message_reads mr
         WHERE mr.message_id = m.id
           AND mr.user_id = $2
       )`,
    [chatId, String(userId || "")],
  );
  return Number(result.rows[0]?.unread_count || 0);
}

async function loadPagedMessages(req, {
  chatId,
  userId,
  beforeCreatedAt = null,
  beforeId = null,
  afterCreatedAt = null,
  afterId = null,
  limit = 40,
}) {
  const safeLimit = parseCursorLimit(limit, 40);
  const userIdText = String(userId || "");
  const beforeTs = parseCursorTimestamp(beforeCreatedAt);
  const afterTs = parseCursorTimestamp(afterCreatedAt);
  const safeBeforeId = trimOptionalUuid(beforeId);
  const safeAfterId = trimOptionalUuid(afterId);

  let mode = "latest";
  let rowsQ;

  if (afterTs && safeAfterId) {
    mode = "after";
    rowsQ = await db.query(
      `SELECT m.id,
              m.sender_id,
              m.client_msg_id,
              m.text,
              m.meta,
              m.created_at,
              (m.sender_id::text = $3::text) AS from_me,
              EXISTS(
                SELECT 1 FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id = $3::uuid
              ) AS is_read_by_me,
              EXISTS(
                SELECT 1 FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              ) AS read_by_others,
              (
                SELECT COUNT(*)
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              )::int AS read_count,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
              u.email AS sender_email,
              u.avatar_url AS sender_avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
       FROM messages m
       LEFT JOIN users u ON u.id = m.sender_id
       WHERE m.chat_id = $1
         AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         AND (
           m.created_at > $4::timestamptz
           OR (m.created_at = $4::timestamptz AND m.id > $5::uuid)
         )
       ORDER BY m.created_at ASC, m.id ASC
       LIMIT $2`,
      [chatId, safeLimit + 1, userIdText, afterTs, safeAfterId],
    );
  } else if (beforeTs && safeBeforeId) {
    mode = "before";
    rowsQ = await db.query(
      `SELECT m.id,
              m.sender_id,
              m.client_msg_id,
              m.text,
              m.meta,
              m.created_at,
              (m.sender_id::text = $3::text) AS from_me,
              EXISTS(
                SELECT 1 FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id = $3::uuid
              ) AS is_read_by_me,
              EXISTS(
                SELECT 1 FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              ) AS read_by_others,
              (
                SELECT COUNT(*)
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              )::int AS read_count,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
              u.email AS sender_email,
              u.avatar_url AS sender_avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
       FROM messages m
       LEFT JOIN users u ON u.id = m.sender_id
       WHERE m.chat_id = $1
         AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         AND (
           m.created_at < $4::timestamptz
           OR (m.created_at = $4::timestamptz AND m.id < $5::uuid)
         )
       ORDER BY m.created_at DESC, m.id DESC
       LIMIT $2`,
      [chatId, safeLimit + 1, userIdText, beforeTs, safeBeforeId],
    );
  } else {
    rowsQ = await db.query(
      `SELECT m.id,
              m.sender_id,
              m.client_msg_id,
              m.text,
              m.meta,
              m.created_at,
              (m.sender_id::text = $3::text) AS from_me,
              EXISTS(
                SELECT 1 FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id = $3::uuid
              ) AS is_read_by_me,
              EXISTS(
                SELECT 1 FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              ) AS read_by_others,
              (
                SELECT COUNT(*)
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              )::int AS read_count,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
              u.email AS sender_email,
              u.avatar_url AS sender_avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
       FROM messages m
       LEFT JOIN users u ON u.id = m.sender_id
       WHERE m.chat_id = $1
         AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       ORDER BY m.created_at DESC, m.id DESC
       LIMIT $2`,
      [chatId, safeLimit + 1, userIdText],
    );
  }

  let rows = rowsQ.rows || [];
  let hasMore = rows.length > safeLimit;
  if (hasMore) {
    rows = rows.slice(0, safeLimit);
  }
  if (mode !== "after") {
    rows = rows.reverse();
  }
  const decoratedRows = await attachReactionMapsToMessages(
    rows.map((row) => decryptMessageRow(row)),
  );
  return {
    data: decoratedRows.map((row) => decorateMessageMediaUrls(req, row)),
    has_more_before: mode === "before" ? hasMore : mode === "latest" ? hasMore : false,
    has_more_after: mode === "after" ? hasMore : false,
    mode,
  };
}

async function listChatsHandler(req, res) {
  try {
    const userId = req.user.id;
    const tenantId = req.user.tenant_id || null;
    const userIdText = String(userId);
    const role = normalizeRole(req.user.role);
    const workerOrHigher =
      role === "worker" || role === "admin" || role === "tenant" || role === "creator";
    const adminOrCreator =
      role === "admin" || role === "tenant" || role === "creator";
    const bugReportViewer = canAccessBugReportsChannel(req.user.role);

    await ensureSavedMessagesChat(db.pool, req.user);

    const publicAndChannelQ = await db.query(
      `SELECT c.id,
              c.title,
              c.type,
              c.settings,
              CASE
                WHEN c.type = 'private'
                  THEN COALESCE(
                    NULLIF(BTRIM(peer.peer_display_name), ''),
                    NULLIF(BTRIM(c.title), ''),
                    'Пользователь'
                  )
                ELSE COALESCE(NULLIF(BTRIM(c.title), ''), 'Чат')
              END AS display_title,
              peer.peer_user_id,
              peer.peer_display_name,
              peer.peer_name,
              peer.peer_phone,
              peer.peer_avatar_url,
              peer.peer_avatar_focus_x,
              peer.peer_avatar_focus_y,
              peer.peer_avatar_zoom,
              COALESCE(pref.pinned, false) AS is_pinned,
              pref.pinned_at,
              last_msg.text AS last_message,
              last_msg.created_at AS updated_at,
              COALESCE(unread_stats.unread_count, 0)::int AS unread_count,
              st.status AS support_ticket_status,
              COALESCE(NULLIF(BTRIM(support_assignee.name), ''), NULLIF(BTRIM(support_assignee.email), ''), '') AS support_assignee_name,
              last_msg.sender_id AS last_message_sender_id,
              COALESCE(NULLIF(BTRIM(last_user.name), ''), NULLIF(BTRIM(last_user.email), ''), 'Система') AS last_message_sender_name,
              last_user.avatar_url AS last_message_sender_avatar_url,
              COALESCE(last_user.avatar_focus_x, 0) AS last_message_sender_avatar_focus_x,
              COALESCE(last_user.avatar_focus_y, 0) AS last_message_sender_avatar_focus_y,
              COALESCE(last_user.avatar_zoom, 1) AS last_message_sender_avatar_zoom
       FROM chats c
       LEFT JOIN support_tickets st
         ON st.chat_id = c.id
       LEFT JOIN users support_assignee
         ON support_assignee.id = st.assignee_id
       LEFT JOIN user_chat_preferences pref
         ON pref.chat_id = c.id
        AND pref.user_id = $1
       LEFT JOIN LATERAL (
         SELECT ou.id AS peer_user_id,
                COALESCE(
                  NULLIF(BTRIM(uc.alias_name), ''),
                  NULLIF(BTRIM(ou.name), ''),
                  NULLIF(BTRIM(op.phone), '')
                ) AS peer_display_name,
                ou.name AS peer_name,
                op.phone AS peer_phone,
                ou.avatar_url AS peer_avatar_url,
                COALESCE(ou.avatar_focus_x, 0) AS peer_avatar_focus_x,
                COALESCE(ou.avatar_focus_y, 0) AS peer_avatar_focus_y,
                COALESCE(ou.avatar_zoom, 1) AS peer_avatar_zoom
         FROM chat_members ocm
         JOIN users ou ON ou.id = ocm.user_id
         LEFT JOIN phones op ON op.user_id = ou.id
         LEFT JOIN user_contacts uc
           ON uc.user_id = $1
          AND uc.contact_user_id = ou.id
          AND ($6::uuid IS NULL OR uc.tenant_id = $6::uuid)
         WHERE ocm.chat_id = c.id
           AND c.type = 'private'
           AND ocm.user_id <> $1
         ORDER BY ocm.joined_at ASC
         LIMIT 1
       ) AS peer ON true
       LEFT JOIN LATERAL (
         SELECT m.text, m.created_at, m.sender_id
         FROM messages m
         WHERE m.chat_id = c.id
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $4::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT 1
       ) AS last_msg ON true
       LEFT JOIN LATERAL (
         SELECT COUNT(*) AS unread_count
         FROM messages um
         WHERE um.chat_id = c.id
           AND (
             (um.sender_id IS NOT NULL AND um.sender_id <> $1)
             OR COALESCE(um.meta->>'kind', '') = 'reserved_order_item'
           )
           AND NOT (COALESCE(um.meta->'hidden_for', '[]'::jsonb) ? $4::text)
           AND COALESCE((um.meta->>'hidden_for_all')::boolean, false) = false
           AND NOT EXISTS (
             SELECT 1
             FROM message_reads mr
             WHERE mr.message_id = um.id
               AND mr.user_id = $1
           )
       ) AS unread_stats ON true
       LEFT JOIN users last_user ON last_user.id = last_msg.sender_id
       WHERE (
         (
           c.type <> 'channel'
           AND NOT EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = c.id)
         )
         OR
         (
           c.type = 'channel'
           AND (
             (
               (
                 COALESCE((c.settings->>'admin_only')::boolean, false) = true
                 OR COALESCE(c.settings->>'kind', '') = 'bug_reports'
                 OR LOWER(TRIM(c.title)) = 'баг-репорты'
               )
               AND $7::boolean = true
             )
             OR
             (
               COALESCE((c.settings->>'admin_only')::boolean, false) = false
               AND COALESCE(c.settings->>'kind', '') <> 'bug_reports'
               AND LOWER(TRIM(c.title)) <> 'баг-репорты'
               AND (
                 $2::boolean = true
                 OR (
                   COALESCE(c.settings->>'kind', '') <> 'reserved_orders'
                   AND COALESCE(c.settings->>'system_key', '') <> 'reserved_orders'
                   AND LOWER(TRIM(c.title)) <> 'забронированный товар'
                 )
               )
               AND (
                 COALESCE(c.settings->>'visibility', 'public') = 'public'
                 OR EXISTS (
                   SELECT 1 FROM chat_members cm
                   WHERE cm.chat_id = c.id AND cm.user_id = $1
                 )
                 OR $2::boolean = true
               )
               AND (
                 $3::boolean = true
                 OR NOT (
                   COALESCE(c.settings->'blacklisted_user_ids', '[]'::jsonb) ? $5::text
                 )
               )
             )
           )
         )
       )
       AND ($6::uuid IS NULL OR c.tenant_id = $6::uuid)
       AND (
         c.type <> 'channel'
         OR COALESCE((c.settings->>'hidden_in_chat_list')::boolean, false) = false
       )
       AND COALESCE(c.settings->>'kind', '') <> 'system_duplicate'
       AND COALESCE(pref.hidden, false) = false
       ORDER BY
         COALESCE(pref.pinned, false) DESC,
         pref.pinned_at DESC NULLS LAST,
         updated_at DESC NULLS LAST
       LIMIT 200`,
      [
        userId,
        workerOrHigher,
        adminOrCreator,
        userIdText,
        userIdText,
        tenantId,
        bugReportViewer,
      ],
    );

    const privateQ = await db.query(
      `SELECT c.id,
              c.title,
              c.type,
              c.settings,
              CASE
                WHEN c.type = 'private'
                  THEN COALESCE(
                    NULLIF(BTRIM(peer.peer_display_name), ''),
                    NULLIF(BTRIM(c.title), ''),
                    'Пользователь'
                  )
                ELSE COALESCE(NULLIF(BTRIM(c.title), ''), 'Чат')
              END AS display_title,
              peer.peer_user_id,
              peer.peer_display_name,
              peer.peer_name,
              peer.peer_phone,
              peer.peer_avatar_url,
              peer.peer_avatar_focus_x,
              peer.peer_avatar_focus_y,
              peer.peer_avatar_zoom,
              COALESCE(pref.pinned, false) AS is_pinned,
              pref.pinned_at,
              last_msg.text AS last_message,
              last_msg.created_at AS updated_at,
              COALESCE(unread_stats.unread_count, 0)::int AS unread_count,
              last_msg.sender_id AS last_message_sender_id,
              COALESCE(NULLIF(BTRIM(last_user.name), ''), NULLIF(BTRIM(last_user.email), ''), 'Система') AS last_message_sender_name,
              last_user.avatar_url AS last_message_sender_avatar_url,
              COALESCE(last_user.avatar_focus_x, 0) AS last_message_sender_avatar_focus_x,
              COALESCE(last_user.avatar_focus_y, 0) AS last_message_sender_avatar_focus_y,
              COALESCE(last_user.avatar_zoom, 1) AS last_message_sender_avatar_zoom
       FROM chats c
       LEFT JOIN chat_members cm
         ON cm.chat_id = c.id
        AND cm.user_id = $1
       LEFT JOIN support_tickets st
         ON st.chat_id = c.id
       LEFT JOIN users support_assignee
         ON support_assignee.id = st.assignee_id
       LEFT JOIN user_chat_preferences pref
         ON pref.chat_id = c.id
        AND pref.user_id = $1
       LEFT JOIN LATERAL (
         SELECT ou.id AS peer_user_id,
                COALESCE(
                  NULLIF(BTRIM(uc.alias_name), ''),
                  NULLIF(BTRIM(ou.name), ''),
                  NULLIF(BTRIM(op.phone), '')
                ) AS peer_display_name,
                ou.name AS peer_name,
                op.phone AS peer_phone,
                ou.avatar_url AS peer_avatar_url,
                COALESCE(ou.avatar_focus_x, 0) AS peer_avatar_focus_x,
                COALESCE(ou.avatar_focus_y, 0) AS peer_avatar_focus_y,
                COALESCE(ou.avatar_zoom, 1) AS peer_avatar_zoom
         FROM chat_members ocm
         JOIN users ou ON ou.id = ocm.user_id
         LEFT JOIN phones op ON op.user_id = ou.id
         LEFT JOIN user_contacts uc
           ON uc.user_id = $1
          AND uc.contact_user_id = ou.id
          AND ($3::uuid IS NULL OR uc.tenant_id = $3::uuid)
         WHERE ocm.chat_id = c.id
           AND c.type = 'private'
           AND ocm.user_id <> $1
         ORDER BY ocm.joined_at ASC
         LIMIT 1
       ) AS peer ON true
       LEFT JOIN LATERAL (
         SELECT m.text, m.created_at, m.sender_id
         FROM messages m
         WHERE m.chat_id = c.id
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT 1
       ) AS last_msg ON true
       LEFT JOIN LATERAL (
         SELECT COUNT(*) AS unread_count
         FROM messages um
         WHERE um.chat_id = c.id
           AND (
             (um.sender_id IS NOT NULL AND um.sender_id <> $1)
             OR COALESCE(um.meta->>'kind', '') = 'reserved_order_item'
           )
           AND NOT (COALESCE(um.meta->'hidden_for', '[]'::jsonb) ? $2::text)
           AND COALESCE((um.meta->>'hidden_for_all')::boolean, false) = false
           AND NOT EXISTS (
             SELECT 1
             FROM message_reads mr
             WHERE mr.message_id = um.id
               AND mr.user_id = $1
           )
       ) AS unread_stats ON true
       LEFT JOIN users last_user ON last_user.id = last_msg.sender_id
       WHERE c.type <> 'channel'
         AND (
           (
             (
               COALESCE(c.settings->>'kind', '') = 'support_ticket'
               OR COALESCE((c.settings->>'support_ticket')::boolean, false) = true
             )
             AND (
               st.customer_id = $1
               OR st.assignee_id = $1
             )
             AND (
               COALESCE(st.status, 'open') <> 'archived'
               OR st.archived_at IS NULL
               OR st.archived_at > now() - interval '5 seconds'
             )
           )
           OR (
             COALESCE(c.settings->>'kind', '') <> 'support_ticket'
             AND COALESCE((c.settings->>'support_ticket')::boolean, false) = false
             AND cm.user_id = $1
           )
         )
         AND ($3::uuid IS NULL OR c.tenant_id = $3::uuid)
         AND COALESCE(pref.hidden, false) = false
       ORDER BY
         COALESCE(pref.pinned, false) DESC,
         pref.pinned_at DESC NULLS LAST,
         updated_at DESC NULLS LAST
       LIMIT 100`,
      [userId, userIdText, tenantId],
    );

    const byId = new Map();
    for (const row of [...publicAndChannelQ.rows, ...privateQ.rows]) {
      if (!byId.has(row.id)) byId.set(row.id, row);
    }
    const chats = Array.from(byId.values());
    for (const chat of chats) {
      const settings = normalizeSettings(chat.settings);
      const supportStatus = String(chat.support_ticket_status || "").trim();
      const supportAssigneeName = String(chat.support_assignee_name || "").trim();
      if (supportStatus) {
        settings.support_ticket = true;
        settings.support_ticket_status = supportStatus;
        settings.support_waiting_customer = supportStatus === "waiting_customer";
        if (supportAssigneeName) {
          settings.support_assignee_name = supportAssigneeName;
        }
      }
      chat.settings = settings;
      chat.last_message = decryptMessageText(chat.last_message);
    }

    return res.json({ ok: true, data: chats });
  } catch (err) {
    console.error("chats.list error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
}

router.get("/list", requireAuth, listChatsHandler);
router.get("/", requireAuth, listChatsHandler);

/**
 * POST /api/chats
 * Создать чат — только creator/admin
 * body: { title, type?: 'public'|'private', members?: [userId,...] }
 */
router.post(
  "/",
  requireAuth,
  requireRole("creator", "admin"),
  async (req, res) => {
    try {
      const { title, type = "public", members = [] } = req.body || {};
      if (!title || typeof title !== "string") {
        return res.status(400).json({ ok: false, error: "title required" });
      }
      const safeType = type === "private" ? "private" : "public";
      const insert = await db.query(
        `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, now(), now())
       RETURNING id, title, type, created_by, settings`,
        [
          uuidv4(),
          title,
          safeType,
          req.user.id,
          req.user.tenant_id,
          JSON.stringify({ kind: "chat" }),
        ],
      );
      const chat = insert.rows[0];

      if (safeType === "private") {
        const creatorId = req.user.id;
        const membersArr = Array.isArray(members) ? members : [];
        const toAddRaw = Array.from(new Set([creatorId, ...membersArr]));
        const allowedMembersQ = await db.query(
          `SELECT id::text AS id
           FROM users
           WHERE id::text = ANY($1::text[])
             AND ($2::uuid IS NULL OR tenant_id = $2::uuid)`,
          [toAddRaw, req.user.tenant_id || null],
        );
        const toAdd = allowedMembersQ.rows.map((row) => String(row.id || "").trim()).filter(Boolean);
        await Promise.all(
          toAdd.map((uid) =>
            db.query(
              `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
           VALUES ($1, $2, $3, now(), $4)
           ON CONFLICT (chat_id, user_id) DO NOTHING`,
              [uuidv4(), chat.id, uid, uid === creatorId ? "owner" : "member"],
            ),
          ),
        );
      }

      const io = req.app.get("io");
      if (safeType === "public" && io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:created", { chat });
      }

      return res.status(201).json({ ok: true, data: chat });
    } catch (err) {
      console.error("chats.create error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.get("/:chatId/state", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const [state, firstUnreadMessageId, unreadCount] = await Promise.all([
      getUserChatState(userId, chatId),
      getFirstUnreadMessageId(chatId, userId),
      getChatUnreadCount(chatId, userId),
    ]);

    return res.json({
      ok: true,
      data: {
        chat_id: chatId,
        last_read_message_id: state?.last_read_message_id || null,
        last_seen_message_id: state?.last_seen_message_id || null,
        draft_text: state?.draft_text || "",
        draft_updated_at: state?.draft_updated_at || null,
        scroll_anchor_message_id: state?.scroll_anchor_message_id || null,
        scroll_anchor_offset: state?.scroll_anchor_offset ?? null,
        first_unread_message_id: firstUnreadMessageId,
        unread_count: unreadCount,
        updated_at: state?.updated_at || null,
      },
    });
  } catch (err) {
    console.error("chats.state.get error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.patch("/:chatId/state", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const patch = {};
    if (Object.prototype.hasOwnProperty.call(req.body || {}, "last_read_message_id")) {
      patch.last_read_message_id = req.body.last_read_message_id;
    }
    if (Object.prototype.hasOwnProperty.call(req.body || {}, "last_seen_message_id")) {
      patch.last_seen_message_id = req.body.last_seen_message_id;
    }
    if (Object.prototype.hasOwnProperty.call(req.body || {}, "draft_text")) {
      patch.draft_text = req.body.draft_text;
      patch.draft_updated_at = new Date().toISOString();
    }
    if (Object.prototype.hasOwnProperty.call(req.body || {}, "scroll_anchor_message_id")) {
      patch.scroll_anchor_message_id = req.body.scroll_anchor_message_id;
    }
    if (Object.prototype.hasOwnProperty.call(req.body || {}, "scroll_anchor_offset")) {
      patch.scroll_anchor_offset = req.body.scroll_anchor_offset;
    }

    const sanitized = sanitizeChatStatePatch(patch);
    const sanitizedPatch = sanitized.patch;
    if (Object.keys(sanitizedPatch).length === 0) {
      const state = await getUserChatState(userId, chatId);
      return res.json({
        ok: true,
        data: state,
        meta: {
          reason_code: "empty_state_patch",
          dropped_fields: sanitized.dropped,
        },
      });
    }
    const state = await upsertUserChatState(userId, chatId, sanitizedPatch);
    return res.json({ ok: true, data: state });
  } catch (err) {
    console.error("chats.state.patch error", err);
    return res.status(500).json({
      ok: false,
      error: "Server error",
      error_code: "chat_state_patch_failed",
    });
  }
});

/**
 * GET /api/chats/:chatId/messages
 */
router.get("/:chatId/messages", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const page = await loadPagedMessages(req, {
      chatId,
      userId,
      beforeCreatedAt: req.query.before_created_at,
      beforeId: req.query.before_id,
      afterCreatedAt: req.query.after_created_at,
      afterId: req.query.after_id,
      limit: req.query.limit,
    });
    const [state, firstUnreadMessageId, unreadCount] = await Promise.all([
      getUserChatState(userId, chatId),
      getFirstUnreadMessageId(chatId, userId),
      getChatUnreadCount(chatId, userId),
    ]);
    return res.json({
      ok: true,
      data: page.data,
      paging: {
        mode: page.mode,
        has_more_before: page.has_more_before,
        has_more_after: page.has_more_after,
      },
      state: {
        last_read_message_id: state?.last_read_message_id || null,
        last_seen_message_id: state?.last_seen_message_id || null,
        first_unread_message_id: firstUnreadMessageId,
        unread_count: unreadCount,
      },
    });
  } catch (err) {
    console.error("chats.messages error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/media/:kind/:filename", async (req, res) => {
  try {
    const kind = String(req.params.kind || "").trim().toLowerCase();
    if (kind !== "image" && kind !== "voice" && kind !== "video") {
      return res.status(404).json({ ok: false, error: "Media not found" });
    }

    const rawFilename = decodeURIComponent(String(req.params.filename || ""));
    const filename = path.basename(rawFilename);
    if (
      !filename ||
      filename !== rawFilename ||
      !/^[A-Za-z0-9._-]+$/.test(filename)
    ) {
      return res.status(400).json({ ok: false, error: "Invalid media name" });
    }

    const exp = Number(req.query.exp || 0);
    const sig = String(req.query.sig || "").trim().toLowerCase();
    const requestedKeyVersion = normalizeKeyVersion(
      req.query.kid || req.query.kv || "",
      "",
    );
    if (!Number.isFinite(exp) || exp <= 0 || !sig) {
      return res.status(403).json({ ok: false, error: "Missing media token" });
    }
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (exp < nowSeconds) {
      return res.status(403).json({ ok: false, error: "Media token expired" });
    }
    if (exp > nowSeconds + 24 * 60 * 60) {
      return res.status(403).json({ ok: false, error: "Media token is invalid" });
    }

    const marker = CHAT_MEDIA_MARKERS[kind];
    const canonicalPath = `${marker}${filename}`;
    const candidates = resolveSecretCandidates(
      CHAT_MEDIA_KEYRING,
      requestedKeyVersion,
    );
    let tokenValid = false;
    for (const candidate of candidates) {
      const expectedSig = signChatMediaAccess(
        canonicalPath,
        exp,
        candidate.secret,
      );
      if (!secureEqualHex(sig, expectedSig)) continue;
      tokenValid = true;
      break;
    }
    if (!tokenValid) {
      return res.status(403).json({ ok: false, error: "Invalid media token" });
    }

    const mediaField = kind === "image"
      ? "image_url"
      : kind === "voice"
      ? "voice_url"
      : "video_url";
    const refQ = await db.query(
      `SELECT 1
       FROM messages m
       WHERE COALESCE(m.meta->>$1, '') LIKE $2
       LIMIT 1`,
      [mediaField, `%${canonicalPath}%`],
    );
    if (refQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Media reference not found" });
    }

    const baseDir = kind === "image"
      ? chatImageUploadsDir
      : kind === "voice"
      ? chatVoiceUploadsDir
      : chatVideoUploadsDir;
    const absoluteBaseDir = path.resolve(baseDir);
    const absoluteFilePath = path.resolve(baseDir, filename);
    if (
      absoluteFilePath !== absoluteBaseDir &&
      !absoluteFilePath.startsWith(`${absoluteBaseDir}${path.sep}`)
    ) {
      return res.status(400).json({ ok: false, error: "Invalid media path" });
    }
    if (!fs.existsSync(absoluteFilePath)) {
      return res.status(404).json({ ok: false, error: "Media file not found" });
    }

    res.setHeader("Cache-Control", "private, max-age=60");
    res.setHeader("X-Content-Type-Options", "nosniff");
    return res.sendFile(absoluteFilePath);
  } catch (err) {
    console.error("chats.media error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/:chatId/messages/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const messageQ = await db.query(
      `SELECT m.id,
              m.sender_id,
              m.client_msg_id,
              m.text,
              m.meta,
              m.created_at,
              (m.sender_id::text = $3::text) AS from_me,
              EXISTS(
                SELECT 1
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id = $3::uuid
              ) AS is_read_by_me,
              EXISTS(
                SELECT 1
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              ) AS read_by_others,
              (
                SELECT COUNT(*)
                FROM message_reads mr
                WHERE mr.message_id = m.id
                  AND mr.user_id <> m.sender_id
              )::int AS read_count,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
              u.email AS sender_email,
              u.avatar_url AS sender_avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
       FROM messages m
       LEFT JOIN users u ON u.id = m.sender_id
       WHERE m.chat_id = $1
         AND m.id = $2
         AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       LIMIT 1`,
      [chatId, messageId, String(userId)],
    );

    if (messageQ.rowCount === 0) {
      return res.status(404).json({
        ok: false,
        error: "Сообщение не найдено",
      });
    }

    const safeMessage = decorateMessageMediaUrls(
      req,
      await getHydratedMessageById(messageQ.rows[0].id, userId),
    );
    return res.json({ ok: true, data: safeMessage });
  } catch (err) {
    console.error("chats.messageById error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/:chatId/search", requireAuth, async (req, res, next) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;
    if (chatId === "direct") {
      return next();
    }
    const query = String(req.query.q || "").trim();
    const safeLimit = parseCursorLimit(req.query.limit, 30);

    if (!query) {
      return res.status(400).json({ ok: false, error: "q required" });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const isReserved = isReservedOrdersChannel(context.chat, context.settings);
    const digitsOnly = /^[0-9]+$/.test(query);
    let messages = [];

    if (isReserved && digitsOnly) {
      const rowsQ = await db.query(
        `SELECT m.id,
                m.sender_id,
                m.client_msg_id,
                m.text,
                m.meta,
                m.created_at,
                (m.sender_id::text = $3::text) AS from_me,
                false AS is_read_by_me,
                false AS read_by_others,
                0::int AS read_count,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
                u.email AS sender_email,
                u.avatar_url AS sender_avatar_url,
                COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
                COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
                COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
         FROM messages m
         LEFT JOIN users u ON u.id = m.sender_id
         WHERE m.chat_id = $1
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
           AND COALESCE(m.meta->>'product_code', '') = $2
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT $4`,
        [chatId, query, String(userId), safeLimit],
      );
      messages = rowsQ.rows.map((row) =>
        decorateMessageMediaUrls(req, decryptMessageRow(row)),
      );
    } else if (isReserved) {
      const like = `%${escapeLikePattern(query.toLowerCase())}%`;
      const rowsQ = await db.query(
        `SELECT m.id,
                m.sender_id,
                m.client_msg_id,
                m.text,
                m.meta,
                m.created_at,
                (m.sender_id::text = $3::text) AS from_me,
                false AS is_read_by_me,
                false AS read_by_others,
                0::int AS read_count,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
                u.email AS sender_email,
                u.avatar_url AS sender_avatar_url,
                COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
                COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
                COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
         FROM messages m
         LEFT JOIN users u ON u.id = m.sender_id
         WHERE m.chat_id = $1
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $3::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
           AND (
             LOWER(COALESCE(m.meta->>'title', '')) LIKE $2 ESCAPE '\\'
             OR LOWER(COALESCE(m.meta->>'description', '')) LIKE $2 ESCAPE '\\'
           )
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT $4`,
        [chatId, like, String(userId), safeLimit],
      );
      messages = rowsQ.rows.map((row) =>
        decorateMessageMediaUrls(req, decryptMessageRow(row)),
      );
    } else {
      const rowsQ = await db.query(
        `SELECT m.id,
                m.sender_id,
                m.client_msg_id,
                m.text,
                m.meta,
                m.created_at,
                (m.sender_id::text = $2::text) AS from_me,
                false AS is_read_by_me,
                false AS read_by_others,
                0::int AS read_count,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS sender_name,
                u.email AS sender_email,
                u.avatar_url AS sender_avatar_url,
                COALESCE(u.avatar_focus_x, 0) AS sender_avatar_focus_x,
                COALESCE(u.avatar_focus_y, 0) AS sender_avatar_focus_y,
                COALESCE(u.avatar_zoom, 1) AS sender_avatar_zoom
         FROM messages m
         LEFT JOIN users u ON u.id = m.sender_id
         WHERE m.chat_id = $1
           AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? $2::text)
           AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT 2000`,
        [chatId, String(userId)],
      );
      const q = query.toLowerCase();
      messages = rowsQ.rows
        .map((row) => decorateMessageMediaUrls(req, decryptMessageRow(row)))
        .filter((row) => {
          const meta = parseMeta(row?.meta);
          const haystacks = [
            String(row?.text || "").toLowerCase(),
            String(meta.title || "").toLowerCase(),
            String(meta.description || "").toLowerCase(),
          ];
          return haystacks.some((item) => item.includes(q));
        })
        .slice(0, safeLimit);
    }

    const hydrated = await attachReactionMapsToMessages(messages);
    return res.json({
      ok: true,
      data: hydrated.map((row) => decorateMessageMediaUrls(req, row)),
    });
  } catch (err) {
    console.error("chats.search error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/:chatId/pin", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const pin = await getActivePinForUser(req, chatId, userId);
    return res.json({ ok: true, data: pin });
  } catch (err) {
    console.error("chats.getPin error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post("/:chatId/pin/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }
    if (!(await canPinInChat(req.user))) {
      return res.status(403).json({
        ok: false,
        error: "Закреплять сообщения могут только администраторы",
      });
    }

    const messageQ = await db.query(
      `SELECT id
       FROM messages
       WHERE id = $1
         AND chat_id = $2
       LIMIT 1`,
      [messageId, chatId],
    );
    if (messageQ.rowCount === 0) {
      return res.status(404).json({
        ok: false,
        error: "Сообщение не найдено в этом чате",
      });
    }

    await db.query(
      `UPDATE chat_pins
       SET is_active = false,
           updated_at = now()
       WHERE chat_id = $1
         AND is_active = true`,
      [chatId],
    );

    await db.query(
      `INSERT INTO chat_pins (
         id,
         chat_id,
         message_id,
         pinned_by,
         is_active,
         created_at,
         updated_at
       )
       VALUES (
         gen_random_uuid(),
         $1,
         $2,
         $3,
         true,
         now(),
         now()
       )
       ON CONFLICT (chat_id, message_id)
       DO UPDATE
         SET pinned_by = EXCLUDED.pinned_by,
             is_active = true,
             updated_at = now()`,
      [chatId, messageId, userId],
    );

    const pin = await getActivePinForUser(req, chatId, userId);
    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:pinned", { chatId, pin });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({ ok: true, data: pin });
  } catch (err) {
    console.error("chats.pinMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.delete("/:chatId/pin", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }
    if (!(await canPinInChat(req.user))) {
      return res.status(403).json({
        ok: false,
        error: "Снимать закреп может только администратор",
      });
    }

    await db.query(
      `UPDATE chat_pins
       SET is_active = false,
           updated_at = now()
       WHERE chat_id = $1
         AND is_active = true`,
      [chatId],
    );

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:pinned", { chatId, pin: null });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({ ok: true, data: null });
  } catch (err) {
    console.error("chats.unpinMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post("/:chatId/read", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;
    const visibleUntilMessageId = trimOptionalUuid(
      req.body?.visible_until_message_id,
    );

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const readRows = await markChatMessagesRead(
      chatId,
      userId,
      visibleUntilMessageId,
    );
    await markChatInboxItemsRead({ userId, chatId });
    const messageIds = readRows
      .map((row) => row.message_id)
      .filter(Boolean);

    const unreadCount = await computeNotificationBadgeCount(userId);
    const io = req.app.get("io");
    if (io) {
      if (messageIds.length > 0) {
        const bySender = new Map();
        for (const row of readRows) {
          const senderId = String(row.sender_id || "").trim();
          const messageId = String(row.message_id || "").trim();
          if (!senderId || !messageId) continue;
          if (!bySender.has(senderId)) {
            bySender.set(senderId, []);
          }
          bySender.get(senderId).push(messageId);
        }
        for (const [senderId, senderMessageIds] of bySender.entries()) {
          io.to(`user:${senderId}`).emit("chat:message:read", {
            chatId,
            readerId: String(userId),
            messageIds: senderMessageIds,
          });
        }
      }
      io.to(`user:${userId}`).emit("notification:badge", {
        unread_count: unreadCount,
      });
      io.to(`user:${userId}`).emit("chat:message:read", {
        chatId,
        readerId: String(userId),
        unread_count: unreadCount,
      });
    }

    return res.json({
      ok: true,
      data: {
        chat_id: chatId,
        message_ids: messageIds,
        visible_until_message_id: visibleUntilMessageId,
        unread_count: unreadCount,
      },
    });
  } catch (err) {
    console.error("chats.markRead error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

/**
 * POST /api/chats/:chatId/messages
 * Поддержка client_msg_id для дедупликации
 */
router.post("/:chatId/messages", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;
    const {
      text,
      client_msg_id,
      reply_to_message_id,
      reply_preview_text,
      reply_preview_sender_name,
      forwarded_from_message_id,
      forwarded_from_chat_id,
      forwarded_from_sender_name,
    } = req.body || {};

    const antifraud = await guardAction({
      queryable: db,
      tenantId: req.user?.tenant_id || null,
      userId,
      actionKey: "chats.post_message",
      details: {
        chat_id: chatId,
      },
    });
    if (!antifraud.allowed) {
      return res.status(429).json({
        ok: false,
        error:
            antifraud.reason ||
            "Слишком много сообщений за короткое время. Повторите позже.",
        blocked_until: antifraud.blockedUntil || null,
      });
    }

    if (!text || !text.trim())
      return res.status(400).json({ ok: false, error: "Text required" });

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canPostChat(context, role, permissionSet.permissions)) {
      return res
        .status(403)
        .json({
          ok: false,
          error: "Нет прав на отправку сообщения в этот чат",
        });
    }

    const messageMeta = {};
    if (trimOptionalUuid(reply_to_message_id)) {
      messageMeta.reply_to_message_id = trimOptionalUuid(reply_to_message_id);
      const replyPreviewText = trimOptionalText(reply_preview_text || "", 280);
      const replyPreviewSenderName = trimOptionalText(
        reply_preview_sender_name || "",
        180,
      );
      if (replyPreviewText) {
        messageMeta.reply_preview_text = replyPreviewText;
      }
      if (replyPreviewSenderName) {
        messageMeta.reply_preview_sender_name = replyPreviewSenderName;
      }
    }
    if (trimOptionalUuid(forwarded_from_message_id)) {
      messageMeta.forwarded_from_message_id = trimOptionalUuid(
        forwarded_from_message_id,
      );
      messageMeta.forwarded_from_chat_id =
        trimOptionalUuid(forwarded_from_chat_id);
      messageMeta.forwarded_from_sender_name = trimOptionalText(
        forwarded_from_sender_name || "",
        180,
      ).trim();
    }

    const insert = await insertMessageWithDedup({
      clientMsgId: String(client_msg_id || "").trim() || null,
      chatId,
      senderId: userId,
      text: String(text),
      metaJson:
        Object.keys(messageMeta).length > 0 ? JSON.stringify(messageMeta) : null,
    });

    const messageId = insert.rows[0]?.id;
    if (!messageId) {
      return res.status(500).json({ ok: false, error: "Не удалось создать сообщение" });
    }
    await maybeBindDirectRequestFirstMessage(chatId, messageId);

    let promptMessageId = null;
    let autoReplyMessageId = null;
    if (isSupportTicketChatContext(context)) {
      const ticketId = supportTicketIdFromSettings(context.settings);
      if (ticketId) {
        const synced = await syncSupportTicketOnMessage({
          chatId,
          senderId: userId,
          senderRole: role,
          tenantId: req.user.tenant_id || null,
          supportTicketId: ticketId,
          messageText: String(text || ""),
        });
        promptMessageId = synced.promptMessageId || null;
        autoReplyMessageId = synced.autoReplyMessageId || null;
      }
    }

    const responseMessage = await finalizeCreatedMessage(
      req,
      chatId,
      messageId,
      userId,
    );
    await upsertUserChatState(userId, chatId, {
      last_seen_message_id: messageId,
      draft_text: "",
      draft_updated_at: new Date().toISOString(),
    });
    if (promptMessageId) {
      await finalizeCreatedMessage(req, chatId, promptMessageId, userId);
    }
    if (autoReplyMessageId) {
      await finalizeCreatedMessage(req, chatId, autoReplyMessageId, userId);
    }
    return res.status(201).json({ ok: true, data: responseMessage });
  } catch (err) {
    console.error("chats.postMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post(
  "/:chatId/messages/media",
  requireAuth,
  uploadChatMedia,
  async (req, res) => {
    const uploadedFiles = [
      ...((req.files?.image || []).map((file) => file)),
      ...((req.files?.voice || []).map((file) => file)),
      ...((req.files?.video || []).map((file) => file)),
      ...((req.files?.file || []).map((file) => file)),
    ];
    try {
      const userId = req.user.id;
      const role = req.user.role;
      const { chatId } = req.params;
      const caption = String(req.body?.text || "").trim();
      const clientMsgId = String(req.body?.client_msg_id || "").trim();
      const replyToMessageId = trimOptionalUuid(req.body?.reply_to_message_id);
      const replyPreviewText = trimOptionalText(
        req.body?.reply_preview_text || "",
        280,
      );
      const replyPreviewSenderName = trimOptionalText(
        req.body?.reply_preview_sender_name || "",
        180,
      );
      const forwardedFromMessageId = trimOptionalUuid(
        req.body?.forwarded_from_message_id,
      );
      const forwardedFromChatId = trimOptionalUuid(
        req.body?.forwarded_from_chat_id,
      );
      const forwardedFromSenderName = trimOptionalText(
        req.body?.forwarded_from_sender_name || "",
        180,
      ).trim();
      const durationMsRaw = Math.floor(Number(req.body?.duration_ms || 0));
      const imageFile = req.files?.image?.[0] || null;
      const voiceFile = req.files?.voice?.[0] || null;
      const videoFile = req.files?.video?.[0] || null;
      const fileFile = req.files?.file?.[0] || null;

      const pickedCount =
        (imageFile ? 1 : 0) +
        (voiceFile ? 1 : 0) +
        (videoFile ? 1 : 0) +
        (fileFile ? 1 : 0);
      if (pickedCount !== 1) {
        console.warn("[chat-media] invalid uploaded files count", {
          pickedCount,
          hasImage: Boolean(imageFile),
          hasVoice: Boolean(voiceFile),
          hasVideo: Boolean(videoFile),
          hasFile: Boolean(fileFile),
          imageMime: imageFile?.mimetype || "",
          voiceMime: voiceFile?.mimetype || "",
          videoMime: videoFile?.mimetype || "",
          fileMime: fileFile?.mimetype || "",
          imageSize: imageFile?.size || 0,
          voiceSize: voiceFile?.size || 0,
          videoSize: videoFile?.size || 0,
          fileSize: fileFile?.size || 0,
          contentType: req.headers?.["content-type"] || "",
          userAgent: req.headers?.["user-agent"] || "",
          origin: req.headers?.origin || "",
          chatId,
          userId,
        });
        removeUploadedFiles(uploadedFiles);
        return res.status(400).json({
          ok: false,
          error:
            "Нужно передать либо изображение, либо голосовое сообщение, либо видео, либо файл",
        });
      }

      const attachmentType = imageFile
        ? "image"
        : voiceFile
        ? "voice"
        : fileFile
        ? "file"
        : "video";
      const uploadedFile = imageFile || voiceFile || videoFile || fileFile;
      const mediaUrl = toChatMediaUrl(req, uploadedFile);
      if (!mediaUrl) {
        removeUploadedFiles(uploadedFiles);
        return res.status(400).json({
          ok: false,
          error: "Не удалось обработать вложение",
        });
      }

      const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
      if (!context) {
        removeUploadedFiles(uploadedFiles);
        return res.status(404).json({ ok: false, error: "Chat not found" });
      }
      const permissionSet = await resolvePermissionSet(req.user, db);
      if (!canPostChat(context, role, permissionSet.permissions)) {
        removeUploadedFiles(uploadedFiles);
        return res.status(403).json({
          ok: false,
          error: "Нет прав на отправку сообщения в этот чат",
        });
      }

      const durationMs = Number.isFinite(durationMsRaw) && durationMsRaw > 0
        ? durationMsRaw
        : 0;
      const imageWidth = attachmentType === "image"
        ? parsePositiveMediaNumber(req.body?.image_width)
        : null;
      const imageHeight = attachmentType === "image"
        ? parsePositiveMediaNumber(req.body?.image_height)
        : null;
      const imageAspectRatio = attachmentType === "image"
        ? parsePositiveMediaNumber(req.body?.image_aspect_ratio, {
            round: false,
          })
        : null;
      const imagePreprocess = attachmentType === "image"
        ? String(req.body?.image_preprocess || "").trim().slice(0, 64)
        : "";
      const hasCaption = caption.length > 0;
      const text = attachmentType === "image"
        ? (hasCaption ? caption : "Фото")
        : attachmentType === "video"
        ? (hasCaption ? caption : "Видеосообщение")
        : attachmentType === "file"
        ? (hasCaption ? caption : "Файл")
        : "Голосовое сообщение";
      const meta = {
        attachment_type: attachmentType,
        ...(hasCaption ? { caption } : {}),
        ...(replyToMessageId ? { reply_to_message_id: replyToMessageId } : {}),
        ...(replyPreviewText ? { reply_preview_text: replyPreviewText } : {}),
        ...(replyPreviewSenderName
          ? { reply_preview_sender_name: replyPreviewSenderName }
          : {}),
        ...(forwardedFromMessageId
          ? {
              forwarded_from_message_id: forwardedFromMessageId,
              forwarded_from_chat_id: forwardedFromChatId,
              forwarded_from_sender_name: forwardedFromSenderName,
            }
          : {}),
        ...(attachmentType === "image"
          ? {
              image_url: mediaUrl,
              ...(imageWidth ? { image_width: imageWidth } : {}),
              ...(imageHeight ? { image_height: imageHeight } : {}),
              ...(imageAspectRatio ? { image_aspect_ratio: imageAspectRatio } : {}),
              ...(imagePreprocess ? { image_preprocess: imagePreprocess } : {}),
            }
          : attachmentType === "voice"
          ? {
              voice_url: mediaUrl,
              voice_duration_ms: durationMs,
              voice_mime_type: String(uploadedFile.mimetype || "").trim(),
              voice_file_name: String(
                uploadedFile.originalname || uploadedFile.filename || "",
              ).trim(),
            }
          : attachmentType === "file"
          ? {
              file_url: mediaUrl,
              file_mime_type: String(uploadedFile.mimetype || "").trim(),
              file_name: String(
                uploadedFile.originalname || uploadedFile.filename || "",
              ).trim(),
              file_size:
                uploadedFile.size == null ? null : Number(uploadedFile.size),
            }
          : {
              video_url: mediaUrl,
              video_duration_ms: durationMs,
              video_mime_type: String(uploadedFile.mimetype || "").trim(),
              video_file_name: String(
                uploadedFile.originalname || uploadedFile.filename || "",
              ).trim(),
            }),
      };

      if (clientMsgId) {
        const existing = await db.query(
          `SELECT id
           FROM messages
           WHERE client_msg_id = $1
           LIMIT 1`,
          [clientMsgId],
        );
        if (existing.rowCount > 0) {
          removeUploadedFiles(uploadedFiles);
          const responseMessage = await finalizeCreatedMessage(
            req,
            chatId,
            existing.rows[0].id,
            userId,
          );
          return res.status(201).json({ ok: true, data: responseMessage });
        }
      }

      const insert = await insertMessageWithDedup({
        clientMsgId: clientMsgId || null,
        chatId,
        senderId: userId,
        text,
        metaJson: JSON.stringify(meta),
      });

      const messageId = insert.rows[0]?.id;
      if (!messageId) {
        removeUploadedFiles(uploadedFiles);
        return res.status(500).json({
          ok: false,
          error: "Не удалось создать сообщение",
        });
      }
      await upsertMessageAttachments({
        messageId,
        attachments: [
          {
            attachment_type: attachmentType,
            sort_order: 0,
            storage_url: mediaUrl,
            file_name: String(
              uploadedFile.originalname || uploadedFile.filename || "",
            ).trim() || null,
            mime_type: String(uploadedFile.mimetype || "").trim() || null,
            file_size:
              uploadedFile.size == null ? null : Number(uploadedFile.size),
            width: imageWidth,
            height: imageHeight,
            aspect_ratio: imageAspectRatio,
            duration_ms: durationMs > 0 ? durationMs : null,
            preprocess_tag: imagePreprocess || null,
            quality_mode: req.body?.quality_mode,
            is_video_note:
              attachmentType === "video" &&
              (req.body?.is_video_note == true ||
                String(req.body?.is_video_note || "").trim() == "true"),
            is_listen_once:
              attachmentType === "voice" &&
              (req.body?.listen_once == true ||
                String(req.body?.listen_once || "").trim() == "true"),
          },
        ],
      });
      const qualityResolution = resolveAttachmentQualityMode(
        req.body?.quality_mode,
        attachmentType,
      );
      if (qualityResolution.defaulted) {
        console.warn("chats.postMediaMessage.quality.defaulted", {
          reason_code: qualityResolution.reasonCode,
          chat_id: chatId,
          message_id: messageId,
          attachment_type: attachmentType,
        });
      }
      await maybeBindDirectRequestFirstMessage(chatId, messageId);

      let promptMessageId = null;
      let autoReplyMessageId = null;
      if (isSupportTicketChatContext(context)) {
        const ticketId = supportTicketIdFromSettings(context.settings);
        if (ticketId) {
          const synced = await syncSupportTicketOnMessage({
            chatId,
            senderId: userId,
            senderRole: role,
            tenantId: req.user.tenant_id || null,
            supportTicketId: ticketId,
            messageText: caption || text || "",
          });
          promptMessageId = synced.promptMessageId || null;
          autoReplyMessageId = synced.autoReplyMessageId || null;
        }
      }

      const responseMessage = await finalizeCreatedMessage(
        req,
        chatId,
        messageId,
        userId,
      );
      await upsertUserChatState(userId, chatId, {
        last_seen_message_id: messageId,
        draft_text: "",
        draft_updated_at: new Date().toISOString(),
      });
      if (promptMessageId) {
        await finalizeCreatedMessage(req, chatId, promptMessageId, userId);
      }
      if (autoReplyMessageId) {
        await finalizeCreatedMessage(req, chatId, autoReplyMessageId, userId);
      }
      return res.status(201).json({ ok: true, data: responseMessage });
    } catch (err) {
      removeUploadedFiles(uploadedFiles);
      console.error("chats.postMediaMessage error", err);
      return res.status(500).json({
        ok: false,
        error: "Server error",
        error_code: "chat_media_send_failed",
      });
    }
  },
);

/**
 * PATCH /api/chats/:chatId/messages/:messageId
 * Редактирование сообщения автором или admin/creator
 */
router.patch("/:chatId/messages/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;
    const nextText = String(req.body?.text || "").trim();
    if (!nextText) {
      return res.status(400).json({ ok: false, error: "Text required" });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const messageQ = await db.query(
      `SELECT id, chat_id, sender_id, text, meta, created_at
       FROM messages
       WHERE id = $1 AND chat_id = $2
       LIMIT 1`,
      [messageId, chatId],
    );
    if (messageQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
    }

    const message = messageQ.rows[0];
    const meta = parseMeta(message.meta);
    if (isSystemMessage(meta)) {
      return res.status(403).json({
        ok: false,
        error: "Системные сообщения нельзя редактировать",
      });
    }

    const ownMessage = String(message.sender_id || "") === String(userId);
    const adminOrCreator = isAdminOrCreator(role);
    if (!ownMessage && !adminOrCreator) {
      return res.status(403).json({
        ok: false,
        error: "Редактировать можно только свои сообщения",
      });
    }

    const previousText = decryptMessageText(message.text);
    await db.query(
      `INSERT INTO message_edits (
         id,
         message_id,
         edited_by,
         editor_role,
         previous_text,
         edited_at
       )
       VALUES ($1, $2, $3, $4, $5, now())`,
      [
        uuidv4(),
        messageId,
        userId,
        String(req.user.role || "").trim(),
        previousText,
      ],
    );

    const upd = await db.query(
      `UPDATE messages
       SET text = $1,
           meta = (
             jsonb_set(
               jsonb_set(
                 jsonb_set(
                   jsonb_set(COALESCE(meta, '{}'::jsonb), '{edited}', 'true'::jsonb, true),
                   '{edited_at}',
                   to_jsonb(now()),
                   true
                 ),
                 '{edited_by_role}',
                 to_jsonb($3::text),
                 true
               ),
               '{edited_by_name}',
               to_jsonb($4::text),
               true
             )
           )
       WHERE id = $2
       RETURNING id`,
      [
        encryptMessageText(nextText),
        messageId,
        String(req.user.role || "").trim(),
        String(req.user.name || req.user.email || "").trim(),
      ],
    );
    const updatedRaw = await getHydratedMessageById(upd.rows[0]?.id, userId);
    const updated = decorateMessageMediaUrls(req, updatedRaw);
    if (!updated) {
      return res.status(500).json({ ok: false, error: "Не удалось загрузить сообщение" });
    }

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:message", { chatId, message: updated });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({ ok: true, data: updated });
  } catch (err) {
    console.error("chats.editMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get(
  "/:chatId/messages/:messageId/edit-history",
  requireAuth,
  async (req, res) => {
    try {
      const userId = req.user.id;
      const role = req.user.role;
      const { chatId, messageId } = req.params;

      const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
      if (!context) {
        return res.status(404).json({ ok: false, error: "Chat not found" });
      }
      const permissionSet = await resolvePermissionSet(req.user, db);
      if (!canReadChat(context, role, permissionSet.permissions)) {
        return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
      }

      const rowsQ = await db.query(
        `SELECT me.id,
                me.message_id,
                me.edited_by,
                me.editor_role,
                me.previous_text,
                me.edited_at,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS edited_by_name
         FROM message_edits me
         LEFT JOIN users u ON u.id = me.edited_by
         WHERE me.message_id = $1
         ORDER BY me.edited_at DESC, me.id DESC`,
        [messageId],
      );
      return res.json({ ok: true, data: rowsQ.rows });
    } catch (err) {
      console.error("chats.editHistory error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.post(
  "/:chatId/messages/:messageId/reactions",
  requireAuth,
  async (req, res) => {
    try {
      const userId = req.user.id;
      const role = req.user.role;
      const { chatId, messageId } = req.params;
      const emoji = normalizeReactionEmoji(req.body?.emoji || "");
      if (!emoji) {
        return res.status(400).json({ ok: false, error: "emoji required" });
      }

      const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
      if (!context) {
        return res.status(404).json({ ok: false, error: "Chat not found" });
      }
      const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
        return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
      }

      const messageQ = await db.query(
        `SELECT id, sender_id, meta
         FROM messages
         WHERE id = $1
           AND chat_id = $2
         LIMIT 1
         FOR UPDATE`,
        [messageId, chatId],
      );
      if (messageQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
      }

      const current = messageQ.rows[0];
      const meta = parseMeta(current.meta);
      if (isSystemMessage(meta)) {
        return res.status(403).json({
          ok: false,
          error: "Системные сообщения не поддерживают реакции",
        });
      }
      if (meta.deleted === true || meta.hidden_for_all === true) {
        return res.status(400).json({
          ok: false,
          error: "Нельзя поставить реакцию на удаленное сообщение",
        });
      }

      const userIdText = String(userId || "").trim();
      const byUser = normalizeReactionsByUser(meta.reactions_by_user);
      const currentEmoji = byUser[userIdText] || "";
      if (currentEmoji === emoji) {
        await db.query(
          `DELETE FROM message_reactions
           WHERE message_id = $1
             AND user_id = $2`,
          [messageId, userId],
        );
        delete byUser[userIdText];
      } else {
        await db.query(
          `INSERT INTO message_reactions (
             message_id,
             user_id,
             emoji,
             created_at,
             updated_at
           )
           VALUES ($1, $2, $3, now(), now())
           ON CONFLICT (message_id, user_id)
           DO UPDATE
             SET emoji = EXCLUDED.emoji,
                 updated_at = now()`,
          [messageId, userId, emoji],
        );
        byUser[userIdText] = emoji;
      }

      const nextMeta = { ...meta };
      if (Object.keys(byUser).length > 0) {
        nextMeta.reactions_by_user = byUser;
      } else {
        delete nextMeta.reactions_by_user;
      }

      const upd = await db.query(
        `UPDATE messages
         SET meta = $1::jsonb
         WHERE id = $2
         RETURNING id`,
        [JSON.stringify(nextMeta), messageId],
      );
      const updatedRaw = await getHydratedMessageById(upd.rows[0]?.id, userId);
      const updated = decorateMessageMediaUrls(req, updatedRaw);
      if (!updated) {
        return res.status(500).json({ ok: false, error: "Не удалось загрузить сообщение" });
      }

      const io = req.app.get("io");
      if (io) {
        io.to(`chat:${chatId}`).emit("chat:message", { chatId, message: updated });
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
      }
      return res.json({ ok: true, data: updated });
    } catch (err) {
      console.error("chats.reaction.toggle error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.delete(
  "/:chatId/messages/:messageId/reactions",
  requireAuth,
  async (req, res) => {
    try {
      const userId = req.user.id;
      const role = req.user.role;
      const { chatId, messageId } = req.params;

      const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
      if (!context) {
        return res.status(404).json({ ok: false, error: "Chat not found" });
      }
      const permissionSet = await resolvePermissionSet(req.user, db);
      if (!canReadChat(context, role, permissionSet.permissions)) {
        return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
      }

      const messageQ = await db.query(
        `SELECT id, meta
         FROM messages
         WHERE id = $1
           AND chat_id = $2
         LIMIT 1`,
        [messageId, chatId],
      );
      if (messageQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
      }

      await db.query(
        `DELETE FROM message_reactions
         WHERE message_id = $1
           AND user_id = $2`,
        [messageId, userId],
      );

      const meta = parseMeta(messageQ.rows[0].meta);
      const byUser = normalizeReactionsByUser(meta.reactions_by_user);
      delete byUser[String(userId || "").trim()];
      const nextMeta = { ...meta };
      if (Object.keys(byUser).length > 0) {
        nextMeta.reactions_by_user = byUser;
      } else {
        delete nextMeta.reactions_by_user;
      }
      await db.query(
        `UPDATE messages
         SET meta = $1::jsonb
         WHERE id = $2`,
        [JSON.stringify(nextMeta), messageId],
      );

      const updatedRaw = await getHydratedMessageById(messageId, userId);
      const updated = decorateMessageMediaUrls(req, updatedRaw);
      const io = req.app.get("io");
      if (io && updated) {
        io.to(`chat:${chatId}`).emit("chat:message", { chatId, message: updated });
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
      }
      return res.json({ ok: true, data: updated });
    } catch (err) {
      console.error("chats.reaction.delete error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

/**
 * DELETE /api/chats/:chatId/messages/:messageId
 * Удаление сообщения:
 * - scope=me: скрыть только у текущего пользователя
 * - scope=all: удалить у всех
 */
router.delete("/:chatId/messages/:messageId", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId, messageId } = req.params;
    const scope = String(req.body?.scope || "all")
      .toLowerCase()
      .trim();
    if (scope !== "me" && scope !== "all") {
      return res.status(400).json({
        ok: false,
        error: "scope должен быть me или all",
      });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context)
      return res.status(404).json({ ok: false, error: "Chat not found" });
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const messageQ = await db.query(
      `SELECT id, chat_id, sender_id, text, meta, created_at
       FROM messages
       WHERE id = $1 AND chat_id = $2
       LIMIT 1`,
      [messageId, chatId],
    );
    if (messageQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
    }

    const message = messageQ.rows[0];
    const meta = parseMeta(message.meta);

    // Скрыть только для себя (локальное удаление)
    if (scope === "me") {
      await db.query(
        `UPDATE messages
         SET meta = jsonb_set(
           COALESCE(meta, '{}'::jsonb),
           '{hidden_for}',
           CASE
             WHEN COALESCE(meta->'hidden_for', '[]'::jsonb) ? $2::text
               THEN COALESCE(meta->'hidden_for', '[]'::jsonb)
             ELSE COALESCE(meta->'hidden_for', '[]'::jsonb) || to_jsonb($2::text)
           END,
           true
         )
         WHERE id = $1`,
        [messageId, String(userId)],
      );
      return res.json({
        ok: true,
        data: {
          message_id: messageId,
          scope: "me",
        },
      });
    }

    const kind = String(meta?.kind || "")
      .toLowerCase()
      .trim();
    const isCatalogPost = kind === "catalog_product";
    const isSystem = isSystemMessage(meta);
    const isCreator = normalizeRole(role) === "creator";

    if (isSystem && !isCatalogPost && !isCreator) {
      return res.status(403).json({
        ok: false,
        error: "Этот тип системных сообщений нельзя удалять у всех",
      });
    }

    const ownMessage = String(message.sender_id || "") === String(userId);
    const adminOrCreator = isAdminOrCreator(role);

    if (isCatalogPost) {
      if (!adminOrCreator) {
        return res.status(403).json({
          ok: false,
          error: "Посты с товарами могут удалять только admin/creator",
        });
      }
    } else if (!ownMessage && !adminOrCreator) {
      return res.status(403).json({
        ok: false,
        error: "Удалять у всех можно только свои сообщения",
      });
    }

    const deleted = await db.query(
      `DELETE FROM messages
       WHERE id = $1 AND chat_id = $2
       RETURNING id`,
      [messageId, chatId],
    );
    if (deleted.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Сообщение не найдено" });
    }

    removeChatMediaByUrl(meta?.image_url);
    removeChatMediaByUrl(meta?.voice_url);
    removeChatMediaByUrl(meta?.video_url);
    removeChatMediaByUrl(meta?.file_url);

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:message:deleted", {
        chatId,
        messageId,
      });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({
      ok: true,
      data: {
        message_id: messageId,
        scope: "all",
      },
    });
  } catch (err) {
    console.error("chats.deleteMessage error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.delete("/:chatId/messages", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const baseRole = String(req.user.base_role || role || "")
      .toLowerCase()
      .trim();
    const { chatId } = req.params;

    if (baseRole !== "creator") {
      return res.status(403).json({
        ok: false,
        error: "Полная очистка чата доступна только создателю",
      });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const mediaQ = await db.query(
      `SELECT meta
       FROM messages
       WHERE chat_id = $1`,
      [chatId],
    );

    for (const row of mediaQ.rows) {
      const meta = parseMeta(row.meta);
      removeChatMediaByUrl(meta?.image_url);
      removeChatMediaByUrl(meta?.voice_url);
      removeChatMediaByUrl(meta?.video_url);
      removeChatMediaByUrl(meta?.file_url);
    }

    await db.query("DELETE FROM message_reads WHERE chat_id = $1", [chatId]);
    const deleted = await db.query(
      `DELETE FROM messages
       WHERE chat_id = $1`,
      [chatId],
    );
    await db.query("UPDATE chats SET updated_at = now() WHERE id = $1", [chatId]);

    const io = req.app.get("io");
    if (io) {
      io.to(`chat:${chatId}`).emit("chat:cleared", { chatId });
      emitToTenant(io, req.user?.tenant_id || null, "chat:updated", { chatId });
    }

    return res.json({
      ok: true,
      data: {
        chat_id: chatId,
        deleted_count: deleted.rowCount || 0,
      },
    });
  } catch (err) {
    console.error("chats.clearMessages error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.patch("/:chatId/list-preferences", requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const role = req.user.role;
    const { chatId } = req.params;
    const payload = req.body || {};
    const hasHidden = Object.prototype.hasOwnProperty.call(payload, "hidden");
    const hasPinned = Object.prototype.hasOwnProperty.call(payload, "pinned");

    if (!hasHidden && !hasPinned) {
      return res.status(400).json({
        ok: false,
        error: "Нужно передать hidden и/или pinned",
      });
    }

    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    const settings = normalizeSettings(context.chat.settings);
    const systemKey = String(settings.system_key || "")
      .toLowerCase()
      .trim();
    const isMainChannel =
      context.chat.type === "channel" && systemKey === "main_channel";
    const hidden = hasHidden ? Boolean(payload.hidden) : null;
    const pinned = hasPinned ? Boolean(payload.pinned) : null;

    if (isMainChannel && hidden === true) {
      return res.status(400).json({
        ok: false,
        error: "Основной канал нельзя скрывать",
      });
    }

    const upsert = await db.query(
      `INSERT INTO user_chat_preferences (
         user_id, chat_id, hidden, pinned, pinned_at, created_at, updated_at
       )
       VALUES (
         $1,
         $2,
         COALESCE($3::boolean, false),
         COALESCE($4::boolean, false),
         CASE WHEN COALESCE($4::boolean, false) THEN now() ELSE NULL END,
         now(),
         now()
       )
       ON CONFLICT (user_id, chat_id) DO UPDATE
         SET hidden = CASE
               WHEN $3::boolean IS NULL THEN user_chat_preferences.hidden
               ELSE $3::boolean
             END,
             pinned = CASE
               WHEN $4::boolean IS NULL THEN user_chat_preferences.pinned
               ELSE $4::boolean
             END,
             pinned_at = CASE
               WHEN $4::boolean IS NULL THEN user_chat_preferences.pinned_at
               WHEN $4::boolean = true THEN now()
               ELSE NULL
             END,
             updated_at = now()
       RETURNING user_id, chat_id, hidden, pinned, pinned_at, updated_at`,
      [
        userId,
        chatId,
        hasHidden ? hidden : null,
        hasPinned ? pinned : null,
      ],
    );

    if (hasHidden && hidden === true) {
      await db.query(
        `UPDATE messages
         SET meta = jsonb_set(
           COALESCE(meta, '{}'::jsonb),
           '{hidden_for}',
           CASE
             WHEN COALESCE(meta->'hidden_for', '[]'::jsonb) ? $2::text
               THEN COALESCE(meta->'hidden_for', '[]'::jsonb)
             ELSE COALESCE(meta->'hidden_for', '[]'::jsonb) || to_jsonb($2::text)
           END,
           true
         )
         WHERE chat_id = $1
           AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false`,
        [chatId, String(userId)],
      );
    }

    const pref = upsert.rows[0];
    if (pref && !pref.hidden && !pref.pinned) {
      await db.query(
        `DELETE FROM user_chat_preferences
         WHERE user_id = $1
           AND chat_id = $2`,
        [userId, chatId],
      );
    }

    return res.json({
      ok: true,
      data: {
        chat_id: chatId,
        hidden: Boolean(pref?.hidden),
        pinned: Boolean(pref?.pinned),
        pinned_at: pref?.pinned_at || null,
      },
    });
  } catch (err) {
    console.error("chats.listPreferences error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/contacts", requireAuth, async (req, res) => {
  try {
    const rows = await db.query(
      `SELECT uc.contact_user_id,
              uc.alias_name,
              uc.created_at,
              uc.updated_at,
              u.name,
              p.phone,
              u.avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS avatar_zoom,
              true AS is_in_contacts,
              COALESCE(pc.last_interaction_at, uc.updated_at, uc.created_at) AS recent_at
       FROM user_contacts uc
       JOIN users u ON u.id = uc.contact_user_id
       LEFT JOIN phones p ON p.user_id = u.id
       LEFT JOIN LATERAL (
         SELECT c.updated_at AS last_interaction_at
         FROM chats c
         JOIN chat_members cm_self
           ON cm_self.chat_id = c.id
          AND cm_self.user_id = $1
         JOIN chat_members cm_peer
           ON cm_peer.chat_id = c.id
          AND cm_peer.user_id = uc.contact_user_id
         WHERE c.type = 'private'
           AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
         ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC
         LIMIT 1
       ) pc ON true
       WHERE uc.user_id = $1
         AND ($2::uuid IS NULL OR uc.tenant_id = $2::uuid)
       ORDER BY recent_at DESC NULLS LAST,
                COALESCE(
                  NULLIF(TRIM(uc.alias_name), ''),
                  NULLIF(TRIM(u.name), ''),
                  NULLIF(TRIM(p.phone), ''),
                  u.id::text
                ) ASC`,
      [req.user.id, req.user.tenant_id || null],
    );
    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error("chats.contacts.list error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post("/contacts", requireAuth, async (req, res) => {
  const aliasName = String(req.body?.alias_name || "").trim().slice(0, 120);
  const targetId = String(req.body?.user_id || "").trim();
  const query = String(req.body?.query || "").trim();

  if (!targetId && !query) {
    return res.status(400).json({
      ok: false,
      error: "Нужен user_id или query",
    });
  }

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    const peer = await resolveDirectTargetUser(client, req.user, {
      userId: targetId,
      query,
    });
    if (!peer) {
      await client.query("ROLLBACK");
      return res.status(404).json({ ok: false, error: "Контакт не найден" });
    }
    const existingQ = await client.query(
      `SELECT alias_name, created_at, updated_at
       FROM user_contacts
       WHERE user_id = $1
         AND contact_user_id = $2
         AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
       LIMIT 1`,
      [req.user.id, peer.id, req.user.tenant_id || null],
    );

    let created = false;
    let savedAlias = aliasName;
    let contactCreatedAt = null;
    let contactUpdatedAt = null;

    if (existingQ.rowCount === 0) {
      const inserted = await client.query(
        `INSERT INTO user_contacts (
           id, tenant_id, user_id, contact_user_id, alias_name, created_at, updated_at
         )
         VALUES ($1, $2, $3, $4, $5, now(), now())
         RETURNING alias_name, created_at, updated_at`,
        [
          uuidv4(),
          req.user.tenant_id || null,
          req.user.id,
          peer.id,
          aliasName,
        ],
      );
      created = true;
      savedAlias = String(inserted.rows[0]?.alias_name || "").trim();
      contactCreatedAt = inserted.rows[0]?.created_at || null;
      contactUpdatedAt = inserted.rows[0]?.updated_at || null;
    } else {
      savedAlias = String(existingQ.rows[0]?.alias_name || "").trim();
      contactCreatedAt = existingQ.rows[0]?.created_at || null;
      contactUpdatedAt = existingQ.rows[0]?.updated_at || null;

      if (aliasName && aliasName !== savedAlias) {
        const updated = await client.query(
          `UPDATE user_contacts
           SET alias_name = $4, updated_at = now()
           WHERE user_id = $1
             AND contact_user_id = $2
             AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
           RETURNING alias_name, created_at, updated_at`,
          [req.user.id, peer.id, req.user.tenant_id || null, aliasName],
        );
        savedAlias = String(updated.rows[0]?.alias_name || "").trim();
        contactCreatedAt = updated.rows[0]?.created_at || contactCreatedAt;
        contactUpdatedAt = updated.rows[0]?.updated_at || contactUpdatedAt;
      }
    }
    await client.query("COMMIT");
    return res.status(created ? 201 : 200).json({
      ok: true,
      data: {
        contact_user_id: peer.id,
        alias_name: savedAlias,
        created,
        peer: mapPeerInfo({
          ...peer,
          alias_name: savedAlias,
          is_in_contacts: true,
          contact_created_at: contactCreatedAt,
          contact_updated_at: contactUpdatedAt,
        }),
      },
    });
  } catch (err) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {}
    console.error("chats.contacts.create error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  } finally {
    client.release();
  }
});

router.delete("/contacts/:contactUserId", requireAuth, async (req, res) => {
  try {
    await db.query(
      `DELETE FROM user_contacts
       WHERE user_id = $1
         AND contact_user_id = $2
         AND ($3::uuid IS NULL OR tenant_id = $3::uuid)`,
      [
        req.user.id,
        String(req.params?.contactUserId || "").trim(),
        req.user.tenant_id || null,
      ],
    );
    return res.json({ ok: true });
  } catch (err) {
    console.error("chats.contacts.delete error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.get("/direct/search", requireAuth, directSearchRateGuard, async (req, res) => {
  const query = String(req.query?.query || req.query?.q || "").trim();
  const limitRaw = Number(req.query?.limit || 8);
  const limit = Number.isFinite(limitRaw) ? limitRaw : 8;

  if (!query) {
    return res.json({
      ok: true,
      data: {
        query: "",
        too_short: true,
        exact: null,
        candidates: [],
        message: "Введите минимум 2 символа имени или полный email/номер",
      },
    });
  }

  const client = await db.pool.connect();
  try {
    const search = await searchDirectTargets(client, req.user, {
      query,
      limit,
    });
    if (search.tooShort) {
      return res.json({
        ok: true,
        data: {
          query,
          too_short: true,
          exact: null,
          candidates: [],
          message: "Введите минимум 2 символа имени или полный email/номер",
        },
      });
    }

    const exact = search.exact ? mapPeerInfo(search.exact) : null;
    const candidates = search.rows.map(mapPeerInfo);
    const hasFullIdentifier =
      looksLikeEmail(query) || normalizePhoneDigits(query).length >= 10;

    let message = "";
    if (!exact && candidates.length === 0) {
      message = "Пользователь не найден в вашей группе";
    } else if (!exact && hasFullIdentifier) {
      message = "Точное совпадение не найдено. Проверьте email или номер.";
    }

    return res.json({
      ok: true,
      data: {
        query,
        too_short: false,
        exact,
        candidates,
        message,
      },
    });
  } catch (err) {
    console.error("chats.direct.search error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  } finally {
    client.release();
  }
});

router.post("/direct/open", requireAuth, directOpenRateGuard, async (req, res) => {
  const targetId = String(req.body?.user_id || "").trim();
  const query = String(req.body?.query || "").trim();
  if (!targetId && !query) {
    return res.status(400).json({
      ok: false,
      error: "Нужен user_id или query",
    });
  }
  if (targetId && String(req.user?.id || "").trim() === targetId) {
    return res.status(400).json({
      ok: false,
      error: "Нельзя открыть ЛС с самим собой",
    });
  }

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");

    const peer = await resolveDirectTargetUser(client, req.user, {
      userId: targetId,
      query,
    });
    if (!peer) {
      await client.query("ROLLBACK");
      return res.status(404).json({
        ok: false,
        error: "Пользователь не найден в вашей группе",
      });
    }

    const knownConnection = await areUsersConnectedByContact(
      client,
      req.user.tenant_id || null,
      req.user.id,
      peer.id,
    );
    const peerPreferences = await getMessengerPreferencesForUser(peer.id);

    const existing = await client.query(
      `SELECT c.id, c.title, c.type, c.settings, c.created_at, c.updated_at
       FROM chats c
       JOIN chat_members m1 ON m1.chat_id = c.id AND m1.user_id = $1
       JOIN chat_members m2 ON m2.chat_id = c.id AND m2.user_id = $2
       WHERE c.type = 'private'
         AND COALESCE(c.settings->>'kind', '') <> 'support_ticket'
         AND COALESCE((c.settings->>'support_ticket')::boolean, false) = false
         AND ($3::uuid IS NULL OR c.tenant_id = $3::uuid)
         AND NOT EXISTS (
           SELECT 1
           FROM chat_members mx
           WHERE mx.chat_id = c.id
             AND mx.user_id <> ALL($4::uuid[])
         )
       ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC
       LIMIT 1`,
      [req.user.id, peer.id, req.user.tenant_id || null, [req.user.id, peer.id]],
    );

    let chat = null;
    let created = false;
    let requestRecord = null;
    let requestCreated = false;
    if (existing.rowCount > 0) {
      chat = existing.rows[0];
      requestRecord = await findDirectRequestByChatId(client, chat.id);
      if (
        requestRecord &&
        requestRecord.status === "declined" &&
        String(requestRecord.requester_id || "").trim() === String(req.user.id || "").trim() &&
        String(requestRecord.target_user_id || "").trim() === String(peer.id || "").trim() &&
        requestRecord.cooldown_until &&
        new Date(requestRecord.cooldown_until).getTime() > Date.now()
      ) {
        await client.query("ROLLBACK");
        return res.status(429).json({
          ok: false,
          error: "Запрос уже был отклонен. Попробуйте написать позже.",
          cooldown_until: requestRecord.cooldown_until,
        });
      }
      if (
        requestRecord &&
        requestRecord.status === "declined" &&
        String(requestRecord.requester_id || "").trim() === String(req.user.id || "").trim() &&
        String(requestRecord.target_user_id || "").trim() === String(peer.id || "").trim()
      ) {
        if (
          !knownConnection &&
          (!peerPreferences.allow_unknown_dm_requests ||
            !peerPreferences.allow_tenant_first_contact)
        ) {
          await client.query("ROLLBACK");
          return res.status(403).json({
            ok: false,
            error: "Пользователь принимает ЛС только после добавления в контакты",
          });
        }

        const nextStatus = knownConnection ? "accepted" : "pending";
        const updatedRequestQ = await client.query(
          `UPDATE direct_message_requests
           SET requester_id = $2,
               target_user_id = $3,
               status = $4,
               first_message_id = NULL,
               cooldown_until = NULL,
               responded_at = NULL,
               updated_at = now()
           WHERE id = $1
           RETURNING id,
                     tenant_id,
                     chat_id,
                     requester_id,
                     target_user_id,
                     status,
                     first_message_id,
                     cooldown_until,
                     responded_at,
                     created_at,
                     updated_at`,
          [
            requestRecord.id,
            req.user.id,
            peer.id,
            nextStatus,
          ],
        );
        requestRecord = updatedRequestQ.rows[0] || requestRecord;
        await client.query(
          `UPDATE chats
           SET settings = settings || $2::jsonb,
               updated_at = now()
           WHERE id = $1`,
          [
            chat.id,
            JSON.stringify({
              direct_request_id: requestRecord.id,
              direct_request_status: nextStatus,
              direct_request_created_by: String(req.user.id || "").trim(),
              direct_request_pending_for:
                nextStatus === "pending" ? String(peer.id || "").trim() : null,
              direct_request_first_message_sent: false,
            }),
          ],
        );
        chat = {
          ...chat,
          settings: {
            ...normalizeSettings(chat.settings),
            direct_request_id: requestRecord.id,
            direct_request_status: nextStatus,
            direct_request_created_by: String(req.user.id || "").trim(),
            direct_request_pending_for:
              nextStatus === "pending" ? String(peer.id || "").trim() : null,
            direct_request_first_message_sent: false,
          },
          updated_at: new Date().toISOString(),
        };
        requestCreated = nextStatus === "pending";
      } else if (
        requestRecord &&
        requestRecord.status === "pending" &&
        knownConnection
      ) {
        const acceptedRequestQ = await client.query(
          `UPDATE direct_message_requests
           SET status = 'accepted',
               cooldown_until = NULL,
               responded_at = COALESCE(responded_at, now()),
               updated_at = now()
           WHERE id = $1
           RETURNING id,
                     tenant_id,
                     chat_id,
                     requester_id,
                     target_user_id,
                     status,
                     first_message_id,
                     cooldown_until,
                     responded_at,
                     created_at,
                     updated_at`,
          [requestRecord.id],
        );
        requestRecord = acceptedRequestQ.rows[0] || requestRecord;
        await client.query(
          `UPDATE chats
           SET settings = settings || $2::jsonb,
               updated_at = now()
           WHERE id = $1`,
          [
            chat.id,
            JSON.stringify({
              direct_request_id: requestRecord.id,
              direct_request_status: "accepted",
              direct_request_pending_for: null,
            }),
          ],
        );
        chat = {
          ...chat,
          settings: {
            ...normalizeSettings(chat.settings),
            direct_request_id: requestRecord.id,
            direct_request_status: "accepted",
            direct_request_pending_for: null,
          },
          updated_at: new Date().toISOString(),
        };
      } else if (!requestRecord) {
        const nextSettings = {
          ...normalizeSettings(chat.settings),
          direct_request_status: "accepted",
          direct_request_pending_for: null,
          direct_request_created_by: null,
        };
        await client.query(
          `UPDATE chats
           SET settings = $2::jsonb,
               updated_at = now()
           WHERE id = $1`,
          [chat.id, JSON.stringify(nextSettings)],
        );
        chat = {
          ...chat,
          settings: nextSettings,
          updated_at: new Date().toISOString(),
        };
      }
    } else {
      if (
        !knownConnection &&
        (!peerPreferences.allow_unknown_dm_requests ||
          !peerPreferences.allow_tenant_first_contact)
      ) {
        await client.query("ROLLBACK");
        return res.status(403).json({
          ok: false,
          error: "Пользователь принимает ЛС только после добавления в контакты",
        });
      }

      const requestPending = !knownConnection;
      const settings = {
        kind: "direct_message",
        visibility: "private",
        ...(requestPending
          ? {
              direct_request_status: "pending",
              direct_request_created_by: String(req.user.id || "").trim(),
              direct_request_pending_for: String(peer.id || "").trim(),
              direct_request_first_message_sent: false,
            }
          : {
              direct_request_status: "accepted",
              direct_request_created_by: null,
              direct_request_pending_for: null,
              direct_request_first_message_sent: false,
            }),
      };
      const chatInsert = await client.query(
        `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
         VALUES ($1, $2, 'private', $3, $4, $5::jsonb, now(), now())
         RETURNING id, title, type, settings, created_at, updated_at`,
        [
          uuidv4(),
          "",
          req.user.id,
          req.user.tenant_id || null,
          JSON.stringify(settings),
        ],
      );
      chat = chatInsert.rows[0];
      await client.query(
        `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
         VALUES ($1, $2, $3, now(), 'member')
         ON CONFLICT (chat_id, user_id) DO NOTHING`,
        [uuidv4(), chat.id, req.user.id],
      );
      await client.query(
        `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
         VALUES ($1, $2, $3, now(), 'member')
         ON CONFLICT (chat_id, user_id) DO NOTHING`,
        [uuidv4(), chat.id, peer.id],
      );
      created = true;

      if (requestPending) {
        const insertedRequest = await client.query(
          `INSERT INTO direct_message_requests (
             id,
             tenant_id,
             chat_id,
             requester_id,
             target_user_id,
             status,
             created_at,
             updated_at
           )
           VALUES ($1, $2, $3, $4, $5, 'pending', now(), now())
           RETURNING id,
                     tenant_id,
                     chat_id,
                     requester_id,
                     target_user_id,
                     status,
                     first_message_id,
                     cooldown_until,
                     responded_at,
                     created_at,
                     updated_at`,
          [
            uuidv4(),
            req.user.tenant_id || null,
            chat.id,
            req.user.id,
            peer.id,
          ],
        );
        requestRecord = insertedRequest.rows[0] || null;
        requestCreated = true;
        await client.query(
          `UPDATE chats
           SET settings = settings || $2::jsonb,
               updated_at = now()
           WHERE id = $1`,
          [
            chat.id,
            JSON.stringify({
              direct_request_id: requestRecord?.id || null,
            }),
          ],
        );
        chat = {
          ...chat,
          settings: {
            ...normalizeSettings(chat.settings),
            direct_request_id: requestRecord?.id,
          },
        };
      }
    }

    await client.query(
      `INSERT INTO user_chat_preferences (
         user_id, chat_id, hidden, pinned, pinned_at, created_at, updated_at
       )
       VALUES ($1, $2, false, false, NULL, now(), now())
       ON CONFLICT (user_id, chat_id) DO UPDATE
       SET hidden = false,
           updated_at = now()`,
      [req.user.id, chat.id],
    );
    if (created || requestCreated || requestRecord?.status === "accepted") {
      await client.query(
        `INSERT INTO user_chat_preferences (
           user_id, chat_id, hidden, pinned, pinned_at, created_at, updated_at
         )
         VALUES ($1, $2, false, false, NULL, now(), now())
         ON CONFLICT (user_id, chat_id)
         DO UPDATE
           SET hidden = false,
               updated_at = now()`,
        [peer.id, chat.id],
      );
    }

    const contactInfoQ = await client.query(
      `SELECT alias_name, created_at, updated_at
       FROM user_contacts
       WHERE user_id = $1
         AND contact_user_id = $2
         AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
       LIMIT 1`,
      [req.user.id, peer.id, req.user.tenant_id || null],
    );
    const contactInfo =
      contactInfoQ.rowCount > 0 ? contactInfoQ.rows[0] : null;
    const reverseContactInfoQ = await client.query(
      `SELECT alias_name, created_at, updated_at
       FROM user_contacts
       WHERE user_id = $1
         AND contact_user_id = $2
         AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
       LIMIT 1`,
      [peer.id, req.user.id, req.user.tenant_id || null],
    );
    const reverseContactInfo =
      reverseContactInfoQ.rowCount > 0 ? reverseContactInfoQ.rows[0] : null;

    const reverseAliasName = await getDirectAliasForViewer(
      client,
      peer.id,
      req.user.id,
      req.user.tenant_id || null,
    );
    const requesterCard = await getDirectUserCard(
      client,
      req.user.id,
      req.user.tenant_id || null,
    );
    const requestState = directRequestStatusForViewer(chat.settings, req.user.id);
    const requesterChat = buildDirectChatPayloadForViewer(
      chat,
      peer,
      contactInfo?.alias_name || "",
    );
    const peerChat = buildDirectChatPayloadForViewer(
      chat,
      requesterCard,
      reverseAliasName,
    );

    await client.query("COMMIT");

    const io = req.app.get("io");
    if (io) {
      if (created) {
        emitToUser(io, req.user?.id, "chat:created", {
          chatId: chat.id,
          chat: requesterChat,
        });
        emitToUser(io, peer.id, "chat:created", {
          chatId: chat.id,
          chat: peerChat,
        });
      }
      if (requestCreated && requestRecord) {
        emitToUser(io, peer.id, "chat:direct_request_created", {
          request_id: requestRecord.id,
          chat_id: chat.id,
          requester: mapPeerInfo({
            ...requesterCard,
            role: req.user?.role || "",
            alias_name: reverseContactInfo?.alias_name || "",
            is_in_contacts: Boolean(reverseContactInfo),
            contact_created_at: reverseContactInfo?.created_at || null,
            contact_updated_at: reverseContactInfo?.updated_at || null,
          }),
          chat: peerChat,
        });
      }
      emitToUser(io, req.user?.id, "chat:updated", {
        chatId: chat.id,
        chat: requesterChat,
      });
      emitToUser(io, peer.id, "chat:updated", {
        chatId: chat.id,
        chat: peerChat,
      });
    }

    return res.json({
      ok: true,
      data: {
        chat: requesterChat,
        peer: mapPeerInfo({
          ...peer,
          alias_name: contactInfo?.alias_name || "",
          is_in_contacts: Boolean(contactInfo),
          contact_created_at: contactInfo?.created_at || null,
          contact_updated_at: contactInfo?.updated_at || null,
        }),
        created,
        request_created: requestCreated,
        request_status: requestState?.status || "accepted",
      },
    });
  } catch (err) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {}
    console.error("chats.direct.open error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  } finally {
    client.release();
  }
});

router.get("/direct/requests", requireAuth, async (req, res) => {
  const client = await db.pool.connect();
  try {
    const rows = await client.query(
      `SELECT dmr.id,
              dmr.chat_id,
              dmr.requester_id,
              dmr.target_user_id,
              dmr.status,
              dmr.cooldown_until,
              dmr.created_at,
              dmr.updated_at,
              c.title,
              c.type,
              c.settings,
              u.name,
              u.role,
              u.email,
              p.phone,
              u.avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS avatar_zoom
       FROM direct_message_requests dmr
       JOIN chats c ON c.id = dmr.chat_id
       JOIN users u ON u.id = dmr.requester_id
       LEFT JOIN phones p ON p.user_id = u.id
       WHERE dmr.target_user_id = $1
         AND dmr.status = 'pending'
         AND ($2::uuid IS NULL OR dmr.tenant_id = $2::uuid)
       ORDER BY dmr.updated_at DESC, dmr.created_at DESC`,
      [req.user.id, req.user.tenant_id || null],
    );
    const data = rows.rows.map((row) => ({
      id: row.id,
      chat_id: row.chat_id,
      status: row.status,
      cooldown_until: row.cooldown_until || null,
      created_at: row.created_at,
      updated_at: row.updated_at,
      requester: mapPeerInfo({
        ...row,
        is_in_contacts: false,
        alias_name: "",
      }),
      chat: buildDirectChatPayloadForViewer(
        {
          id: row.chat_id,
          title: row.title,
          type: row.type,
          settings: row.settings,
          created_at: row.created_at,
          updated_at: row.updated_at,
        },
        row,
        "",
      ),
    }));
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("chats.direct.requests.list error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  } finally {
    client.release();
  }
});

async function updateDirectRequestStatus({
  client,
  requestId,
  viewer,
  nextStatus,
}) {
  const requestQ = await client.query(
    `SELECT id,
            tenant_id,
            chat_id,
            requester_id,
            target_user_id,
            status,
            first_message_id,
            cooldown_until,
            responded_at,
            created_at,
            updated_at
     FROM direct_message_requests
     WHERE id = $1
       AND target_user_id = $2
       AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
     LIMIT 1
     FOR UPDATE`,
    [requestId, viewer.id, viewer.tenant_id || null],
  );
  if (requestQ.rowCount === 0) {
    return { error: "not_found" };
  }
  const request = requestQ.rows[0];
  if (request.status !== "pending") {
    return { error: "not_pending", request };
  }
  const cooldownUntil =
    nextStatus === "declined"
      ? new Date(
          Date.now() + DIRECT_REQUEST_COOLDOWN_HOURS * 60 * 60 * 1000,
        ).toISOString()
      : null;
  const chatSettingsPatch =
    nextStatus === "accepted"
      ? {
          direct_request_id: request.id,
          direct_request_status: "accepted",
          direct_request_pending_for: null,
          direct_request_first_message_sent: request.first_message_id != null,
        }
      : {
          direct_request_id: request.id,
          direct_request_status: "declined",
          direct_request_pending_for: String(viewer.id || "").trim(),
          direct_request_first_message_sent: request.first_message_id != null,
        };
  const updatedRequest = await client.query(
    `UPDATE direct_message_requests
     SET status = $2,
         cooldown_until = $3,
         responded_at = now(),
         updated_at = now()
     WHERE id = $1
     RETURNING id,
               tenant_id,
               chat_id,
               requester_id,
               target_user_id,
               status,
               first_message_id,
               cooldown_until,
               responded_at,
               created_at,
               updated_at`,
    [requestId, nextStatus, cooldownUntil],
  );
  await client.query(
    `UPDATE chats
     SET settings = settings || $2::jsonb,
         updated_at = now()
     WHERE id = $1`,
    [request.chat_id, JSON.stringify(chatSettingsPatch)],
  );
  if (nextStatus === "declined") {
    await client.query(
      `INSERT INTO user_chat_preferences (
         user_id, chat_id, hidden, pinned, pinned_at, created_at, updated_at
       )
       VALUES ($1, $2, true, false, NULL, now(), now())
       ON CONFLICT (user_id, chat_id)
       DO UPDATE
         SET hidden = true,
             updated_at = now()`,
      [viewer.id, request.chat_id],
    );
  }
  return { request: updatedRequest.rows[0] };
}

router.post("/direct/requests/:id/accept", requireAuth, async (req, res) => {
  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    const updated = await updateDirectRequestStatus({
      client,
      requestId: String(req.params?.id || "").trim(),
      viewer: req.user,
      nextStatus: "accepted",
    });
    if (updated.error === "not_found") {
      await client.query("ROLLBACK");
      return res.status(404).json({ ok: false, error: "Запрос не найден" });
    }
    if (updated.error === "not_pending") {
      await client.query("ROLLBACK");
      return res.status(409).json({ ok: false, error: "Запрос уже обработан" });
    }
    const chatQ = await client.query(
      `SELECT id, title, type, settings, created_at, updated_at
       FROM chats
       WHERE id = $1
       LIMIT 1`,
      [updated.request.chat_id],
    );
    const requesterCard = await getDirectUserCard(
      client,
      updated.request.requester_id,
      req.user.tenant_id || null,
    );
    const aliasName = await getDirectAliasForViewer(
      client,
      req.user.id,
      updated.request.requester_id,
      req.user.tenant_id || null,
    );
    const chatPayload = buildDirectChatPayloadForViewer(
      chatQ.rows[0],
      requesterCard,
      aliasName,
    );
    const accepterCard = await getDirectUserCard(
      client,
      updated.request.target_user_id,
      req.user.tenant_id || null,
    );
    const requesterAlias = await getDirectAliasForViewer(
      client,
      updated.request.requester_id,
      updated.request.target_user_id,
      req.user.tenant_id || null,
    );
    const requesterChatPayload = buildDirectChatPayloadForViewer(
      chatQ.rows[0],
      accepterCard,
      requesterAlias,
    );
    await client.query("COMMIT");

    const io = req.app.get("io");
    if (io) {
      emitToUser(io, updated.request.target_user_id, "chat:direct_request_updated", {
        request_id: updated.request.id,
        chat_id: updated.request.chat_id,
        status: updated.request.status,
      });
      emitToUser(io, updated.request.requester_id, "chat:direct_request_updated", {
        request_id: updated.request.id,
        chat_id: updated.request.chat_id,
        status: updated.request.status,
      });
      emitToUser(io, updated.request.target_user_id, "chat:updated", {
        chatId: updated.request.chat_id,
        chat: chatPayload,
      });
      emitToUser(io, updated.request.requester_id, "chat:updated", {
        chatId: updated.request.chat_id,
        chat: requesterChatPayload,
      });
    }
    return res.json({ ok: true, data: { request: updated.request, chat: chatPayload } });
  } catch (err) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {}
    console.error("chats.direct.requests.accept error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  } finally {
    client.release();
  }
});

router.post("/direct/requests/:id/decline", requireAuth, async (req, res) => {
  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    const updated = await updateDirectRequestStatus({
      client,
      requestId: String(req.params?.id || "").trim(),
      viewer: req.user,
      nextStatus: "declined",
    });
    if (updated.error === "not_found") {
      await client.query("ROLLBACK");
      return res.status(404).json({ ok: false, error: "Запрос не найден" });
    }
    if (updated.error === "not_pending") {
      await client.query("ROLLBACK");
      return res.status(409).json({ ok: false, error: "Запрос уже обработан" });
    }
    const chatQ = await client.query(
      `SELECT id, title, type, settings, created_at, updated_at
       FROM chats
       WHERE id = $1
       LIMIT 1`,
      [updated.request.chat_id],
    );
    const accepterCard = await getDirectUserCard(
      client,
      updated.request.target_user_id,
      req.user.tenant_id || null,
    );
    const requesterAlias = await getDirectAliasForViewer(
      client,
      updated.request.requester_id,
      updated.request.target_user_id,
      req.user.tenant_id || null,
    );
    const requesterChatPayload = buildDirectChatPayloadForViewer(
      chatQ.rows[0],
      accepterCard,
      requesterAlias,
    );
    await client.query("COMMIT");
    const io = req.app.get("io");
    if (io) {
      emitToUser(io, updated.request.target_user_id, "chat:direct_request_updated", {
        request_id: updated.request.id,
        chat_id: updated.request.chat_id,
        status: updated.request.status,
        cooldown_until: updated.request.cooldown_until || null,
      });
      emitToUser(io, updated.request.requester_id, "chat:direct_request_updated", {
        request_id: updated.request.id,
        chat_id: updated.request.chat_id,
        status: updated.request.status,
        cooldown_until: updated.request.cooldown_until || null,
      });
      emitToUser(io, updated.request.requester_id, "chat:updated", {
        chatId: updated.request.chat_id,
        chat: requesterChatPayload,
      });
    }
    return res.json({ ok: true, data: updated.request });
  } catch (err) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {}
    console.error("chats.direct.requests.decline error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  } finally {
    client.release();
  }
});

router.get("/:chatId/contact-card", requireAuth, async (req, res) => {
  const userId = req.user.id;
  const role = req.user.role;
  const { chatId } = req.params;
  try {
    const context = await getChatAccessContext(chatId, userId, req.user.tenant_id);
    if (!context) {
      return res.status(404).json({ ok: false, error: "Chat not found" });
    }
    const permissionSet = await resolvePermissionSet(req.user, db);
    if (!canReadChat(context, role, permissionSet.permissions)) {
      return res.status(403).json({ ok: false, error: "Нет доступа к чату" });
    }

    if (isSavedMessagesSettings(context.settings)) {
      const directRequest = await findDirectRequestByChatId(db.pool, chatId);
      const selfCard = await getDirectUserCard(
        db.pool,
        req.user.id,
        req.user.tenant_id || null,
      );
      return res.json({
        ok: true,
        data: {
          is_saved_messages: true,
          request_id: directRequest?.id || null,
          peer: mapPeerInfo({
            ...selfCard,
            alias_name: "",
            is_in_contacts: true,
          }),
          shared_media_count: 0,
          shared_file_count: 0,
        },
      });
    }

    if (!isDirectMessageSettings(context.settings)) {
      return res.status(400).json({
        ok: false,
        error: "Карточка контакта доступна только для личных чатов",
      });
    }

    const directRequest = await findDirectRequestByChatId(db.pool, chatId);

    const peerQ = await db.query(
      `SELECT u.id,
              u.email,
              u.name,
              u.role,
              u.tenant_id,
              p.phone,
              u.avatar_url,
              COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
              COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
              COALESCE(u.avatar_zoom, 1) AS avatar_zoom,
              uc.alias_name,
              uc.created_at AS contact_created_at,
              uc.updated_at AS contact_updated_at,
              (uc.user_id IS NOT NULL) AS is_in_contacts
       FROM chat_members cm
       JOIN users u ON u.id = cm.user_id
       LEFT JOIN phones p ON p.user_id = u.id
       LEFT JOIN user_contacts uc
         ON uc.user_id = $1
        AND uc.contact_user_id = u.id
        AND ($3::uuid IS NULL OR uc.tenant_id = $3::uuid)
       WHERE cm.chat_id = $2
         AND cm.user_id <> $1
       ORDER BY cm.joined_at ASC
       LIMIT 1`,
      [userId, chatId, req.user.tenant_id || null],
    );
    if (peerQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Собеседник не найден" });
    }
    const mediaStatsQ = await db.query(
      `SELECT COUNT(*) FILTER (
                WHERE EXISTS (
                  SELECT 1
                  FROM message_attachments ma
                  WHERE ma.message_id = m.id
                    AND ma.attachment_type IN ('image', 'video')
                )
                OR COALESCE(m.meta->>'image_url', '') <> ''
                OR COALESCE(m.meta->>'video_url', '') <> ''
              )::int AS shared_media_count,
              COUNT(*) FILTER (
                WHERE EXISTS (
                  SELECT 1
                  FROM message_attachments ma
                  WHERE ma.message_id = m.id
                    AND ma.attachment_type = 'file'
                )
                OR COALESCE(m.meta->>'file_url', '') <> ''
              )::int AS shared_file_count
       FROM messages m
       WHERE m.chat_id = $1`,
      [chatId],
    );
    return res.json({
      ok: true,
      data: {
        is_saved_messages: false,
        request_id: directRequest?.id || null,
        peer: mapPeerInfo(peerQ.rows[0], { includeEmail: true }),
        shared_media_count:
          Number(mediaStatsQ.rows[0]?.shared_media_count || 0) || 0,
        shared_file_count:
          Number(mediaStatsQ.rows[0]?.shared_file_count || 0) || 0,
      },
    });
  } catch (err) {
    console.error("chats.contactCard error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

// Members management endpoints
router.get("/:chatId/members", requireAuth, async (req, res) => {
  try {
    const { chatId } = req.params;
    const q = await db.query(
      `SELECT u.id as user_id, u.email, cm.role, cm.joined_at
       FROM users u
       JOIN chat_members cm ON cm.user_id = u.id
       WHERE cm.chat_id = $1
       ORDER BY cm.joined_at ASC`,
      [chatId],
    );
    return res.json({ ok: true, data: q.rows });
  } catch (err) {
    console.error("chats.members.list error", err);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

router.post(
  "/:chatId/members",
  requireAuth,
  requireChatPermission(["owner", "moderator"]),
  async (req, res) => {
    const { chatId } = req.params;
    const { userId, role = "member" } = req.body || {};
    if (!userId)
      return res.status(400).json({ ok: false, error: "userId required" });

    try {
      await db.query(
        `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1,$2,$3,now(),$4)
       ON CONFLICT (chat_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
        [uuidv4(), chatId, userId, role],
      );
      return res.status(201).json({ ok: true });
    } catch (err) {
      console.error("chats.members.add error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.delete(
  "/:chatId/members/:userId",
  requireAuth,
  requireChatPermission(["owner", "moderator"]),
  async (req, res) => {
    const { chatId, userId } = req.params;
    try {
      await db.query(
        "DELETE FROM chat_members WHERE chat_id=$1 AND user_id=$2",
        [chatId, userId],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("chats.members.delete error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

router.patch(
  "/:chatId/members/:userId/role",
  requireAuth,
  requireChatPermission(["owner"]),
  async (req, res) => {
    const { chatId, userId } = req.params;
    const { role } = req.body || {};
    if (!role)
      return res.status(400).json({ ok: false, error: "role required" });
    try {
      await db.query(
        "UPDATE chat_members SET role=$1 WHERE chat_id=$2 AND user_id=$3",
        [role, chatId, userId],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("chats.members.role error", err);
      return res.status(500).json({ ok: false, error: "Server error" });
    }
  },
);

module.exports = router;
