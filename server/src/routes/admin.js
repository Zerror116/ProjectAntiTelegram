// server/src/routes/admin.js
const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const requirePermission = require("../middleware/requirePermission");
const db = require("../db");
const { ensureSystemChannels, insertAdminSystemMessage } = require("../utils/systemChannels");
const {
  generateAccessKey,
  generateInviteCode,
  generateTenantCode,
  hashAccessKey,
  maskAccessKey,
  normalizeAccessKey,
  normalizeInviteCode,
} = require("../utils/tenants");
const {
  provisionIsolatedTenantDatabase,
  syncTenantShadowTenantState,
} = require("../utils/tenantDatabases");
const { logMonitoringEvent, monitoringEnabled } = require("../utils/monitoring");
const { emitToTenant } = require("../utils/socket");
const { emitCatalogQueueUpdated } = require("../utils/catalogQueueSocket");
const { antifraudGuard } = require("../utils/antifraud");
const {
  encryptMessageText,
  decryptMessageRow,
} = require("../utils/messageCrypto");
const { readEncryptedText } = require("../utils/secureData");
const { runInRequestTenantScope } = require("../utils/requestScope");
const { uploadsPath } = require("../utils/storagePaths");
const { registerPublicImageUpload } = require("../utils/publicMediaRegistration");
const { toOriginalPublicMediaUrl } = require("../utils/mediaAssets");
const { normalizeCatalogTitle } = require("../utils/catalogTitle");
const {
  getTenantFeatureSettings,
  patchTenantFeatureSettings,
} = require("../utils/tenantFeatureSettings");
const {
  DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS,
  enqueueChannelPublicationBatches,
  notifyChannelPublicationBatchesStarted,
  listActivePublicationBatches,
  buildPublicationSummary,
  getChannelPublicationBatch,
  kickChannelPublicationProcessor,
} = require("../utils/channelPublicationQueue");
const {
  upsertMessageSearchDocument,
} = require("../utils/chatSearchIndex");

const requireProductPublishPermission = requirePermission("product.publish");
const requireReservationFulfillPermission = requirePermission(
  "reservation.fulfill",
);
const PUBLISH_POST_INTERVAL_MS = DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS;
const SAMARA_TZ = "Europe/Samara";

function tenantIdFromRequest(req) {
  return String(req.user?.tenant_id || "").trim();
}

function emitChannelUpdated(io, tenantId, channelId, payload = {}) {
  if (!io || !channelId) return;
  emitToTenant(io, tenantId || null, "channel:updated", {
    entity: "channel",
    entity_id: String(channelId),
    channel_id: String(channelId),
    chatId: String(channelId),
    action: payload.action || "updated",
    ...payload,
  });
}

function emitChannelMembersUpdated(io, tenantId, channelId, payload = {}) {
  if (!io || !channelId) return;
  emitToTenant(io, tenantId || null, "channel:members:updated", {
    entity: "channel_members",
    entity_id: String(channelId),
    channel_id: String(channelId),
    chatId: String(channelId),
    action: payload.action || "updated",
    ...payload,
  });
}

function emitChannelMediaUpdated(io, tenantId, channelId, payload = {}) {
  if (!io || !channelId) return;
  emitToTenant(io, tenantId || null, "channel:media:updated", {
    entity: "channel_media",
    entity_id: String(channelId),
    channel_id: String(channelId),
    chatId: String(channelId),
    action: payload.action || "updated",
    ...payload,
  });
}

function emitReservedOrderUpdated(io, tenantId, reservedChannelId, payload = {}) {
  if (!io || !reservedChannelId) return;
  emitToTenant(io, tenantId || null, "reserved:order:updated", {
    entity: "reserved_order",
    entity_id:
      payload.message_id ||
      payload.messageId ||
      payload.reservation_id ||
      payload.cart_item_id ||
      String(reservedChannelId),
    channel_id: String(reservedChannelId),
    chatId: String(reservedChannelId),
    action: payload.action || "updated",
    ...payload,
  });
}

function buildRevisionDeleteDecisionText({ approved, productTitle, productLabel, adminName }) {
  const action = approved ? "одобрил удаление" : "отклонил удаление";
  return [
    `Ревизия: администратор ${adminName || "Администратор"} ${action} товара.`,
    `Товар: ${productTitle || "без названия"}`,
    `ID: ${productLabel || "—"}`,
  ].join("\n");
}

function firstLocalityLetterFromAddress(addressText, fallbackCity = "") {
  const source = String(addressText || fallbackCity || "").trim();
  if (!source) return "";
  const firstPart = source
    .split(",")[0]
    .replace(/^г\.?\s+/i, "")
    .replace(/^город\s+/i, "")
    .trim();
  if (!firstPart) return "";
  return firstPart[0].toUpperCase();
}

function buildChannelClientExcelRow(row) {
  const deliveryAddress = readEncryptedText({
    address_text: row.delivery_address_text,
    address_ciphertext: row.delivery_address_ciphertext,
    address_iv: row.delivery_address_iv,
    address_tag: row.delivery_address_tag,
  });
  const savedAddress = readEncryptedText({
    address_text: row.saved_address_text,
    address_ciphertext: row.saved_address_ciphertext,
    address_iv: row.saved_address_iv,
    address_tag: row.saved_address_tag,
  });
  const effectiveAddress = deliveryAddress || savedAddress || "";
  const deliverySum = Number(row.delivery_sum || 0);
  const cartSum = Number(row.cart_sum || 0);
  const deliveryShelfLabel = String(row.delivery_shelf_label || "").trim();
  const deliveryShelfNumber = row.delivery_shelf_number == null
    ? ""
    : String(row.delivery_shelf_number).trim();
  const shelfLabel = deliveryShelfLabel ||
    deliveryShelfNumber ||
    (row.shelf_number == null ? "" : String(row.shelf_number).trim());
  const bulkyText = String(row.delivery_bulky_note || row.cart_bulky_titles || "").trim();
  const hasDeliveryRow = row.delivery_customer_id != null;
  return {
    total_sum: Number.isFinite(deliverySum) && deliverySum > 0 ? deliverySum : cartSum,
    delivery_address_text: deliveryAddress,
    saved_address_text: savedAddress,
    effective_address_text: effectiveAddress,
    courier_name: String(row.courier_name || "").trim(),
    locality_letter: firstLocalityLetterFromAddress(
      effectiveAddress,
      row.client_city,
    ),
    bulky_text: bulkyText,
    shelf_label: shelfLabel,
    package_places: hasDeliveryRow && row.package_places != null
      ? Number(row.package_places) || null
      : null,
  };
}

router.get(
  "/tenant/feature-settings",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  async (req, res) => {
    const tenantId = tenantIdFromRequest(req);
    if (!tenantId) {
      return res.status(403).json({
        ok: false,
        error: "Аккаунт не привязан к группе арендатора",
      });
    }
    try {
      const settings = await getTenantFeatureSettings(tenantId);
      return res.json({ ok: true, data: settings });
    } catch (err) {
      console.error("admin.tenant.featureSettings.get error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenant/feature-settings",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  async (req, res) => {
    const tenantId = tenantIdFromRequest(req);
    if (!tenantId) {
      return res.status(403).json({
        ok: false,
        error: "Аккаунт не привязан к группе арендатора",
      });
    }
    try {
      const settings = await patchTenantFeatureSettings(tenantId, req.body || {});
      emitToTenant(req.app.get("io"), tenantId, "tenant:feature-settings:updated", {
        entity: "tenant_feature_settings",
        entity_id: tenantId,
        action: "updated",
        settings,
      });
      return res.json({ ok: true, data: settings });
    } catch (err) {
      console.error("admin.tenant.featureSettings.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/revision/delete-requests",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  async (req, res) => {
    const tenantId = tenantIdFromRequest(req) || null;
    try {
      const settings = await getTenantFeatureSettings(tenantId);
      if (settings.revision_delete_approval_enabled !== true) {
        return res.json({ ok: true, enabled: false, data: [] });
      }
      const result = await db.query(
        `SELECT r.id,
                r.tenant_id,
                r.worker_id,
                r.product_id,
                r.queue_id,
                r.channel_id,
                r.reason,
                r.status,
                r.decided_by,
                r.decided_at,
                r.created_at,
                r.updated_at,
                p.title AS product_title,
                p.product_code,
                p.shelf_number,
                p.manual_shelf_label,
                p.image_url,
                COALESCE(NULLIF(BTRIM(w.name), ''), NULLIF(BTRIM(w.email), ''), 'Рабочий') AS worker_name,
                COALESCE(NULLIF(BTRIM(a.name), ''), NULLIF(BTRIM(a.email), ''), '') AS decided_by_name,
                c.title AS channel_title
         FROM revision_delete_requests r
         LEFT JOIN products p ON p.id = r.product_id
         LEFT JOIN users w ON w.id = r.worker_id
         LEFT JOIN users a ON a.id = r.decided_by
         LEFT JOIN chats c ON c.id = r.channel_id
         WHERE ($1::uuid IS NULL OR r.tenant_id = $1::uuid)
         ORDER BY CASE r.status WHEN 'pending' THEN 0 ELSE 1 END,
                  r.created_at DESC
         LIMIT 120`,
        [tenantId],
      );
      return res.json({ ok: true, enabled: true, data: result.rows });
    } catch (err) {
      console.error("admin.revision.deleteRequests.list error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/revision/delete-requests/:requestId/decision",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  async (req, res) => {
    const requestId = String(req.params?.requestId || "").trim();
    const rawDecision = String(req.body?.decision || req.body?.status || "")
      .trim()
      .toLowerCase();
    const approved = ["approve", "approved", "yes", "true", "да"].includes(rawDecision);
    const rejected = ["reject", "rejected", "no", "false", "нет"].includes(rawDecision);
    if (!isUuidLike(requestId)) {
      return res.status(400).json({ ok: false, error: "Некорректный id запроса" });
    }
    if (!approved && !rejected) {
      return res.status(400).json({ ok: false, error: "Укажите решение: approved или rejected" });
    }

    const tenantId = tenantIdFromRequest(req) || null;
    const client = await db.pool.connect();
    let hiddenMessages = [];
    let affectedChannelIds = new Set();
    let requestRow = null;
    try {
      const settings = await getTenantFeatureSettings(tenantId);
      if (settings.revision_delete_approval_enabled !== true) {
        return res.status(403).json({
          ok: false,
          error: "Удаление через ревизию недоступно для этой группы",
        });
      }

      await client.query("BEGIN");
      const requestQ = await client.query(
        `SELECT r.*,
                p.title AS product_title,
                p.product_code,
                p.shelf_number,
                p.image_url,
                COALESCE(NULLIF(BTRIM(a.name), ''), NULLIF(BTRIM(a.email), ''), 'Администратор') AS admin_name
         FROM revision_delete_requests r
         LEFT JOIN products p ON p.id = r.product_id
         LEFT JOIN users a ON a.id = $3::uuid
         WHERE r.id = $1::uuid
           AND ($2::uuid IS NULL OR r.tenant_id = $2::uuid)
         LIMIT 1
         FOR UPDATE`,
        [requestId, tenantId, req.user.id],
      );
      if (requestQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Запрос не найден" });
      }
      requestRow = requestQ.rows[0];
      if (String(requestRow.status || "") !== "pending") {
        await client.query("ROLLBACK");
        return res.status(409).json({ ok: false, error: "По этому запросу уже принято решение" });
      }

      const productLabel = formatProductLabel(
        requestRow.product_code,
        requestRow.shelf_number,
        requestRow.manual_shelf_label,
      );

      if (approved) {
        await client.query(
          `UPDATE products
           SET status = 'archived',
               quantity = 0,
               reusable_at = now(),
               updated_at = now()
           WHERE id = $1::uuid`,
          [requestRow.product_id],
        );
        await client.query(
          `UPDATE product_publication_queue
           SET status = 'archived',
               is_sent = true,
               publish_error_code = 'revision_delete_approved',
               publish_error_message = 'Удалено администратором по запросу ревизии'
           WHERE product_id = $1::uuid
             AND status = 'pending'
             AND COALESCE(is_sent, false) = false`,
          [requestRow.product_id],
        );
        const hiddenQ = await client.query(
          `UPDATE messages
           SET meta = jsonb_set(
                 jsonb_set(
                   jsonb_set(
                     COALESCE(meta, '{}'::jsonb),
                     '{hidden_for_all}',
                     'true'::jsonb,
                     true
                   ),
                   '{hidden_revision_delete_approved}',
                   'true'::jsonb,
                   true
                 ),
                 '{hidden_revision_delete_request_id}',
                 to_jsonb($2::text),
                 true
               )
           WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
             AND COALESCE(meta->>'product_id', '') = $1::text
             AND ($3::uuid IS NULL OR chat_id = $3::uuid)
             AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [requestRow.product_id, requestId, requestRow.channel_id || null],
        );
        hiddenMessages = hiddenQ.rows;
        for (const message of hiddenMessages) {
          if (message.chat_id) affectedChannelIds.add(String(message.chat_id));
        }
      }

      const decisionStatus = approved ? "approved" : "rejected";
      const updatedQ = await client.query(
        `UPDATE revision_delete_requests
         SET status = $2,
             decided_by = $3::uuid,
             decided_at = now(),
             updated_at = now()
         WHERE id = $1::uuid
         RETURNING id, tenant_id, worker_id, product_id, queue_id, channel_id,
                   reason, status, decided_by, decided_at, created_at, updated_at`,
        [requestId, decisionStatus, req.user.id],
      );
      const updatedRequest = updatedQ.rows[0];

      await insertAdminSystemMessage(client, {
        tenantId,
        createdBy: req.user.id,
        text: buildRevisionDeleteDecisionText({
          approved,
          productTitle: requestRow.product_title,
          productLabel,
          adminName: requestRow.admin_name,
        }),
        meta: {
          kind: "revision_delete_decision",
          request_id: requestId,
          product_id: requestRow.product_id,
          channel_id: requestRow.channel_id || null,
          decision: decisionStatus,
          product_label: productLabel,
          action: "revision_delete_decision",
        },
        dedupeKey: `revision_delete_decision:${requestId}:${decisionStatus}`,
      });

      if (requestRow.channel_id) {
        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          requestRow.channel_id,
        ]);
        affectedChannelIds.add(String(requestRow.channel_id));
      }
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const message of hiddenMessages) {
          io.to(`chat:${message.chat_id}`).emit("chat:message", {
            chatId: message.chat_id,
            message: decryptMessageRow(message),
          });
        }
        for (const channelId of affectedChannelIds) {
          emitToTenant(io, tenantId, "chat:updated", { chatId: channelId });
        }
        emitCatalogQueueUpdated(io, tenantId, {
          action: approved ? "revision_delete_approved" : "revision_delete_rejected",
          product_id: requestRow.product_id,
          request_id: requestId,
          channel_id: requestRow.channel_id || null,
        });
        emitToTenant(io, tenantId, "revision:delete-request:updated", {
          entity: "revision_delete_request",
          entity_id: requestId,
          action: decisionStatus,
          request: updatedRequest,
        });
      }

      return res.json({
        ok: true,
        data: {
          request: updatedRequest,
          hidden_messages: hiddenMessages.length,
        },
      });
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      console.error("admin.revision.deleteRequests.decision error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.get(
  "/defects/stats",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  async (req, res) => {
    const tenantId = tenantIdFromRequest(req) || null;
    try {
      const settings = await getTenantFeatureSettings(tenantId);
      if (settings.defect_stats_enabled !== true) {
        return res.json({
          ok: true,
          enabled: false,
          data: {
            items: [],
            counts: { week: 0, two_weeks: 0, month: 0, total: 0 },
          },
        });
      }
      const result = await db.query(
        `WITH defect_rows AS (
           SELECT d.id,
                  d.tenant_id,
                  d.product_id,
                  d.created_at,
                  d.title,
                  d.reason,
                  d.image_url,
                  d.amount,
                  COALESCE(NULLIF(BTRIM(author.name), ''), NULLIF(BTRIM(author.email), ''), '') AS uploader_name,
                  'defect_report'::text AS source
           FROM product_defect_reports d
           LEFT JOIN users author ON author.id = d.created_by
           WHERE d.status = 'active'
             AND ($1::uuid IS NULL OR d.tenant_id = $1::uuid)
           UNION ALL
           SELECT cc.id,
                  cc.tenant_id,
                  cc.product_id,
                  cc.created_at,
                  COALESCE(NULLIF(BTRIM(p.title), ''), 'Товар') AS title,
                  COALESCE(NULLIF(BTRIM(cc.description), ''), cc.claim_type) AS reason,
                  COALESCE(NULLIF(BTRIM(cc.image_url), ''), NULLIF(BTRIM(p.image_url), '')) AS image_url,
                  GREATEST(COALESCE(cc.approved_amount, 0), COALESCE(cc.requested_amount, 0)) AS amount,
                  COALESCE(NULLIF(BTRIM(author.name), ''), NULLIF(BTRIM(author.email), ''), '') AS uploader_name,
                  'customer_claim'::text AS source
           FROM customer_claims cc
           LEFT JOIN products p ON p.id = cc.product_id
           LEFT JOIN users author ON author.id = p.created_by
           WHERE cc.status IN ('pending', 'approved_return', 'approved_discount', 'settled')
             AND ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
         )
         SELECT id,
                tenant_id,
                product_id,
                created_at,
                title,
                reason,
                image_url,
                amount,
                uploader_name,
                source,
                COUNT(*) FILTER (WHERE created_at >= now() - interval '7 days') OVER ()::int AS week_count,
                COUNT(*) FILTER (WHERE created_at >= now() - interval '14 days') OVER ()::int AS two_weeks_count,
                COUNT(*) FILTER (WHERE created_at >= now() - interval '30 days') OVER ()::int AS month_count,
                COUNT(*) OVER ()::int AS total_count
         FROM defect_rows
         ORDER BY created_at DESC
         LIMIT 200`,
        [tenantId],
      );
      const first = result.rows[0] || {};
      return res.json({
        ok: true,
        enabled: true,
        data: {
          counts: {
            week: Number(first.week_count || 0),
            two_weeks: Number(first.two_weeks_count || 0),
            month: Number(first.month_count || 0),
            total: Number(first.total_count || 0),
          },
          items: result.rows.map((row) => ({
            id: row.id,
            tenant_id: row.tenant_id,
            product_id: row.product_id,
            created_at: row.created_at,
            title: row.title,
            reason: row.reason,
            image_url: row.image_url,
            amount: Number(row.amount || 0),
            uploader_name: row.uploader_name || "",
            uploaded_by_name: row.uploader_name || "",
            source_label:
              row.source === "customer_claim" ? "Возврат клиента" : "Брак",
            source: row.source,
          })),
        },
      });
    } catch (err) {
      console.error("admin.defects.stats error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);
const TENANT_ACCESS_KEY_PATTERN = /^[A-Z]{3}-[A-Z0-9]{1,32}-KEY$/;

function buildIsolatedProvisionWarning(err) {
  const code = String(err?.code || "").trim();
  if (code === "42501") {
    return "Не удалось создать отдельную БД (проверьте CREATEDB). Арендатор переведен в schema-isolated режим.";
  }
  if (code === "23503") {
    return "Изоляция создана частично, но не удалось связать служебные данные. Требуется ручная проверка арендатора.";
  }
  return "Изолированная БД не создана. Включен безопасный fallback.";
}

function emitTenantSubscriptionUpdate(io, tenantId, row, source = "admin") {
  if (!io) return;
  const targetTenantId = String(tenantId || row?.id || "").trim();
  if (!targetTenantId) return;
  emitToTenant(io, targetTenantId, "tenant:subscription:update", {
    tenant_id: targetTenantId,
    status: row?.status || null,
    subscription_expires_at: row?.subscription_expires_at || null,
    source,
    at: new Date().toISOString(),
  });
}

async function syncTenantShadowStateForAdmin(row, source = "admin") {
  try {
    return await syncTenantShadowTenantState(row);
  } catch (err) {
    console.error(`admin.tenants.${source}.shadowSync error`, err);
    return {
      synced: false,
      reason: "shadow_sync_failed",
      row_count: 0,
      error: String(err?.message || err || "unknown_error"),
    };
  }
}

function serializeTenantAdminRow(row, extra = {}) {
  if (!row || typeof row !== "object") return extra;
  const {
    db_url: _dbUrl,
    db_mode: _dbMode,
    db_name: _dbName,
    db_schema: _dbSchema,
    ...safeRow
  } = row;
  return {
    ...safeRow,
    ...extra,
  };
}

const channelUploadsDir = uploadsPath("channels");
const productUploadsDir = uploadsPath("products");
fs.mkdirSync(channelUploadsDir, { recursive: true });
fs.mkdirSync(productUploadsDir, { recursive: true });

const channelAvatarUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, channelUploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : ".jpg";
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const mime = String(file.mimetype || "").toLowerCase().trim();
    const ext = path.extname(String(file.originalname || "")).toLowerCase();
    const allowedExt = new Set([
      ".jpg",
      ".jpeg",
      ".png",
      ".gif",
      ".webp",
      ".bmp",
      ".heic",
      ".heif",
    ]);
    const isImageMime = mime.startsWith("image/");
    const isOctetImage = mime === "application/octet-stream" && allowedExt.has(ext);
    if (isImageMime || isOctetImage) {
      cb(null, true);
      return;
    }
    cb(new Error("Можно загружать только изображения"));
  },
});

function uploadChannelAvatar(req, res, next) {
  channelAvatarUpload.single("avatar")(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === "LIMIT_FILE_SIZE") {
      return res
        .status(400)
        .json({ ok: false, error: "Размер фото не должен превышать 8MB" });
    }
    return res
      .status(400)
      .json({ ok: false, error: err.message || "Некорректный файл" });
  });
}

function toChannelAvatarUrl(req, file) {
  if (!file || !file.filename) return null;
  return `${req.protocol}://${req.get("host")}/uploads/channels/${file.filename}`;
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function removeChannelAvatarByUrl(raw) {
  const url = String(raw || "").trim();
  if (!url) return;
  const marker = "/uploads/channels/";
  const idx = url.indexOf(marker);
  if (idx === -1) return;
  const filename = url.slice(idx + marker.length).split(/[?#]/)[0].trim();
  if (!filename) return;
  const fullPath = path.join(channelUploadsDir, filename);
  if (!fullPath.startsWith(channelUploadsDir)) return;
  fs.unlink(fullPath, () => {});
}

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function normalizePhoneDigits(raw) {
  return String(raw || "").replace(/\D/g, "").slice(0, 20);
}

async function acquireReservationOperationLock(
  client,
  { reservationId = null, cartItemId = null, tenantId = null } = {},
) {
  const normalizedReservationId = String(reservationId || "").trim();
  const normalizedCartItemId = String(cartItemId || "").trim();
  let lockKey = normalizedCartItemId;

  if (!lockKey && normalizedReservationId) {
    const lockKeyQ = await client.query(
      `SELECT COALESCE(r.cart_item_id::text, r.id::text) AS lock_key
       FROM reservations r
       JOIN users buyer ON buyer.id = r.user_id
       WHERE (
         ($1::uuid IS NOT NULL AND r.id = $1::uuid)
         OR
         ($1::uuid IS NULL AND $2::uuid IS NOT NULL AND r.cart_item_id = $2::uuid)
       )
         AND ($3::uuid IS NULL OR buyer.tenant_id = $3::uuid)
       ORDER BY r.created_at DESC
       LIMIT 1`,
      [normalizedReservationId || null, normalizedCartItemId || null, tenantId || null],
    );
    if (lockKeyQ.rowCount > 0) {
      lockKey = String(lockKeyQ.rows[0]?.lock_key || "").trim();
    }
  }

  if (!lockKey) {
    lockKey = normalizedReservationId || normalizedCartItemId;
  }
  if (!lockKey) return null;

  await client.query(
    `SELECT pg_advisory_xact_lock(hashtext($1), 0)`,
    [`reservation-op:${lockKey}`],
  );
  return lockKey;
}

function formatPhoneForDisplay(raw) {
  const digits = normalizePhoneDigits(raw);
  if (digits.length === 10) return `8${digits}`;
  if (digits.length === 11) {
    if (digits.startsWith("8")) return digits;
    if (digits.startsWith("7")) return `8${digits.slice(1)}`;
  }
  return String(raw || "").trim() || "—";
}

function schedulePublishedMessages(io, published, tenantId = null) {
  if (!io || !Array.isArray(published) || published.length === 0) return;
  published.forEach((item, index) => {
    setTimeout(async () => {
      try {
        const msgRes = await db.query(
          "SELECT id, chat_id, sender_id, text, meta, created_at FROM messages WHERE id = $1 LIMIT 1",
          [item.message_id],
        );
        if (msgRes.rowCount === 0) return;
        io.to(`chat:${item.channel_id}`).emit("chat:message", {
          chatId: item.channel_id,
          message: decryptMessageRow(msgRes.rows[0]),
        });
        emitToTenant(io, tenantId, "chat:updated", { chatId: item.channel_id });
      } catch (err) {
        console.error("admin.publish_pending emit error", err);
      }
    }, index * PUBLISH_POST_INTERVAL_MS);
  });
}

function normalizeVisibility(value) {
  const v = String(value || "public")
    .toLowerCase()
    .trim();
  return v === "private" ? "private" : "public";
}

function isIsoDay(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || "").trim());
}

function clampNumber(value, min, max, fallback = 0) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}

function normalizeAvatarFocus(value, fallback = 0) {
  return clampNumber(value, -1, 1, fallback);
}

function normalizeAvatarZoom(value, fallback = 1) {
  return clampNumber(value, 1, 4, fallback);
}

const demoPlaceholderPngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAoAAAAHgCAYAAAA10dzkAAAACXBIWXMAAAsSAAALEgHS3X78AAAGnElEQVR4nO3UQQ0AIBDAsAP/nuGNAvZoFSzZOjM7AID3zA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDv7AFCiwL6geiJ2QAAAABJRU5ErkJggg==";

function ensureDemoProductImage(req) {
  const filename = "demo-placeholder.png";
  const target = path.join(productUploadsDir, filename);
  if (!fs.existsSync(target)) {
    fs.writeFileSync(target, Buffer.from(demoPlaceholderPngBase64, "base64"));
  }
  return `${req.protocol}://${req.get("host")}/uploads/products/${filename}`;
}

function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function isUuidLike(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    String(value || "").trim(),
  );
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function normalizeUuidList(raw) {
  if (!Array.isArray(raw)) return [];
  const unique = new Set();
  for (const item of raw) {
    const value = String(item || "").trim();
    if (!value || !isUuidLike(value)) continue;
    unique.add(value);
  }
  return Array.from(unique);
}

function parseSettingsStringList(raw) {
  if (!Array.isArray(raw)) return [];
  const unique = new Set();
  for (const item of raw) {
    const value = String(item || "").trim();
    if (!value) continue;
    unique.add(value);
  }
  return Array.from(unique);
}

function buildTenantWorkflowSettingsPayload(body = {}) {
  const source = isPlainObject(body) ? body : {};
  const payload = isPlainObject(source.workflow_settings)
    ? { ...source.workflow_settings }
    : {};
  if (Object.prototype.hasOwnProperty.call(source, "client_city_options")) {
    payload.registration = {
      ...(isPlainObject(payload.registration) ? payload.registration : {}),
      client_city_options: source.client_city_options,
    };
    payload.client_city_options = source.client_city_options;
  }
  return payload;
}

function isBugReportsTitle(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase() === "баг-репорты"
  );
}

function isMainSystemTitle(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase() === "основной канал"
  );
}

function isReservedSystemTitle(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase() === "забронированный товар"
  );
}

function normalizeBlacklistEntries(settings) {
  const entriesRaw = Array.isArray(settings?.blacklist_entries)
    ? settings.blacklist_entries
    : [];
  const fromIds = parseSettingsStringList(settings?.blacklisted_user_ids);

  const byUserId = new Map();

  for (const entry of entriesRaw) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const userId = String(entry.user_id || "").trim();
    if (!userId || !isUuidLike(userId)) continue;
    byUserId.set(userId, {
      user_id: userId,
      added_at: String(entry.added_at || "").trim() || new Date().toISOString(),
      added_by: String(entry.added_by || "").trim() || null,
      reason: String(entry.reason || "").trim(),
    });
  }

  for (const userId of fromIds) {
    if (byUserId.has(userId)) continue;
    byUserId.set(userId, {
      user_id: userId,
      added_at: new Date().toISOString(),
      added_by: null,
      reason: "",
    });
  }

  return Array.from(byUserId.values());
}

function applyBlacklistToSettings(settings, entries) {
  const nextEntries = normalizeBlacklistEntries({
    blacklist_entries: Array.isArray(entries) ? entries : [],
  });
  return {
    ...settings,
    blacklist_entries: nextEntries,
    blacklisted_user_ids: nextEntries.map((entry) => entry.user_id),
  };
}

function isChannelReadOnlySystemChannel(chatRow, settings) {
  const kind = String(settings?.kind || "")
    .toLowerCase()
    .trim();
  return (
    (kind && kind !== "channel") ||
    settings?.admin_only === true ||
    isBugReportsTitle(chatRow?.title)
  );
}

function productMessageText(product) {
  const lines = [
    `🛒 ${product.title}`,
    product.description ? String(product.description).trim() : null,
    `Цена: ${product.price} ₽`,
    `Количество в наличии: ${product.quantity}`,
    'Нажмите "Купить", чтобы добавить в корзину',
  ].filter(Boolean);
  return lines.join("\n");
}

function formatProductLabel(productCode, shelfNumber, manualShelfLabel = "") {
  const code = Number(productCode);
  const shelf = Number(shelfNumber);
  const codePart = Number.isFinite(code) && code > 0 ? String(Math.floor(code)) : "—";
  const manualShelf = String(manualShelfLabel || "").trim();
  const shelfPart = manualShelf || (
    Number.isFinite(shelf) && shelf > 0
      ? String(Math.floor(shelf)).padStart(2, "0")
      : "—"
  );
  return `${codePart}--${shelfPart}`;
}

function normalizeShelfLabel(raw) {
  const normalized = String(raw ?? "")
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) return null;
  return normalized.slice(0, 64);
}

function parsePositiveShelfNumber(raw) {
  const normalized = normalizeShelfLabel(raw);
  if (!normalized || !/^\d+$/.test(normalized)) return null;
  const parsed = Number(normalized);
  if (!Number.isFinite(parsed) || parsed <= 0) return null;
  return Math.floor(parsed);
}

function displayShelfValue(shelfLabel, shelfNumber) {
  const normalizedLabel = normalizeShelfLabel(shelfLabel);
  if (normalizedLabel) return normalizedLabel;
  const parsedShelf = Number(shelfNumber);
  if (Number.isFinite(parsedShelf)) {
    return String(Math.trunc(parsedShelf));
  }
  return "не назначена";
}

async function resolveAutoShelfNumber(
  client,
  tenantId = null,
  dateValue = null,
  fallback = 1,
) {
  const dayQ = await client.query(
    `SELECT to_char((COALESCE($1::timestamptz, now()) AT TIME ZONE $2)::date, 'YYYY-MM-DD') AS current_day`,
    [dateValue, SAMARA_TZ],
  );
  const currentDay = String(dayQ.rows[0]?.current_day || "").trim();
  if (!isIsoDay(currentDay)) return fallback;

  let startDay = currentDay;
  const mainQ = await client.query(
    `SELECT id, settings
     FROM chats
     WHERE type = 'channel'
       AND COALESCE(settings->>'system_key', '') = 'main_channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
     ORDER BY created_at ASC
     LIMIT 1
     FOR UPDATE`,
    [tenantId || null],
  );
  if (mainQ.rowCount > 0) {
    const main = mainQ.rows[0];
    const settings = normalizeSettings(main.settings);
    const savedStart = String(settings.shelf_cycle_start_day || "").trim();
    if (isIsoDay(savedStart)) {
      startDay = savedStart;
    } else {
      const nextSettings = {
        ...settings,
        shelf_cycle_start_day: currentDay,
      };
      await client.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2`,
        [JSON.stringify(nextSettings), main.id],
      );
      startDay = currentDay;
    }
  }

  const diffQ = await client.query(
    `SELECT GREATEST(0, COUNT(*)::int - 1) AS diff_days
     FROM generate_series($2::date, $1::date, interval '1 day') AS day(value)
     WHERE EXTRACT(ISODOW FROM day.value) < 7`,
    [currentDay, startDay],
  );
  const diffDays = Number(diffQ.rows[0]?.diff_days || 0);
  if (!Number.isFinite(diffDays) || diffDays < 0) return fallback;
  return (diffDays % 10) + 1;
}

function reservedOrderMessageText(order) {
  const productLabel = formatProductLabel(
    order.product_code,
    order.product_shelf_number,
    order.manual_shelf_label,
  );
  const clientShelf = displayShelfValue(order.shelf_label, order.shelf_number);
  const lines = [
    `📦 ${order.product_title}`,
    order.product_description
      ? `Описание: ${String(order.product_description).trim()}`
      : null,
    `Клиент: ${order.client_name || "—"}`,
    `Телефон: ${formatPhoneForDisplay(order.client_phone)}`,
    `ID товара: ${productLabel}`,
    `Цена: ${order.product_price} ₽`,
    `Куплено: ${order.quantity}`,
    `Полка товара: ${order.product_shelf_number ?? "не назначена"}`,
    `Полка клиента: ${clientShelf}`,
    "Статус: ожидание обработки",
  ].filter(Boolean);
  return lines.join("\n");
}

function archivedProductMessageText({
  product,
  sourceChannelTitle,
  queuedByName,
  queuedByEmail,
  queuedByPhone,
}) {
  const creator = queuedByName || queuedByEmail || "Неизвестно";
  const productLabel = formatProductLabel(
    product.product_code,
    product.shelf_number,
    product.manual_shelf_label,
  );
  const lines = [
    "🗂 Архив поста товара",
    `Название: ${product.title}`,
    product.description ? `Описание: ${String(product.description).trim()}` : null,
    `Цена: ${product.price} ₽`,
    `Количество: ${product.quantity}`,
    `ID товара: ${productLabel}`,
    `Канал публикации: ${sourceChannelTitle || "Основной канал"}`,
    `Кто создал пост: ${creator}`,
    queuedByPhone ? `Телефон создателя: ${queuedByPhone}` : null,
  ].filter(Boolean);
  return lines.join("\n");
}

function buildDemoProduct(index, imageUrl) {
  const nouns = [
    "Шампунь",
    "Кофта",
    "Кружка",
    "Плед",
    "Игрушка",
    "Сумка",
    "Свеча",
    "Куртка",
    "Термос",
    "Скраб",
  ];
  const adjectives = [
    "новый",
    "уютный",
    "мягкий",
    "яркий",
    "плотный",
    "аккуратный",
    "зимний",
    "летний",
    "практичный",
    "компактный",
  ];
  const noun = nouns[index % nouns.length];
  const adjective = adjectives[randomInt(0, adjectives.length - 1)];
  const price = randomInt(80, 2500);
  const quantity = randomInt(1, 8);
  return {
    title: `${noun} ${index + 1}`,
    description: `${adjective} товар для теста публикации на канал. Партия ${randomInt(
      1,
      99,
    )}.`,
    price,
    quantity,
    image_url: imageUrl,
  };
}

function publishDemoPostsSequentially({
  io,
  count,
  channelId,
  channelTitle,
  tenantId,
  createdBy,
  imageUrl,
}) {
  for (let index = 0; index < count; index += 1) {
    setTimeout(async () => {
      const client = await db.pool.connect();
      try {
        await client.query("BEGIN");
        const code = await allocateProductCode(client, tenantId || null);
        const demo = buildDemoProduct(index, imageUrl);
        const productId = uuidv4();
        await client.query(
          `INSERT INTO products (
             id, product_code, title, description, price, quantity,
             image_url, created_by, status, created_at, updated_at
           )
           VALUES (
             $1, $2, $3, $4, $5, $6,
             $7, $8, 'published', now(), now()
           )`,
          [
            productId,
            code,
            demo.title,
            demo.description,
            demo.price,
            demo.quantity,
            demo.image_url,
            createdBy,
          ],
        );

        const payload = {
          title: demo.title,
          description: demo.description,
          price: demo.price,
          quantity: demo.quantity,
          image_url: demo.image_url,
        };
        const messageMeta = {
          kind: "catalog_product",
          product_id: productId,
          product_code: code,
          price: demo.price,
          quantity: demo.quantity,
          image_url: demo.image_url,
        };
        const messageInsert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, NULL, $3, $4::jsonb, now())
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            uuidv4(),
            channelId,
            encryptMessageText(
              productMessageText({
              title: demo.title,
              description: demo.description,
              price: demo.price,
              quantity: demo.quantity,
              }),
            ),
            JSON.stringify(messageMeta),
          ],
        );
        await upsertMessageSearchDocument({
          queryable: client,
          messageId: messageInsert.rows[0]?.id,
          chatId: channelId,
          tenantId: tenantId || null,
          senderId: null,
          text: productMessageText({
            title: demo.title,
            description: demo.description,
            price: demo.price,
            quantity: demo.quantity,
          }),
          meta: messageMeta,
          attachments: [],
          createdAt: messageInsert.rows[0]?.created_at || null,
        });

        await client.query(
          `INSERT INTO product_publication_queue (
             id, product_id, channel_id, queued_by,
             status, is_sent, payload, approved_by, approved_at, published_message_id, created_at
           )
           VALUES (
             $1, $2, $3, $4,
             'published', true, $5::jsonb, $6, now(), $7, now()
           )`,
          [
            uuidv4(),
            productId,
            channelId,
            createdBy,
            JSON.stringify(payload),
            createdBy,
            messageInsert.rows[0].id,
          ],
        );

        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          channelId,
        ]);
        await client.query("COMMIT");

        if (io) {
          io.to(`chat:${channelId}`).emit("chat:message", {
            chatId: channelId,
            message: decryptMessageRow(messageInsert.rows[0]),
          });
          emitToTenant(io, tenantId || null, "chat:updated", {
            chatId: channelId,
            chat: {
              id: channelId,
              title: channelTitle,
              updated_at: new Date().toISOString(),
            },
          });
        }
      } catch (err) {
        await client.query("ROLLBACK");
        console.error("admin.test.publishDemoPostsSequentially error", err);
      } finally {
        client.release();
      }
    }, index * PUBLISH_POST_INTERVAL_MS);
  }
}

async function allocateProductCode(client, tenantId = null) {
  void tenantId;
  await client.query("LOCK TABLE products IN SHARE ROW EXCLUSIVE MODE");

  const reusable = await client.query(
    `SELECT p.id, p.product_code, p.reusable_at
     FROM products p
     WHERE p.status = 'archived'
       AND p.reusable_at IS NOT NULL
       AND p.reusable_at <= now()
       AND p.product_code IS NOT NULL
       AND p.product_code > 0
     ORDER BY p.product_code ASC, p.reusable_at ASC
     FOR UPDATE OF p`,
  );

  const reusableCodes = reusable.rows
    .map((row) => Number(row.product_code))
    .filter((value) => Number.isFinite(value) && value > 0);
  const reusableCodeSet = new Set(reusableCodes);
  const reusableByCode = new Map();
  for (const row of reusable.rows) {
    const code = Number(row.product_code);
    if (!Number.isFinite(code) || code <= 0) continue;
    if (!reusableByCode.has(code)) {
      reusableByCode.set(code, row.id);
    }
  }

  const nextRes = await client.query(
    `WITH used AS (
       SELECT DISTINCT p.product_code
       FROM products p
       WHERE p.product_code IS NOT NULL
         AND p.product_code > 0
         AND NOT (p.product_code = ANY($1::int[]))
     )
     SELECT COALESCE(
       (SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM used WHERE product_code = 1)),
       (
         SELECT MIN(u1.product_code + 1)
         FROM used u1
         LEFT JOIN used u2
           ON u2.product_code = u1.product_code + 1
         WHERE u2.product_code IS NULL
       ),
       1
     ) AS next_code`,
    [reusableCodes],
  );
  const nextCode = Number(nextRes.rows[0]?.next_code || 1);
  if (!Number.isFinite(nextCode) || nextCode <= 0) return 1;

  if (reusableCodeSet.has(nextCode)) {
    const reusableProductId = reusableByCode.get(nextCode);
    if (reusableProductId) {
      await client.query(
        `UPDATE products
         SET product_code = NULL,
             updated_at = now()
         WHERE id = $1`,
        [reusableProductId],
      );
    }
  }

  return nextCode;
}

function isProductCodeConflictError(err) {
  return (
    String(err?.code || "") === "23505" &&
    String(err?.constraint || "").trim() === "products_product_code_key"
  );
}

async function resolveUniqueProductCodeForPublish(
  client,
  requestedCode,
  productId,
  tenantId = null,
) {
  const normalizedRequested = Number(requestedCode);
  if (Number.isFinite(normalizedRequested) && normalizedRequested > 0) {
    const collisionQ = await client.query(
      `SELECT id
       FROM products
       WHERE product_code = $1
         AND id <> $2
       LIMIT 1`,
      [Math.floor(normalizedRequested), productId],
    );
    if (collisionQ.rowCount === 0) {
      return Math.floor(normalizedRequested);
    }
  }
  return await allocateProductCode(client, tenantId || null);
}

// Список пользователей
router.get(
  "/users",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Управление ролями доступно арендатору только во вкладке Профиль",
      });
    }
    try {
      const role = String(req.user?.role || "")
        .toLowerCase()
        .trim();
      const isCreator = role === "creator";
      const result = await db.query(
        `SELECT id, email, role, created_at
         FROM users
         WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid)
         ORDER BY created_at DESC`,
        [isCreator ? null : req.user?.tenant_id || null],
      );
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error("admin.users.list error", err);
      return res.status(500).json({ error: "Ошибка сервера" });
    }
  },
);

// Назначить роль пользователю
router.post(
  "/users/:id/role",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Управление ролями доступно арендатору только во вкладке Профиль",
      });
    }
    const { id } = req.params;
    const { role } = req.body || {};
    const allowed = ["client", "worker", "admin", "creator"];

    if (!allowed.includes(role)) {
      return res.status(400).json({ error: "Неправильная роль" });
    }

    try {
      if (role === "creator" && req.user.role !== "creator") {
        return res
          .status(403)
          .json({ error: "Только создатель способен на такое" });
      }

      const isCreator = String(req.user?.role || "")
        .toLowerCase()
        .trim() === "creator";
      const updated = await db.query(
        `UPDATE users
         SET role = $1, updated_at = now()
         WHERE id = $2
           AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
         RETURNING id`,
        [role, id, isCreator ? null : req.user?.tenant_id || null],
      );
      if (updated.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Пользователь не найден" });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.users.role error", err);
      return res.status(500).json({ error: "Ошибка сервера" });
    }
  },
);

// Управление арендаторами (только platform creator)
router.get("/tenants", requireAuth, requireRole("creator"), async (req, res) => {
  if (req.user?.is_platform_creator !== true) {
    return res.status(403).json({ ok: false, error: "Forbidden" });
  }
  try {
    const includeDeleted = String(req.query?.include_deleted || "")
      .trim()
      .toLowerCase() === "1";
    const result = await db.platformQuery(
      `SELECT id, code, name, status,
              COALESCE(access_key_mask, '—') AS access_key_mask,
              COALESCE(NULLIF(access_key_value, ''), NULL) AS access_key_value,
              subscription_expires_at, last_payment_confirmed_at, notes,
              db_mode, db_name, db_schema, is_deleted,
              created_at, updated_at
       FROM tenants
       WHERE ($1::boolean = true OR COALESCE(is_deleted, false) = false)
       ORDER BY created_at DESC`,
      [includeDeleted],
    );
    return res.json({ ok: true, data: result.rows });
  } catch (err) {
    console.error("admin.tenants.list error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get(
  "/tenants/:tenantId/feature-settings",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }

    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant || tenant.is_deleted === true) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      const settings = await getTenantFeatureSettings(tenantId);
      return res.json({ ok: true, data: settings });
    } catch (err) {
      console.error("admin.tenants.featureSettings.get error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenants/:tenantId/feature-settings",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }

    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant || tenant.is_deleted === true) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      const settings = await patchTenantFeatureSettings(
        tenantId,
        buildTenantWorkflowSettingsPayload(req.body || {}),
      );
      emitToTenant(req.app.get("io"), tenantId, "tenant:feature-settings:updated", {
        entity: "tenant_feature_settings",
        entity_id: tenantId,
        action: "updated",
        settings,
      });
      return res.json({ ok: true, data: settings });
    } catch (err) {
      console.error("admin.tenants.featureSettings.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/tenants",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }

    const name = String(req.body?.name || "").trim();
    const monthsRaw = Number(req.body?.months);
    const months = Number.isFinite(monthsRaw)
      ? Math.max(1, Math.min(24, Math.floor(monthsRaw)))
      : 1;
    const notes = String(req.body?.notes || "").trim();

    if (!name) {
      return res
        .status(400)
        .json({ ok: false, error: "Название арендатора обязательно" });
    }

    const accessKey = generateAccessKey();
    const accessKeyHash = hashAccessKey(accessKey);
    const accessKeyMask = maskAccessKey(accessKey);
    const tenantId = uuidv4();
    const code = generateTenantCode(name);

    const platformDbUrl =
      process.env.DATABASE_URL ||
      "postgresql://projectphoenix:projectphoenix@localhost:5432/projectphoenix";
    const client = await db.platformConnect();
    try {
      await client.query("BEGIN");
      const created = await client.query(
        `INSERT INTO tenants (
           id, code, name, access_key_hash, access_key_mask,
           access_key_value,
           status, subscription_expires_at, last_payment_confirmed_at,
           created_by, notes, db_mode, db_name, db_schema, db_url, created_at, updated_at
         )
         VALUES (
           $1, $2, $3, $4, $5, $6,
           'active', now() + make_interval(months => $7::int), now(),
           $8, $9, 'isolated', NULL, NULL, NULL, now(), now()
         )
         RETURNING id, code, name, status, access_key_mask, access_key_value, subscription_expires_at, notes, created_at`,
        [
          tenantId,
          code,
          name,
          accessKeyHash,
          accessKeyMask,
          accessKey,
          months,
          req.user.id,
          notes,
        ],
      );
      await client.query("COMMIT");

      const createdRow = created.rows[0];
      var dbMode = "isolated";
      var dbName = null;
      var dbSchema = null;
      var warning = "";

      try {
        const provision = await provisionIsolatedTenantDatabase({
          platformDbUrl,
          tenantId,
          tenantCode: code,
          tenantName: name,
          accessKeyHash,
          accessKeyMask,
          accessKeyValue: accessKey,
          status: "active",
          subscriptionExpiresAt: createdRow.subscription_expires_at,
          createdBy: req.user.id,
          notes,
        });

        dbMode = String(provision.dbMode || "isolated")
          .toLowerCase()
          .trim();
        dbName = provision.dbName || null;
        dbSchema = provision.dbSchema || null;
        await db.platformQuery(
          `UPDATE tenants
           SET db_mode = $2,
               db_name = $3,
               db_schema = $4,
               db_url = $5,
               updated_at = now()
           WHERE id = $1`,
          [tenantId, dbMode, dbName, dbSchema, provision.dbUrl || null],
        );
        if (dbMode === "schema_isolated") {
          warning =
            "Отдельная БД не была создана из-за ограничений PostgreSQL, включен schema-isolated режим (данные арендатора в отдельной схеме).";
        }
      } catch (provisionErr) {
        console.error(
          "admin.tenants.create isolated provision failed",
          provisionErr,
        );
        dbMode = "shared";
        dbName = null;
        dbSchema = null;
        warning = buildIsolatedProvisionWarning(provisionErr);
        try {
          await db.platformQuery(
            `UPDATE tenants
             SET db_mode = 'shared',
                 db_name = NULL,
                 db_schema = NULL,
                 db_url = NULL,
                 updated_at = now()
             WHERE id = $1`,
            [tenantId],
          );
          const sharedClient = await db.platformConnect();
          try {
            await sharedClient.query("BEGIN");
            await ensureSystemChannels(sharedClient, req.user.id, tenantId);
            await sharedClient.query("COMMIT");
          } catch (sharedErr) {
            await sharedClient.query("ROLLBACK");
            throw sharedErr;
          } finally {
            sharedClient.release();
          }
        } catch (fallbackErr) {
          console.error(
            "admin.tenants.create shared fallback failed",
            fallbackErr,
          );
          await db.platformQuery(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
          return res.status(500).json({
            ok: false,
            error:
              "Не удалось создать арендатора: изолированная и shared инициализация завершились ошибкой.",
          });
        }
      }

      let featureSettings = null;
      try {
        featureSettings = await patchTenantFeatureSettings(
          tenantId,
          buildTenantWorkflowSettingsPayload(req.body || {}),
        );
      } catch (settingsErr) {
        console.error("admin.tenants.create feature settings failed", settingsErr);
        warning = `${warning ? `${warning} ` : ""}Настройки группы не сохранены, можно повторить через кнопку "Настройки".`;
      }

      return res.status(201).json({
        ok: true,
        data: {
          ...createdRow,
          access_key: accessKey,
          db_mode: dbMode,
          db_name: dbName,
          db_schema: dbSchema,
          feature_settings: featureSettings,
          warning,
        },
      });
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      try {
        await db.platformQuery("DELETE FROM tenants WHERE id = $1", [tenantId]);
      } catch (_) {}
      console.error("admin.tenants.create error", err);
      return res.status(500).json({
        ok: false,
        error:
          "Не удалось создать арендатора и его отдельную БД. Проверьте доступ к PostgreSQL.",
      });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/tenants/:tenantId/confirm-payment",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    const monthsRaw = Number(req.body?.months);
    const months = Number.isFinite(monthsRaw)
      ? Math.max(1, Math.min(24, Math.floor(monthsRaw)))
      : 1;

    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }

    try {
      const updated = await db.platformQuery(
        `UPDATE tenants
         SET status = 'active',
             subscription_expires_at = GREATEST(now(), subscription_expires_at) + make_interval(months => $1::int),
             last_payment_confirmed_at = now(),
             updated_at = now()
         WHERE id = $2
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, subscription_expires_at,
                   last_payment_confirmed_at, db_mode, db_url, db_name, db_schema`,
        [months, tenantId],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      const shadowSync = await syncTenantShadowStateForAdmin(
        updated.rows[0],
        "confirmPayment",
      );
      const io = req.app.get("io");
      emitTenantSubscriptionUpdate(
        io,
        tenantId,
        updated.rows[0],
        "confirm_payment",
      );
      return res.json({
        ok: true,
        data: serializeTenantAdminRow(updated.rows[0], {
          shadow_sync: shadowSync,
        }),
      });
    } catch (err) {
      console.error("admin.tenants.confirmPayment error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenants/:tenantId/status",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    const status = String(req.body?.status || "")
      .toLowerCase()
      .trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }
    if (status !== "active" && status !== "blocked") {
      return res.status(400).json({ ok: false, error: "Статус должен быть active или blocked" });
    }

    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      if (tenant.is_deleted === true) {
        return res.status(404).json({
          ok: false,
          error: "Арендатор уже удален",
        });
      }
      if (isProtectedTenantCode(tenant.code)) {
        return res.status(403).json({
          ok: false,
          error: "Системного арендатора default нельзя блокировать",
        });
      }
      const updated = await db.platformQuery(
        `UPDATE tenants
         SET status = $1,
             updated_at = now()
         WHERE id = $2
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, subscription_expires_at,
                   updated_at, db_mode, db_url, db_name, db_schema`,
        [status, tenantId],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      const shadowSync = await syncTenantShadowStateForAdmin(
        updated.rows[0],
        "updateStatus",
      );
      const io = req.app.get("io");
      emitTenantSubscriptionUpdate(
        io,
        tenantId,
        updated.rows[0],
        "status_change",
      );
      return res.json({
        ok: true,
        data: serializeTenantAdminRow(updated.rows[0], {
          shadow_sync: shadowSync,
        }),
      });
    } catch (err) {
      console.error("admin.tenants.updateStatus error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenants/:tenantId/access-key",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }

    const generate = req.body?.generate === true;
    let accessKey = generate
      ? generateAccessKey()
      : normalizeTenantAccessKeyInput(req.body?.access_key || "");
    if (!accessKey) {
      return res.status(400).json({
        ok: false,
        error: "Укажите новый ключ арендатора или включите авто-генерацию",
      });
    }
    if (!TENANT_ACCESS_KEY_PATTERN.test(accessKey)) {
      return res.status(400).json({
        ok: false,
        error:
          "Ключ должен быть в формате XXX-XXXXXXX-KEY (3 буквы слева, в центре буквы/цифры, справа KEY)",
      });
    }

    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant || tenant.is_deleted === true) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }

      const updated = await db.platformQuery(
        `UPDATE tenants
         SET access_key_hash = $1,
             access_key_mask = $2,
             access_key_value = $3,
             updated_at = now()
         WHERE id = $4
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, access_key_value, subscription_expires_at, updated_at`,
        [
          hashAccessKey(accessKey),
          maskAccessKey(accessKey),
          accessKey,
          tenantId,
        ],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      return res.json({
        ok: true,
        data: {
          ...updated.rows[0],
          access_key: accessKey,
        },
      });
    } catch (err) {
      console.error("admin.tenants.updateAccessKey error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/tenants/:tenantId",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const tenantId = String(req.params?.tenantId || "").trim();
    if (!isUuidLike(tenantId)) {
      return res.status(400).json({ ok: false, error: "Некорректный tenantId" });
    }
    try {
      const tenant = await getTenantById(tenantId);
      if (!tenant) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден" });
      }
      if (tenant.is_deleted === true) {
        return res.status(404).json({
          ok: false,
          error: "Арендатор уже удален",
        });
      }
      const archived = await db.platformQuery(
        `UPDATE tenants
         SET status = 'blocked',
             is_deleted = true,
             subscription_expires_at = now(),
             updated_at = now()
         WHERE id = $1
           AND COALESCE(is_deleted, false) = false
         RETURNING id, code, name, status, access_key_mask, subscription_expires_at,
                   updated_at, is_deleted, db_mode, db_url, db_name, db_schema`,
        [tenantId],
      );
      if (archived.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Арендатор не найден или уже удален" });
      }
      const shadowSync = await syncTenantShadowStateForAdmin(
        archived.rows[0],
        "delete",
      );
      const io = req.app.get("io");
      emitTenantSubscriptionUpdate(io, tenantId, archived.rows[0], "delete");
      return res.json({
        ok: true,
        data: serializeTenantAdminRow(archived.rows[0], {
          shadow_sync: shadowSync,
        }),
      });
    } catch (err) {
      console.error("admin.tenants.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

function tenantInviteRole(rawRole) {
  const role = String(rawRole || "").toLowerCase().trim();
  if (role === "client") return role;
  return "client";
}

function parseNullablePositiveInt(raw, { min = 1, max = 100000 } = {}) {
  if (raw == null) return null;
  if (typeof raw === "string" && raw.trim() === "") return null;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return null;
  return Math.max(min, Math.min(max, Math.floor(parsed)));
}

function normalizeTenantAccessKeyInput(raw) {
  const normalized = normalizeAccessKey(raw);
  if (!normalized) return "";
  const compact = normalized.replace(/[^A-Z0-9]/g, "");
  if (compact.length >= 7 && compact.endsWith("KEY")) {
    const prefix = compact.slice(0, 3);
    const middle = compact.slice(3, -3);
    if (/^[A-Z]{3}$/.test(prefix) && /^[A-Z0-9]{1,32}$/.test(middle)) {
      return `${prefix}-${middle}-KEY`;
    }
  }
  return normalized.slice(0, 64);
}

async function resolveTargetTenantForInvite(req) {
  const ownTenantId = String(req.user?.tenant_id || "").trim();
  if (ownTenantId) {
    return {
      id: ownTenantId,
      code: String(req.user?.tenant_code || "").trim() || null,
    };
  }

  const tenantIdHint = String(
    req.query?.tenant_id || req.body?.tenant_id || "",
  ).trim();
  if (tenantIdHint) {
    const byId = await db.platformQuery(
      `SELECT id, code
       FROM tenants
       WHERE id = $1
       LIMIT 1`,
      [tenantIdHint],
    );
    if (byId.rowCount > 0) {
      return {
        id: byId.rows[0].id,
        code: byId.rows[0].code || null,
      };
    }
  }

  const tenantCodeHint = String(
    req.query?.tenant_code || req.body?.tenant_code || "",
  )
    .trim()
    .toLowerCase();
  if (tenantCodeHint) {
    const byCode = await db.platformQuery(
      `SELECT id, code
       FROM tenants
       WHERE lower(code) = $1
       LIMIT 1`,
      [tenantCodeHint],
    );
    if (byCode.rowCount > 0) {
      return {
        id: byCode.rows[0].id,
        code: byCode.rows[0].code || null,
      };
    }
  }

  const latest = await db.platformQuery(
    `SELECT id, code
     FROM tenants
     WHERE code <> 'default'
     ORDER BY updated_at DESC NULLS LAST, created_at DESC
     LIMIT 1`,
  );
  if (latest.rowCount > 0) {
    return {
      id: latest.rows[0].id,
      code: latest.rows[0].code || null,
    };
  }
  return null;
}

function inviteLinkForRequest(req, inviteCode, tenantCode = "") {
  const base = String(process.env.INVITE_LINK_BASE || "").trim();
  const encoded = encodeURIComponent(inviteCode);
  const tenantPart = tenantCode
    ? `?tenant=${encodeURIComponent(tenantCode)}`
    : "";
  if (base) {
    const normalizedBase = base.replace(/\/+$/, "");
    if (/\/join(?:\/|$)/i.test(normalizedBase)) {
      const glue = normalizedBase.includes("?") ? "&" : "?";
      return `${normalizedBase}${glue}invite=${encoded}${
        tenantCode ? `&tenant=${encodeURIComponent(tenantCode)}` : ""
      }`;
    }
    return `${normalizedBase}/join/${encoded}${tenantPart}`;
  }
  return `${req.protocol}://${req.get("host")}/join/${encoded}${tenantPart}`;
}

function isTenantUser(user) {
  const base = String(user?.base_role || user?.role || "")
    .toLowerCase()
    .trim();
  return base === "tenant";
}

async function getTenantById(tenantId) {
  const result = await db.platformQuery(
    `SELECT id, code, name, is_deleted
     FROM tenants
     WHERE id = $1
     LIMIT 1`,
    [tenantId],
  );
  return result.rowCount > 0 ? result.rows[0] : null;
}

function isProtectedTenantCode(code) {
  return String(code || "").toLowerCase().trim() === "default";
}

router.get(
  "/tenant/invites",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    try {
      const includeInactive = String(req.query?.include_inactive || "")
        .toLowerCase()
        .trim() === "1";
      const result = await db.platformQuery(
        `SELECT i.id,
                i.tenant_id,
                t.code AS tenant_code,
                i.code,
                i.role,
                i.is_active,
                i.max_uses,
                i.used_count,
                i.expires_at,
                i.created_by,
                i.last_used_at,
                i.notes,
                i.created_at,
                i.updated_at
         FROM tenant_invites i
         JOIN tenants t ON t.id = i.tenant_id
         WHERE i.tenant_id = $1
           AND ($2::boolean = true OR i.is_active = true)
         ORDER BY i.created_at DESC`,
        [targetTenant.id, includeInactive],
      );
      const data = result.rows.map((row) => ({
        ...row,
        invite_link: inviteLinkForRequest(
          req,
          row.code,
          row.tenant_code || targetTenant.code || "",
        ),
      }));
      return res.json({ ok: true, data });
    } catch (err) {
      console.error("admin.tenant.invites.list error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/tenant/invites",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const role = tenantInviteRole(req.body?.role);
    const notes = String(req.body?.notes || "").trim();
    const maxUses = parseNullablePositiveInt(req.body?.max_uses, {
      min: 1,
      max: 100000,
    });
    const expiresDays = parseNullablePositiveInt(req.body?.expires_days, {
      min: 1,
      max: 365,
    });
    const forceNew = req.body?.force_new === true;

    try {
      if (!forceNew) {
        const existing = await db.platformQuery(
          `SELECT id,
                  tenant_id,
                  code,
                  role,
                  is_active,
                  max_uses,
                  used_count,
                  expires_at,
                  created_by,
                  last_used_at,
                  notes,
                  created_at,
                  updated_at
           FROM tenant_invites
           WHERE tenant_id = $1
             AND role = $2
             AND is_active = true
             AND max_uses IS NULL
             AND expires_at IS NULL
             AND (expires_at IS NULL OR expires_at > now())
             AND (max_uses IS NULL OR used_count < max_uses)
           ORDER BY created_at DESC
           LIMIT 1`,
          [targetTenant.id, role],
        );
        if (existing.rowCount > 0) {
          const row = existing.rows[0];
          return res.json({
            ok: true,
            reused: true,
            data: {
              ...row,
              invite_link: inviteLinkForRequest(
                req,
                row.code,
                targetTenant.code || "",
              ),
            },
          });
        }
      }

      let tries = 0;
      while (tries < 5) {
        tries += 1;
        const code = generateInviteCode();
        try {
          const inserted = await db.platformQuery(
            `INSERT INTO tenant_invites (
               id, tenant_id, code, role, is_active, max_uses,
               used_count, expires_at, created_by, notes, created_at, updated_at
             )
             VALUES (
               $1, $2, $3, $4, true, $5,
               0,
               CASE WHEN $6::int IS NULL THEN NULL ELSE now() + make_interval(days => $6::int) END,
               $7, NULLIF($8, ''), now(), now()
             )
             RETURNING id,
                       tenant_id,
                       code,
                       role,
                       is_active,
                       max_uses,
                       used_count,
                       expires_at,
                       created_by,
                       last_used_at,
                       notes,
                       created_at,
                       updated_at`,
            [
              uuidv4(),
              targetTenant.id,
              normalizeInviteCode(code),
              role,
              maxUses,
              expiresDays,
              req.user.id,
              notes,
            ],
          );
          const row = inserted.rows[0];
          return res.status(201).json({
            ok: true,
            data: {
              ...row,
              invite_link: inviteLinkForRequest(
                req,
                row.code,
                targetTenant.code || "",
              ),
            },
          });
        } catch (err) {
          if (String(err?.code || "") === "23505") {
            continue;
          }
          throw err;
        }
      }
      return res.status(500).json({
        ok: false,
        error: "Не удалось сгенерировать уникальный код приглашения",
      });
    } catch (err) {
      console.error("admin.tenant.invites.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenant/invites/:inviteId/status",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const inviteId = String(req.params?.inviteId || "").trim();
    const active = req.body?.is_active === true;
    if (!isUuidLike(inviteId)) {
      return res.status(400).json({ ok: false, error: "Некорректный inviteId" });
    }
    try {
      const updated = await db.platformQuery(
        `UPDATE tenant_invites
         SET is_active = $1,
             updated_at = now()
         WHERE id = $2
           AND tenant_id = $3
         RETURNING id,
                   tenant_id,
                   code,
                   role,
                   is_active,
                   max_uses,
                   used_count,
                   expires_at,
                   created_by,
                   last_used_at,
                   notes,
                   created_at,
                   updated_at`,
        [active, inviteId, targetTenant.id],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Код приглашения не найден" });
      }
      const row = updated.rows[0];
      return res.json({
        ok: true,
        data: {
          ...row,
          invite_link: inviteLinkForRequest(
            req,
            row.code,
            targetTenant.code || "",
          ),
        },
      });
    } catch (err) {
      console.error("admin.tenant.invites.status error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenant/invites/:inviteId/code",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Изменять код приглашения может только Создатель",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const inviteId = String(req.params?.inviteId || "").trim();
    if (!isUuidLike(inviteId)) {
      return res.status(400).json({ ok: false, error: "Некорректный inviteId" });
    }
    const nextCode = normalizeInviteCode(req.body?.code || "");
    if (!nextCode || nextCode.length < 6 || nextCode.length > 64) {
      return res.status(400).json({
        ok: false,
        error: "Код должен содержать от 6 до 64 символов (A-Z, 0-9, -)",
      });
    }
    try {
      const updated = await db.platformQuery(
        `UPDATE tenant_invites
         SET code = $1,
             updated_at = now()
         WHERE id = $2
           AND tenant_id = $3
         RETURNING id,
                   tenant_id,
                   code,
                   role,
                   is_active,
                   max_uses,
                   used_count,
                   expires_at,
                   created_by,
                   last_used_at,
                   notes,
                   created_at,
                   updated_at`,
        [nextCode, inviteId, targetTenant.id],
      );
      if (updated.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Код приглашения не найден" });
      }
      const row = updated.rows[0];
      return res.json({
        ok: true,
        data: {
          ...row,
          invite_link: inviteLinkForRequest(
            req,
            row.code,
            targetTenant.code || "",
          ),
        },
      });
    } catch (err) {
      if (String(err?.code || "") === "23505") {
        return res.status(409).json({
          ok: false,
          error: "Такой код уже существует. Выберите другой.",
        });
      }
      console.error("admin.tenant.invites.rename error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/tenant/invites/:inviteId",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error:
          "Коды приглашений здесь отключены. Используйте раздел Профиль внутри нужной группы.",
      });
    }
    if (isTenantUser(req.user)) {
      return res.status(403).json({
        ok: false,
        error:
          "Клиентские приглашения арендатора доступны только во вкладке Профиль",
      });
    }
    const targetTenant = await resolveTargetTenantForInvite(req);
    if (!targetTenant?.id) {
      return res.status(403).json({
        ok: false,
        error: "Не выбран арендатор для кодов приглашения",
      });
    }
    const inviteId = String(req.params?.inviteId || "").trim();
    if (!isUuidLike(inviteId)) {
      return res.status(400).json({ ok: false, error: "Некорректный inviteId" });
    }
    try {
      const removed = await db.platformQuery(
        `UPDATE tenant_invites
         SET is_active = false,
             updated_at = now()
         WHERE id = $1
           AND tenant_id = $2
         RETURNING id`,
        [inviteId, targetTenant.id],
      );
      if (removed.rowCount === 0) {
        return res
          .status(404)
          .json({ ok: false, error: "Код приглашения не найден" });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.tenant.invites.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Получить список каналов
router.get(
  "/channels",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const client = await db.pool.connect();
      try {
        await client.query("BEGIN");
        await ensureSystemChannels(client, req.user.id, req.user.tenant_id);
        await client.query("COMMIT");
      } catch (err) {
        await client.query("ROLLBACK");
        throw err;
      } finally {
        client.release();
      }

      const result = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
       FROM chats
       WHERE type = 'channel'
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
         AND (
           (
             COALESCE(settings->>'kind', 'channel') = 'channel'
             AND COALESCE((settings->>'admin_only')::boolean, false) = false
             AND COALESCE((settings->>'hidden_in_chat_list')::boolean, false) = false
           )
           OR COALESCE(settings->>'system_key', '') IN ('reserved_orders', 'posts_archive')
           OR COALESCE(settings->>'kind', '') IN ('reserved_orders', 'posts_archive')
         )
         AND LOWER(TRIM(title)) <> LOWER(TRIM('Баг-репорты'))
       ORDER BY updated_at DESC NULLS LAST, created_at DESC`,
        [req.user.tenant_id || null],
      );
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error("admin.channels.list error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Создать канал
router.post(
  "/channels",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const { title, description, visibility, avatar_url } = req.body || {};

      const normalizedTitle = String(title || "").trim();
      if (!normalizedTitle) {
        return res
          .status(400)
          .json({ ok: false, error: "Название канала обязательно" });
      }
      if (isMainSystemTitle(normalizedTitle) || isReservedSystemTitle(normalizedTitle)) {
        return res.status(400).json({
          ok: false,
          error:
            "Это системное название. Измените существующий системный канал в настройках, а не создавайте новый.",
        });
      }

      const nextVisibility = normalizeVisibility(visibility);
      const settings = {
        kind: "channel",
        tenant_id: req.user.tenant_id,
        description: String(description || "").trim(),
        visibility: nextVisibility,
        worker_can_post: false,
        is_post_channel: false,
        avatar_url: avatar_url ? toOriginalPublicMediaUrl(String(avatar_url || "").trim()) : "",
        avatar_focus_x: 0,
        avatar_focus_y: 0,
        avatar_zoom: 1,
        blacklisted_user_ids: [],
        blacklist_entries: [],
      };

      const insert = await db.query(
        `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
       VALUES ($1, $2, 'channel', $3, $4, $5::jsonb, now(), now())
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [
          uuidv4(),
          normalizedTitle,
          req.user.id,
          req.user.tenant_id,
          JSON.stringify(settings),
        ],
      );
      const channel = insert.rows[0];
      if (settings.avatar_url) {
        await registerPublicImageUpload({
          queryable: db,
          ownerKind: "channel_avatar",
          ownerId: channel.id,
          rawUrl: settings.avatar_url,
        });
      }

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:created", {
          chatId: channel.id,
          chat: channel,
        });
        emitChannelUpdated(io, req.user?.tenant_id || null, channel.id, {
          action: "created",
          chat: channel,
        });
      }

      return res.status(201).json({ ok: true, data: channel });
    } catch (err) {
      console.error("admin.channels.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Удалить канал
router.delete(
  "/channels/:id",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      return await runInRequestTenantScope(req, async () => {
        const client = await db.pool.connect();
        try {
          await client.query("BEGIN");

          const current = await client.query(
            `SELECT id, title, settings
             FROM chats
             WHERE id = $1 AND type = 'channel' AND tenant_id = $2
             LIMIT 1
             FOR UPDATE`,
            [id, req.user.tenant_id],
          );
          if (current.rowCount === 0) {
            await client.query("ROLLBACK");
            return res.status(404).json({ ok: false, error: "Канал не найден" });
          }
          const currentSettings = normalizeSettings(current.rows[0].settings);
          const systemKey = String(currentSettings.system_key || "")
            .toLowerCase()
            .trim();
          if (
            (currentSettings.kind && currentSettings.kind !== "channel") ||
            systemKey === "main_channel" ||
            systemKey === "reserved_orders" ||
            currentSettings.admin_only === true ||
            isBugReportsTitle(current.rows[0].title)
          ) {
            await client.query("ROLLBACK");
            return res
              .status(403)
              .json({ ok: false, error: "Системный канал нельзя удалять" });
          }

          const deleted = await client.query(
            `DELETE FROM chats
             WHERE id = $1 AND type = 'channel' AND tenant_id = $2
             RETURNING id, title, type, created_by, settings, created_at, updated_at`,
            [id, req.user.tenant_id],
          );
          const deletedChannel = deleted.rows[0];
          const deletedSettings = normalizeSettings(deletedChannel.settings);

          // Если удалили текущий post-channel, автоматически назначаем следующий канал.
          if (deletedSettings.is_post_channel === true) {
            const next = await client.query(
              `SELECT id
               FROM chats
               WHERE type = 'channel'
                 AND tenant_id = $1
                 AND COALESCE(settings->>'kind', 'channel') = 'channel'
               ORDER BY updated_at DESC NULLS LAST, created_at DESC
               LIMIT 1`,
              [req.user.tenant_id],
            );
            if (next.rowCount > 0) {
              await client.query(
                `UPDATE chats
                 SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{is_post_channel}', 'true'::jsonb, true),
                     updated_at = now()
                 WHERE id = $1`,
                [next.rows[0].id],
              );
            }
          }

          await client.query("COMMIT");

          const io = req.app.get("io");
          if (io) {
            emitToTenant(io, req.user?.tenant_id || null, "chat:deleted", {
              chatId: id,
            });
            emitChannelUpdated(io, req.user?.tenant_id || null, id, {
              action: "deleted",
            });
          }

          return res.json({ ok: true, data: deletedChannel });
        } catch (err) {
          await client.query("ROLLBACK");
          console.error("admin.channels.delete error", err);
          return res.status(500).json({ ok: false, error: "Ошибка сервера" });
        } finally {
          client.release();
        }
      });
    } catch (err) {
      console.error("admin.channels.delete scope error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Обновить настройки канала
router.patch(
  "/channels/:id",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      const current = await db.query(
        `SELECT id, title, settings
       FROM chats
       WHERE id = $1 AND type = 'channel' AND tenant_id = $2
       LIMIT 1`,
        [id, req.user.tenant_id],
      );
      if (current.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const row = current.rows[0];
      const rowSettings = normalizeSettings(row.settings);
      if (isChannelReadOnlySystemChannel(row, rowSettings)) {
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя редактировать" });
      }
      const nextSettings = {
        kind: "channel",
        ...rowSettings,
      };
      nextSettings.avatar_focus_x = normalizeAvatarFocus(
        nextSettings.avatar_focus_x,
        0,
      );
      nextSettings.avatar_focus_y = normalizeAvatarFocus(
        nextSettings.avatar_focus_y,
        0,
      );
      nextSettings.avatar_zoom = normalizeAvatarZoom(nextSettings.avatar_zoom, 1);
      const normalizedEntries = normalizeBlacklistEntries(nextSettings);
      nextSettings.blacklist_entries = normalizedEntries;
      nextSettings.blacklisted_user_ids = normalizedEntries.map(
        (entry) => entry.user_id,
      );
      const systemKey = String(nextSettings.system_key || "").toLowerCase().trim();
      const isMainChannel = systemKey === "main_channel";

      if (Object.prototype.hasOwnProperty.call(req.body || {}, "description")) {
        nextSettings.description = String(req.body.description || "").trim();
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "visibility")) {
        nextSettings.visibility = normalizeVisibility(req.body.visibility);
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_url")) {
        nextSettings.avatar_url = req.body.avatar_url
          ? toOriginalPublicMediaUrl(String(req.body.avatar_url || "").trim())
          : "";
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_focus_x")) {
        nextSettings.avatar_focus_x = normalizeAvatarFocus(
          req.body.avatar_focus_x,
          nextSettings.avatar_focus_x,
        );
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_focus_y")) {
        nextSettings.avatar_focus_y = normalizeAvatarFocus(
          req.body.avatar_focus_y,
          nextSettings.avatar_focus_y,
        );
      }
      if (Object.prototype.hasOwnProperty.call(req.body || {}, "avatar_zoom")) {
        nextSettings.avatar_zoom = normalizeAvatarZoom(
          req.body.avatar_zoom,
          nextSettings.avatar_zoom,
        );
      }
      if (isMainChannel) {
        nextSettings.visibility = "public";
        nextSettings.worker_can_post = true;
        nextSettings.is_post_channel = true;
        nextSettings.admin_only = false;
      } else {
        nextSettings.worker_can_post = false;
        nextSettings.is_post_channel = false;
      }

      const nextTitle =
        typeof req.body?.title === "string" && req.body.title.trim()
          ? req.body.title.trim()
          : row.title;

      const updated = await db.query(
        `UPDATE chats
       SET title = $1,
           settings = $2::jsonb,
           updated_at = now()
       WHERE id = $3
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [nextTitle, JSON.stringify(nextSettings), id],
      );
      if (nextSettings.avatar_url) {
        await registerPublicImageUpload({
          queryable: db,
          ownerKind: "channel_avatar",
          ownerId: id,
          rawUrl: nextSettings.avatar_url,
        });
      }

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated.rows[0],
        });
        emitChannelUpdated(io, req.user?.tenant_id || null, id, {
          action: "updated",
          chat: updated.rows[0],
        });
      }

      return res.json({ ok: true, data: updated.rows[0] });
    } catch (err) {
      console.error("admin.channels.update error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Детальный обзор канала: клиенты, медиа, blacklist, счетчики
router.get(
  "/channels/:id/overview",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      const channelQ = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
         FROM chats
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
      );
      if (channelQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const channel = channelQ.rows[0];
      const settings = normalizeSettings(channel.settings);
      if (isChannelReadOnlySystemChannel(channel, settings)) {
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал недоступен в настройках" });
      }

      const visibility = normalizeVisibility(settings.visibility);
      const blacklistEntries = normalizeBlacklistEntries(settings);
      const blacklistedUserIds = blacklistEntries.map((entry) => entry.user_id);
      const blacklistedSet = new Set(blacklistedUserIds);

      const statsQ = await db.query(
        `SELECT COUNT(*)::int AS messages_total,
                COUNT(*) FILTER (
                  WHERE created_at >= now() - interval '24 hours'
                )::int AS messages_24h,
                COUNT(*) FILTER (
                  WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
                )::int AS product_posts_total,
                COUNT(*) FILTER (
                  WHERE
                    COALESCE(meta->>'image_url', '') <> ''
                    OR COALESCE(meta->>'product_image_url', '') <> ''
                    OR COALESCE(meta->>'kind', '') = 'catalog_product'
                )::int AS media_total,
                MAX(created_at) AS last_message_at
         FROM messages
         WHERE chat_id = $1`,
        [id],
      );

      const queueQ = await db.query(
        `SELECT COUNT(*) FILTER (
                  WHERE status = 'pending' AND COALESCE(is_sent, false) = false
                )::int AS pending_posts_total,
                COUNT(*) FILTER (
                  WHERE status = 'published' AND COALESCE(is_sent, false) = true
                )::int AS published_queue_total
         FROM product_publication_queue
         WHERE channel_id = $1`,
        [id],
      );

      const membersQ = await db.query(
        `SELECT u.id::text AS user_id,
                COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Пользователь') AS name,
                u.email,
                u.role,
                u.client_city,
                ph.phone,
                cm.role AS chat_role,
                cm.joined_at
         FROM chat_members cm
         JOIN users u ON u.id = cm.user_id
         LEFT JOIN phones ph ON ph.user_id = u.id
         WHERE cm.chat_id = $1
         ORDER BY cm.joined_at DESC
         LIMIT 300`,
        [id],
      );

      let clientsQ;
      let clientsTotal = 0;
      if (visibility === "private") {
        clientsQ = await db.query(
          `SELECT u.id::text AS user_id,
                  COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Клиент') AS name,
                  u.email,
                  u.client_city,
                  ph.phone,
                  COALESCE(cart_summary.total_sum, 0)::numeric AS cart_sum,
                  us.shelf_number,
                  saved_addr.address_text AS saved_address_text,
                  saved_addr.address_ciphertext AS saved_address_ciphertext,
                  saved_addr.address_iv AS saved_address_iv,
                  saved_addr.address_tag AS saved_address_tag,
                  latest_delivery.id::text AS delivery_customer_id,
                  latest_delivery.processed_sum,
                  latest_delivery.agreed_sum,
                  COALESCE(latest_delivery.agreed_sum, latest_delivery.processed_sum, 0)::numeric AS delivery_sum,
                  latest_delivery.address_text AS delivery_address_text,
                  latest_delivery.address_ciphertext AS delivery_address_ciphertext,
                  latest_delivery.address_iv AS delivery_address_iv,
                  latest_delivery.address_tag AS delivery_address_tag,
                  latest_delivery.courier_name,
                  latest_delivery.shelf_number AS delivery_shelf_number,
                  latest_delivery.shelf_label AS delivery_shelf_label,
                  latest_delivery.bulky_places,
                  latest_delivery.bulky_note AS delivery_bulky_note,
                  latest_delivery.package_places,
                  cart_summary.bulky_titles AS cart_bulky_titles,
                  true AS is_member
           FROM chat_members cm
           JOIN users u ON u.id = cm.user_id
           LEFT JOIN phones ph ON ph.user_id = u.id
           LEFT JOIN user_shelves us ON us.user_id = u.id
           LEFT JOIN LATERAL (
             SELECT COALESCE(SUM(COALESCE(ci.custom_price, p.price) * ci.quantity), 0)::numeric AS total_sum,
                    STRING_AGG(DISTINCT p.title, ', ') FILTER (
                      WHERE COALESCE(ci.processing_mode, 'standard') = 'oversize'
                    ) AS bulky_titles
             FROM cart_items ci
             JOIN products p ON p.id = ci.product_id
             WHERE ci.user_id = u.id
               AND ci.status IN ('processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')
           ) AS cart_summary ON true
           LEFT JOIN LATERAL (
             SELECT a.address_text,
                    a.address_ciphertext,
                    a.address_iv,
                    a.address_tag
             FROM user_delivery_addresses a
             WHERE a.user_id = u.id
             ORDER BY a.is_default DESC, a.updated_at DESC
             LIMIT 1
           ) AS saved_addr ON true
           LEFT JOIN LATERAL (
             SELECT dbc.*
             FROM delivery_batch_customers dbc
             JOIN delivery_batches dbt ON dbt.id = dbc.batch_id
             WHERE dbc.user_id = u.id
             ORDER BY
               CASE dbt.status
                 WHEN 'calling' THEN 0
                 WHEN 'couriers_assigned' THEN 1
                 WHEN 'handed_off' THEN 2
                 WHEN 'completed' THEN 3
                 ELSE 4
               END,
               dbc.updated_at DESC
             LIMIT 1
           ) AS latest_delivery ON true
           WHERE cm.chat_id = $1 AND u.role = 'client'
           ORDER BY cm.joined_at DESC
           LIMIT 300`,
          [id],
        );
        clientsTotal = clientsQ.rowCount;
      } else {
        clientsQ = await db.query(
          `SELECT u.id::text AS user_id,
                  COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Клиент') AS name,
                  u.email,
                  u.client_city,
                  ph.phone,
                  COALESCE(cart_summary.total_sum, 0)::numeric AS cart_sum,
                  us.shelf_number,
                  saved_addr.address_text AS saved_address_text,
                  saved_addr.address_ciphertext AS saved_address_ciphertext,
                  saved_addr.address_iv AS saved_address_iv,
                  saved_addr.address_tag AS saved_address_tag,
                  latest_delivery.id::text AS delivery_customer_id,
                  latest_delivery.processed_sum,
                  latest_delivery.agreed_sum,
                  COALESCE(latest_delivery.agreed_sum, latest_delivery.processed_sum, 0)::numeric AS delivery_sum,
                  latest_delivery.address_text AS delivery_address_text,
                  latest_delivery.address_ciphertext AS delivery_address_ciphertext,
                  latest_delivery.address_iv AS delivery_address_iv,
                  latest_delivery.address_tag AS delivery_address_tag,
                  latest_delivery.courier_name,
                  latest_delivery.shelf_number AS delivery_shelf_number,
                  latest_delivery.shelf_label AS delivery_shelf_label,
                  latest_delivery.bulky_places,
                  latest_delivery.bulky_note AS delivery_bulky_note,
                  latest_delivery.package_places,
                  cart_summary.bulky_titles AS cart_bulky_titles,
                  EXISTS (
                    SELECT 1 FROM chat_members cm
                    WHERE cm.chat_id = $1 AND cm.user_id = u.id
                  ) AS is_member
           FROM users u
           LEFT JOIN phones ph ON ph.user_id = u.id
           LEFT JOIN user_shelves us ON us.user_id = u.id
           LEFT JOIN LATERAL (
             SELECT COALESCE(SUM(COALESCE(ci.custom_price, p.price) * ci.quantity), 0)::numeric AS total_sum,
                    STRING_AGG(DISTINCT p.title, ', ') FILTER (
                      WHERE COALESCE(ci.processing_mode, 'standard') = 'oversize'
                    ) AS bulky_titles
             FROM cart_items ci
             JOIN products p ON p.id = ci.product_id
             WHERE ci.user_id = u.id
               AND ci.status IN ('processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')
           ) AS cart_summary ON true
           LEFT JOIN LATERAL (
             SELECT a.address_text,
                    a.address_ciphertext,
                    a.address_iv,
                    a.address_tag
             FROM user_delivery_addresses a
             WHERE a.user_id = u.id
             ORDER BY a.is_default DESC, a.updated_at DESC
             LIMIT 1
           ) AS saved_addr ON true
           LEFT JOIN LATERAL (
             SELECT dbc.*
             FROM delivery_batch_customers dbc
             JOIN delivery_batches dbt ON dbt.id = dbc.batch_id
             WHERE dbc.user_id = u.id
             ORDER BY
               CASE dbt.status
                 WHEN 'calling' THEN 0
                 WHEN 'couriers_assigned' THEN 1
                 WHEN 'handed_off' THEN 2
                 WHEN 'completed' THEN 3
                 ELSE 4
               END,
               dbc.updated_at DESC
             LIMIT 1
           ) AS latest_delivery ON true
           WHERE u.role = 'client'
             AND u.tenant_id = $2
           ORDER BY u.created_at DESC
           LIMIT 300`,
          [id, req.user.tenant_id],
        );
        const clientsCountQ = await db.query(
          `SELECT COUNT(*)::int AS total
           FROM users
           WHERE role = 'client'
             AND tenant_id = $1`,
          [req.user.tenant_id],
        );
        clientsTotal = Number(clientsCountQ.rows[0]?.total || 0);
      }

      const clients = clientsQ.rows.map((row) => ({
        ...row,
        ...buildChannelClientExcelRow(row),
        is_blacklisted: blacklistedSet.has(String(row.user_id)),
      }));

      const mediaQ = await db.query(
        `SELECT m.id AS message_id,
                m.text,
                m.meta,
                m.created_at,
                u.id::text AS sender_id,
                COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Пользователь') AS sender_name,
                u.email AS sender_email
         FROM messages m
         LEFT JOIN users u ON u.id = m.sender_id
         WHERE m.chat_id = $1
           AND (
             COALESCE(m.meta->>'image_url', '') <> ''
             OR COALESCE(m.meta->>'product_image_url', '') <> ''
             OR COALESCE(m.meta->>'kind', '') = 'catalog_product'
           )
         ORDER BY m.created_at DESC
         LIMIT 120`,
        [id],
      );

      const media = mediaQ.rows
        .map((row) => {
          const meta = normalizeSettings(row.meta);
          const imageUrl =
            String(meta.image_url || "").trim() ||
            String(meta.product_image_url || "").trim() ||
            null;
          if (!imageUrl) return null;
          return {
            message_id: row.message_id,
            created_at: row.created_at,
            kind: String(meta.kind || "").trim(),
            image_url: imageUrl,
            text: String(row.text || "").trim(),
            sender_id: row.sender_id,
            sender_name: row.sender_name,
            sender_email: row.sender_email,
          };
        })
        .filter(Boolean);

      let blacklistedUsers = [];
      if (blacklistedUserIds.length > 0) {
        const validBlacklistedIds = normalizeUuidList(blacklistedUserIds);
        if (validBlacklistedIds.length > 0) {
          const usersQ = await db.query(
            `SELECT u.id::text AS user_id,
                    COALESCE(NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1), 'Пользователь') AS name,
                    u.email,
                    u.role,
                    ph.phone
             FROM users u
             LEFT JOIN phones ph ON ph.user_id = u.id
             WHERE u.id = ANY($1::uuid[])
               AND u.tenant_id = $2
             LIMIT 300`,
            [validBlacklistedIds, req.user.tenant_id],
          );
          const byId = new Map(usersQ.rows.map((u) => [String(u.user_id), u]));
          blacklistedUsers = blacklistEntries.map((entry) => ({
            ...entry,
            user: byId.get(String(entry.user_id)) || null,
          }));
        } else {
          blacklistedUsers = blacklistEntries.map((entry) => ({
            ...entry,
            user: null,
          }));
        }
      }

      const stats = {
        messages_total: Number(statsQ.rows[0]?.messages_total || 0),
        messages_24h: Number(statsQ.rows[0]?.messages_24h || 0),
        media_total: Number(statsQ.rows[0]?.media_total || 0),
        product_posts_total: Number(statsQ.rows[0]?.product_posts_total || 0),
        pending_posts_total: Number(queueQ.rows[0]?.pending_posts_total || 0),
        published_queue_total: Number(queueQ.rows[0]?.published_queue_total || 0),
        members_total: Number(membersQ.rowCount || 0),
        clients_total: Number(clientsTotal || 0),
        blacklisted_total: blacklistedUserIds.length,
        last_message_at: statsQ.rows[0]?.last_message_at || null,
      };

      const suggestedBlacklistUsers = clients
        .filter((u) => !u.is_blacklisted)
        .slice(0, 60);

      return res.json({
        ok: true,
        data: {
          channel: {
            ...channel,
            settings: {
              ...settings,
              avatar_focus_x: normalizeAvatarFocus(settings.avatar_focus_x, 0),
              avatar_focus_y: normalizeAvatarFocus(settings.avatar_focus_y, 0),
              avatar_zoom: normalizeAvatarZoom(settings.avatar_zoom, 1),
              blacklisted_user_ids: blacklistedUserIds,
              blacklist_entries: blacklistEntries,
            },
          },
          stats,
          members: membersQ.rows,
          clients,
          media,
          blacklist: blacklistedUsers,
          suggested_blacklist_users: suggestedBlacklistUsers,
        },
      });
    } catch (err) {
      console.error("admin.channels.overview error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Изменить имя клиента из списка клиентов канала
router.patch(
  "/channels/:id/clients/:userId/name",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id, userId } = req.params;
    const nextName = String(req.body?.name || "").trim();
    if (!isUuidLike(id) || !isUuidLike(userId)) {
      return res.status(400).json({ ok: false, error: "Некорректный id" });
    }
    if (nextName.length < 2 || nextName.length > 80) {
      return res.status(400).json({
        ok: false,
        error: "Имя должно содержать от 2 до 80 символов",
      });
    }

    try {
      const channelQ = await db.query(
        `SELECT id
         FROM chats
         WHERE id = $1
           AND type = 'channel'
           AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
      );
      if (channelQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const updatedQ = await db.query(
        `UPDATE users
         SET name = $1,
             updated_at = now()
         WHERE id = $2
           AND tenant_id = $3
           AND role = 'client'
         RETURNING id::text AS user_id, name, email, client_city`,
        [nextName, userId, req.user.tenant_id],
      );
      if (updatedQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Клиент не найден" });
      }

      const phoneQ = await db.query(
        `SELECT phone
         FROM phones
         WHERE user_id = $1
         LIMIT 1`,
        [userId],
      );
      const data = {
        ...updatedQ.rows[0],
        phone: phoneQ.rows[0]?.phone || null,
      };
      emitChannelMembersUpdated(req.app.get("io"), req.user?.tenant_id || null, id, {
        action: "client_name_updated",
        user_id: userId,
        name: nextName,
      });
      return res.json({ ok: true, data });
    } catch (err) {
      console.error("admin.channels.clientName.update error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Добавить пользователя в blacklist канала
router.post(
  "/channels/:id/blacklist",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    const userId = String(req.body?.user_id || "").trim();
    const reason = String(req.body?.reason || "").trim().slice(0, 240);
    if (!isUuidLike(userId)) {
      return res
        .status(400)
        .json({ ok: false, error: "user_id должен быть UUID" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const channelQ = await client.query(
        `SELECT id, title, settings
         FROM chats
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1
         FOR UPDATE`,
        [id, req.user.tenant_id],
      );
      if (channelQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const channel = channelQ.rows[0];
      const settings = normalizeSettings(channel.settings);
      if (isChannelReadOnlySystemChannel(channel, settings)) {
        await client.query("ROLLBACK");
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя редактировать" });
      }

      const userQ = await client.query(
        `SELECT id::text AS user_id, role, name, email
         FROM users
         WHERE id = $1::uuid
           AND tenant_id = $2
         LIMIT 1`,
        [userId, req.user.tenant_id],
      );
      if (userQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res
          .status(404)
          .json({ ok: false, error: "Пользователь не найден" });
      }
      const targetUser = userQ.rows[0];
      const targetRole = String(targetUser.role || "")
        .toLowerCase()
        .trim();
      if (targetRole === "admin" || targetRole === "creator") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Нельзя добавлять admin/creator в черный список",
        });
      }

      const currentEntries = normalizeBlacklistEntries(settings);
      const byUserId = new Map(
        currentEntries.map((entry) => [String(entry.user_id), entry]),
      );
      const nowIso = new Date().toISOString();
      byUserId.set(userId, {
        user_id: userId,
        added_at: nowIso,
        added_by: String(req.user.id || "").trim() || null,
        reason,
      });
      const nextSettings = applyBlacklistToSettings(
        {
          ...settings,
          avatar_focus_x: normalizeAvatarFocus(settings.avatar_focus_x, 0),
          avatar_focus_y: normalizeAvatarFocus(settings.avatar_focus_y, 0),
          avatar_zoom: normalizeAvatarZoom(settings.avatar_zoom, 1),
        },
        Array.from(byUserId.values()),
      );

      const updated = await client.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );

      // Если канал приватный и пользователь был участником — удаляем его.
      await client.query(
        `DELETE FROM chat_members
         WHERE chat_id = $1 AND user_id = $2::uuid`,
        [id, userId],
      );

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated.rows[0],
        });
        emitChannelUpdated(io, req.user?.tenant_id || null, id, {
          action: "blacklist_added",
          chat: updated.rows[0],
        });
        emitChannelMembersUpdated(io, req.user?.tenant_id || null, id, {
          action: "blacklist_added",
          user_id: userId,
        });
      }

      return res.json({
        ok: true,
        data: {
          channel: updated.rows[0],
          user: targetUser,
          blacklist_user_ids: nextSettings.blacklisted_user_ids,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.blacklist.add error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Удалить пользователя из blacklist канала
router.delete(
  "/channels/:id/blacklist/:userId",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id, userId } = req.params;
    if (!isUuidLike(userId)) {
      return res
        .status(400)
        .json({ ok: false, error: "userId должен быть UUID" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const channelQ = await client.query(
        `SELECT id, title, settings
         FROM chats
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1
         FOR UPDATE`,
        [id, req.user.tenant_id],
      );
      if (channelQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }
      const channel = channelQ.rows[0];
      const settings = normalizeSettings(channel.settings);
      if (isChannelReadOnlySystemChannel(channel, settings)) {
        await client.query("ROLLBACK");
        return res
          .status(403)
          .json({ ok: false, error: "Системный канал нельзя редактировать" });
      }

      const nextEntries = normalizeBlacklistEntries(settings).filter(
        (entry) => String(entry.user_id) !== String(userId),
      );
      const nextSettings = applyBlacklistToSettings(
        {
          ...settings,
          avatar_focus_x: normalizeAvatarFocus(settings.avatar_focus_x, 0),
          avatar_focus_y: normalizeAvatarFocus(settings.avatar_focus_y, 0),
          avatar_zoom: normalizeAvatarZoom(settings.avatar_zoom, 1),
        },
        nextEntries,
      );

      const updated = await client.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated.rows[0],
        });
        emitChannelUpdated(io, req.user?.tenant_id || null, id, {
          action: "blacklist_removed",
          chat: updated.rows[0],
        });
        emitChannelMembersUpdated(io, req.user?.tenant_id || null, id, {
          action: "blacklist_removed",
          user_id: userId,
        });
      }

      return res.json({
        ok: true,
        data: {
          channel: updated.rows[0],
          blacklist_user_ids: nextSettings.blacklisted_user_ids,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.blacklist.remove error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Загрузить/обновить аватарку канала
router.post(
  "/channels/:id/avatar",
  requireAuth,
  requireRole("admin", "creator"),
  uploadChannelAvatar,
  async (req, res) => {
    const { id } = req.params;
    const uploadedUrl = toChannelAvatarUrl(req, req.file);
    if (!uploadedUrl) {
      return res.status(400).json({ ok: false, error: "Файл аватарки обязателен" });
    }
    try {
      const current = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
         FROM chats
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
      );
      if (current.rowCount === 0) {
        removeUploadedFile(req.file);
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }

      const currentRow = current.rows[0];
      const settings = normalizeSettings(currentRow.settings);
      const nextSettings = { ...settings, avatar_url: uploadedUrl };
      const previousAvatar = String(settings.avatar_url || "").trim();

      const upd = await db.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );
      const updated = upd.rows[0];
      await registerPublicImageUpload({
        queryable: db,
        ownerKind: "channel_avatar",
        ownerId: id,
        rawUrl: uploadedUrl,
      });

      if (previousAvatar && previousAvatar !== uploadedUrl) {
        removeChannelAvatarByUrl(previousAvatar);
      }

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated,
        });
        emitChannelUpdated(io, req.user?.tenant_id || null, id, {
          action: "avatar_updated",
          chat: updated,
        });
        emitChannelMediaUpdated(io, req.user?.tenant_id || null, id, {
          action: "avatar_updated",
        });
      }

      return res.json({ ok: true, data: updated });
    } catch (err) {
      removeUploadedFile(req.file);
      console.error("admin.channels.avatar error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Удалить аватарку канала
router.delete(
  "/channels/:id/avatar",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { id } = req.params;
    try {
      const current = await db.query(
        `SELECT id, title, type, created_by, settings, created_at, updated_at
         FROM chats
         WHERE id = $1 AND type = 'channel' AND tenant_id = $2
         LIMIT 1`,
        [id, req.user.tenant_id],
      );
      if (current.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Канал не найден" });
      }
      const currentRow = current.rows[0];
      const settings = normalizeSettings(currentRow.settings);
      const previousAvatar = String(settings.avatar_url || "").trim();
      const nextSettings = { ...settings, avatar_url: "" };

      const upd = await db.query(
        `UPDATE chats
         SET settings = $1::jsonb,
             updated_at = now()
         WHERE id = $2 AND tenant_id = $3
         RETURNING id, title, type, created_by, settings, created_at, updated_at`,
        [JSON.stringify(nextSettings), id, req.user.tenant_id],
      );
      const updated = upd.rows[0];

      if (previousAvatar) {
        removeChannelAvatarByUrl(previousAvatar);
      }

      const io = req.app.get("io");
      if (io) {
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chat: updated,
        });
        emitChannelUpdated(io, req.user?.tenant_id || null, id, {
          action: "avatar_removed",
          chat: updated,
        });
        emitChannelMediaUpdated(io, req.user?.tenant_id || null, id, {
          action: "avatar_removed",
        });
      }

      return res.json({ ok: true, data: updated });
    } catch (err) {
      console.error("admin.channels.avatar.remove error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Назначить каналом для публикации товаров (эксклюзивный выбор)
router.post(
  "/channels/:id/set_post_channel",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    return res.status(410).json({
      ok: false,
      error:
        "Функция выбора канала публикации отключена. Публикация идет только в Основной канал.",
    });
  },
);

// Очередь постов от worker (ожидают подтверждения)
router.get(
  "/channels/pending_posts",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireProductPublishPermission,
  async (req, res) => {
    try {
      const [result, reservedStatsQ, activePublishBatches] = await runInRequestTenantScope(
        req,
        async () => {
          const pendingRows = await db.query(
            `SELECT q.id,
                  q.product_id,
                  q.channel_id,
                  q.queued_by,
                  q.status,
                  q.is_sent,
                  q.publish_batch_id,
                  q.publish_order,
                  COALESCE(q.publish_status, 'pending') AS publish_status,
                  q.publish_started_at,
                  q.publish_finished_at,
                  q.publish_error_code,
                  q.publish_error_message,
                  q.payload,
                  q.created_at,
                  c.title AS channel_title,
                  COALESCE(NULLIF(BTRIM(q.payload->>'title'), ''), p.title) AS product_title,
                  COALESCE(NULLIF(BTRIM(q.payload->>'description'), ''), p.description) AS product_description,
                  COALESCE(NULLIF(q.payload->>'price', '')::numeric, p.price) AS product_price,
                  COALESCE(NULLIF(q.payload->>'quantity', '')::int, p.quantity) AS product_quantity,
                  p.shelf_number AS product_shelf_number,
                  COALESCE(NULLIF(BTRIM(q.payload->>'manual_shelf_label'), ''), p.manual_shelf_label) AS manual_shelf_label,
                  COALESCE(NULLIF(BTRIM(q.payload->>'shelf_floor'), ''), p.shelf_floor) AS shelf_floor,
                  COALESCE(q.pickup_only, p.pickup_only, false) AS pickup_only,
                  COALESCE(NULLIF(BTRIM(q.payload->>'image_url'), ''), p.image_url) AS product_image_url,
                  p.product_code,
                  u.email AS queued_by_email,
                  u.name AS queued_by_name
           FROM product_publication_queue q
           JOIN chats c ON c.id = q.channel_id
           JOIN products p ON p.id = q.product_id
           LEFT JOIN users u ON u.id = q.queued_by
           WHERE q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
             AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
           ORDER BY q.created_at ASC, q.id ASC`,
            [req.user.tenant_id || null],
          );
          const reservedStats = await db.query(
            `SELECT COUNT(*)::int AS total,
                    COALESCE(SUM(quantity), 0)::int AS units
             FROM reservations r
             JOIN users u ON u.id = r.user_id
             WHERE r.is_fulfilled = false
               AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)`,
            [req.user.tenant_id || null],
          );
          const activeBatches = await listActivePublicationBatches(
            db,
            req.user.tenant_id || null,
          );
          return [pendingRows, reservedStats, activeBatches];
        },
      );
      const publishingSummary = buildPublicationSummary(activePublishBatches);
      return res.json({
        ok: true,
        data: result.rows,
        meta: {
          reserved_pending_total: Number(reservedStatsQ.rows[0]?.total || 0),
          reserved_pending_units: Number(reservedStatsQ.rows[0]?.units || 0),
          active_publish_batch:
            activePublishBatches.length === 1 ? activePublishBatches[0] : null,
          active_publish_batches: activePublishBatches,
          publishing_summary: publishingSummary,
        },
      });
    } catch (err) {
      console.error("admin.channels.pending_posts error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/channels/publish_batches/:batchId",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireProductPublishPermission,
  async (req, res) => {
    const batchId = String(req.params.batchId || "").trim();
    if (!batchId) {
      return res.status(400).json({ ok: false, error: "batchId обязателен" });
    }
    try {
      const batch = await runInRequestTenantScope(req, async () =>
        getChannelPublicationBatch(db, batchId, req.user.tenant_id || null),
      );
      if (!batch) {
        return res.status(404).json({
          ok: false,
          error: "Пакет публикации не найден",
        });
      }
      return res.json({ ok: true, data: batch });
    } catch (err) {
      console.error("admin.channels.publish_batch_status error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/channels/pending_posts/:queueId",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireProductPublishPermission,
  async (req, res) => {
    const queueId = String(req.params.queueId || "").trim();
    const title = normalizeCatalogTitle(req.body?.title || "");
    const description = String(req.body?.description || "").trim();
    const price = Number(req.body?.price);
    const quantity = Number(req.body?.quantity);
    const rawShelfNumber = Number(req.body?.shelf_number);
    const shelfNumber =
      Number.isFinite(rawShelfNumber) && rawShelfNumber > 0
        ? Math.floor(rawShelfNumber)
        : null;

    if (!queueId) {
      return res.status(400).json({ ok: false, error: "queueId обязателен" });
    }
    if (!title) {
      return res
        .status(400)
        .json({ ok: false, error: "Название товара обязательно" });
    }
    if (!description || description.length < 2) {
      return res.status(400).json({
        ok: false,
        error: "Описание должно содержать минимум 2 символа",
      });
    }
    if (!Number.isFinite(price) || price <= 0) {
      return res
        .status(400)
        .json({ ok: false, error: "Цена должна быть больше нуля" });
    }
    if (!Number.isFinite(quantity) || quantity <= 0) {
      return res
        .status(400)
        .json({ ok: false, error: "Количество должно быть больше нуля" });
    }
    try {
      const updated = await runInRequestTenantScope(req, async () =>
        db.query(
          `UPDATE product_publication_queue q
           SET payload = jsonb_strip_nulls(
                 COALESCE(q.payload, '{}'::jsonb) ||
                 jsonb_build_object(
                   'title', $2::text,
                   'description', $3::text,
                   'price', $4::numeric,
                   'quantity', $5::int,
                   'shelf_number', COALESCE($6::int, NULLIF(q.payload->>'shelf_number', '')::int),
                   'image_url', NULLIF(BTRIM(COALESCE(q.payload->>'image_url', '')), '')
                 )
               )
           WHERE q.id = $1
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
             AND COALESCE(q.publish_status, 'pending') NOT IN ('queued', 'publishing')
             AND EXISTS (
               SELECT 1
               FROM chats c
               WHERE c.id = q.channel_id
                 AND ($7::uuid IS NULL OR c.tenant_id = $7::uuid)
             )
           RETURNING q.id`,
          [
            queueId,
            title,
            description,
            price,
            Math.floor(quantity),
            shelfNumber,
            req.user.tenant_id || null,
          ],
        ),
      );
      if (updated.rowCount === 0) {
        const stateQ = await runInRequestTenantScope(req, async () =>
          db.query(
            `SELECT COALESCE(q.publish_status, 'pending') AS publish_status
             FROM product_publication_queue q
             WHERE q.id = $1
               AND EXISTS (
                 SELECT 1
                 FROM chats c
                 WHERE c.id = q.channel_id
                   AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
               )
             LIMIT 1`,
            [queueId, req.user.tenant_id || null],
          ),
        );
        const publishStatus = String(
          stateQ.rows[0]?.publish_status || "",
        ).trim();
        if (["queued", "publishing"].includes(publishStatus)) {
          return res.status(409).json({
            ok: false,
            error: "Пост уже стоит в очереди публикации и сейчас недоступен для изменения",
          });
        }
        return res.status(404).json({
          ok: false,
          error: "Пост не найден или уже опубликован",
        });
      }
      emitCatalogQueueUpdated(req.app.get("io"), req.user?.tenant_id || null, {
        action: "admin_updated",
        queue_id: queueId,
      });
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.channels.pending_posts.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/channels/pending_posts/:queueId",
  requireAuth,
  requireRole("admin", "creator"),
  requireProductPublishPermission,
  async (req, res) => {
    const queueId = String(req.params.queueId || "").trim();
    if (!queueId) {
      return res.status(400).json({ ok: false, error: "queueId обязателен" });
    }
    try {
      const client = await db.pool.connect();
      let restoredMessages = [];
      let channelId = null;
      try {
        await client.query("BEGIN");
        const pendingQ = await client.query(
          `SELECT q.id,
                  q.channel_id,
                  q.payload
           FROM product_publication_queue q
           WHERE q.id = $1
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
             AND COALESCE(q.publish_status, 'pending') NOT IN ('queued', 'publishing')
             AND EXISTS (
               SELECT 1
               FROM chats c
               WHERE c.id = q.channel_id
                 AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
             )
           LIMIT 1
           FOR UPDATE`,
          [queueId, req.user.tenant_id || null],
        );
        if (pendingQ.rowCount === 0) {
          const stateQ = await client.query(
            `SELECT COALESCE(q.publish_status, 'pending') AS publish_status
             FROM product_publication_queue q
             WHERE q.id = $1
               AND EXISTS (
                 SELECT 1
                 FROM chats c
                 WHERE c.id = q.channel_id
                   AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
               )
             LIMIT 1`,
            [queueId, req.user.tenant_id || null],
          );
          await client.query("ROLLBACK");
          if (
            ["queued", "publishing"].includes(
              String(stateQ.rows[0]?.publish_status || "").trim(),
            )
          ) {
            return res.status(409).json({
              ok: false,
              error: "Пост уже стоит в очереди публикации и сейчас недоступен для удаления",
            });
          }
          return res.status(404).json({
            ok: false,
            error: "Пост не найден или уже опубликован",
          });
        }

        const row = pendingQ.rows[0];
        channelId = String(row.channel_id || "").trim() || null;
        const payload = row.payload && typeof row.payload === "object" ? row.payload : {};
        const sourceMessageIds = Array.from(
          new Set(
            [
              ...(Array.isArray(payload.source_message_ids) ? payload.source_message_ids : []),
              payload.source_message_id,
            ]
              .map((value) => String(value || "").trim())
              .filter(Boolean),
          ),
        );

        const isRevisionQueue =
          payload.revision_manual === true || payload.revision_auto === true;
        if (isRevisionQueue && channelId && sourceMessageIds.length > 0) {
          const restoredQ = await client.query(
            `UPDATE messages
             SET meta = jsonb_set(
                   (COALESCE(meta, '{}'::jsonb)
                     - 'hidden_by_revision'
                     - 'hidden_by_revision_at'
                     - 'hidden_by_revision_actor_id'),
                   '{hidden_for_all}',
                   'false'::jsonb,
                   true
                 )
             WHERE chat_id = $1
               AND id = ANY($2::uuid[])
               AND COALESCE((meta->>'hidden_by_revision')::boolean, false) = true
             RETURNING id, chat_id, sender_id, text, meta, created_at`,
            [channelId, sourceMessageIds],
          );
          restoredMessages = restoredQ.rows;
        }

        await client.query(
          `DELETE FROM product_publication_queue
           WHERE id = $1`,
          [queueId],
        );
        if (channelId) {
          await client.query(
            "UPDATE chats SET updated_at = now() WHERE id = $1",
            [channelId],
          );
        }
        await client.query("COMMIT");
      } catch (err) {
        try {
          await client.query("ROLLBACK");
        } catch (_) {}
        throw err;
      } finally {
        client.release();
      }

      const io = req.app.get("io");
      if (io && channelId) {
        for (const message of restoredMessages) {
          io.to(`chat:${channelId}`).emit("chat:message", {
            chatId: channelId,
            message: decryptMessageRow(message),
          });
        }
        emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
          chatId: channelId,
        });
        emitCatalogQueueUpdated(io, req.user?.tenant_id || null, {
          action: "admin_deleted",
          channel_id: channelId,
          queue_id: queueId,
        });
      }
      return res.json({
        ok: true,
        data: {
          restored_count: restoredMessages.length,
        },
      });
    } catch (err) {
      console.error("admin.channels.pending_posts.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

// Отправить заказы клиентов в канал "Забронированный товар"
router.post(
  "/orders/dispatch_reserved",
  requireAuth,
  requireRole("admin", "creator"),
  requireReservationFulfillPermission,
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(
        `SELECT pg_advisory_xact_lock(hashtext($1), 0)`,
        [`dispatch-reserved:${req.user.tenant_id || "global"}`],
      );
      const { reservedChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );

      const ordersQ = await client.query(
        `SELECT r.id AS reservation_id,
                r.user_id,
                r.product_id,
                r.cart_item_id,
                r.quantity,
                r.is_fulfilled,
                r.is_sent,
                p.product_code,
                p.shelf_number AS product_shelf_number,
                p.manual_shelf_label,
                COALESCE(p.pickup_only, false) AS pickup_only,
                p.title AS product_title,
                p.description AS product_description,
                p.price AS product_price,
                p.image_url AS product_image_url,
                u.name AS client_name,
                ph.phone AS client_phone,
                regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g') AS client_phone_digits,
                us.shelf_number,
                NULLIF(BTRIM(us.shelf_label), '') AS shelf_label
         FROM reservations r
         JOIN products p ON p.id = r.product_id
         JOIN users u ON u.id = r.user_id
         LEFT JOIN phones ph ON ph.user_id = r.user_id
         LEFT JOIN user_shelves us ON us.user_id = r.user_id
         WHERE r.is_fulfilled = false
           AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
         ORDER BY DATE(COALESCE(r.created_at, now())) ASC,
                  CASE
                    WHEN NULLIF(BTRIM(us.shelf_label), '') ~ '^-?\\d+$' THEN 0
                    WHEN NULLIF(BTRIM(us.shelf_label), '') IS NOT NULL THEN 1
                    ELSE 2
                  END ASC,
                  CASE
                    WHEN NULLIF(BTRIM(us.shelf_label), '') ~ '^-?\\d+$'
                      THEN (NULLIF(BTRIM(us.shelf_label), ''))::int
                    ELSE NULL
                  END ASC NULLS LAST,
                  lower(COALESCE(NULLIF(BTRIM(us.shelf_label), ''), us.shelf_number::text, p.shelf_number::text, '')) ASC,
                  COALESCE(us.shelf_number, p.shelf_number, 2147483647) ASC,
                  CASE
                    WHEN regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g') = '' THEN '89999999999'
                    WHEN length(regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g')) = 10
                      THEN '8' || regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g')
                    WHEN regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g') ~ '^7\\d{10}$'
                      THEN '8' || substr(regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g'), 2)
                    ELSE regexp_replace(COALESCE(ph.phone, ''), '\\D+', '', 'g')
                  END ASC,
                  lower(COALESCE(u.name, '')) ASC,
                  r.created_at ASC,
                  r.id ASC
         FOR UPDATE OF r`,
        [req.user.tenant_id || null],
      );

      const dispatched = [];
      for (const row of ordersQ.rows) {
        const meta = {
          kind: "reserved_order_item",
          reservation_id: row.reservation_id,
          cart_item_id: row.cart_item_id,
          user_id: row.user_id,
          product_id: row.product_id,
          product_code: row.product_code,
          product_label: formatProductLabel(
            row.product_code,
            row.product_shelf_number,
            row.manual_shelf_label,
          ),
          product_shelf_number: row.product_shelf_number,
          manual_shelf_label: row.manual_shelf_label || null,
          pickup_only: row.pickup_only === true,
          title: row.product_title,
          description: row.product_description,
          price: Number(row.product_price),
          quantity: Number(row.quantity),
          image_url: row.product_image_url,
          client_name: row.client_name || "—",
          client_phone: formatPhoneForDisplay(row.client_phone),
          shelf_number: row.shelf_number,
          shelf_label: row.shelf_label,
          placed: false,
          resent: row.is_sent === true,
        };

        const messageInsert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, $3, $4, $5::jsonb, now())
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [
            uuidv4(),
            reservedChannel.id,
            null,
            encryptMessageText(reservedOrderMessageText(row)),
            JSON.stringify(meta),
          ],
        );

        await client.query(
          `UPDATE reservations
           SET is_sent = true,
               sent_at = now(),
               reserved_channel_message_id = $2,
               updated_at = now()
           WHERE id = $1`,
          [row.reservation_id, messageInsert.rows[0].id],
        );

        if (row.cart_item_id) {
          await client.query(
            `UPDATE cart_items
             SET reserved_sent_at = now(),
                 updated_at = now()
             WHERE id = $1`,
            [row.cart_item_id],
          );
        }

        dispatched.push({
          reservation_id: row.reservation_id,
          cart_item_id: row.cart_item_id,
          message_id: messageInsert.rows[0].id,
          user_id: row.user_id,
          shelf_number: row.shelf_number,
          shelf_label: row.shelf_label,
          product_code: row.product_code,
          product_shelf_number: row.product_shelf_number,
          quantity: Number(row.quantity),
          client_name: row.client_name || "—",
        });
      }

      if (dispatched.length > 0) {
        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          reservedChannel.id,
        ]);
      }

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io && dispatched.length > 0) {
        for (const item of dispatched) {
          const msgRes = await db.query(
            "SELECT id, chat_id, sender_id, text, meta, created_at FROM messages WHERE id = $1 LIMIT 1",
            [item.message_id],
          );
          if (msgRes.rowCount > 0) {
            io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
              chatId: reservedChannel.id,
              message: decryptMessageRow(msgRes.rows[0]),
            });
            emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
              chatId: reservedChannel.id,
            });
            emitReservedOrderUpdated(io, req.user?.tenant_id || null, reservedChannel.id, {
              action: "dispatched",
              message_id: item.message_id,
              reservation_id: item.reservation_id,
              cart_item_id: item.cart_item_id,
              user_id: item.user_id,
              shelf_number: item.shelf_number,
              shelf_label: item.shelf_label,
            });
          }
        }
      }

      return res.json({
        ok: true,
        data: {
          channel_id: reservedChannel.id,
          dispatched_count: dispatched.length,
          orders: dispatched,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.orders.dispatch_reserved error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/orders/change_shelf",
  requireAuth,
  requireRole("admin", "creator"),
  requireReservationFulfillPermission,
  async (req, res) => {
    const reservationId = String(req.body?.reservation_id || "").trim();
    const cartItemId = String(req.body?.cart_item_id || "").trim();
    const shelfLabel = normalizeShelfLabel(req.body?.shelf_number);
    const shelfNumber = parsePositiveShelfNumber(req.body?.shelf_number);

    if (!reservationId && !cartItemId) {
      return res
        .status(400)
        .json({ ok: false, error: "reservation_id или cart_item_id обязателен" });
    }
    if (!shelfLabel) {
      return res
        .status(400)
        .json({ ok: false, error: "Укажите корректную полку" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      await acquireReservationOperationLock(client, {
        reservationId,
        cartItemId,
        tenantId: req.user.tenant_id || null,
      });
      const { reservedChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );

      const reservationQ = await client.query(
        `SELECT r.id,
                r.user_id,
                r.cart_item_id
         FROM reservations r
         JOIN users buyer ON buyer.id = r.user_id
         WHERE (
           ($1::uuid IS NOT NULL AND r.id = $1::uuid)
           OR
           ($1::uuid IS NULL AND $2::uuid IS NOT NULL AND r.cart_item_id = $2::uuid)
         )
           AND ($3::uuid IS NULL OR buyer.tenant_id = $3::uuid)
         ORDER BY r.created_at DESC
         LIMIT 1
         FOR UPDATE OF r`,
        [reservationId || null, cartItemId || null, req.user.tenant_id || null],
      );
      if (reservationQ.rowCount === 0) {
        const cancelledReservedQ = await client.query(
          `SELECT id
           FROM messages
           WHERE chat_id = $1
             AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
             AND (
               COALESCE(meta->>'reservation_id', '') = $2
               OR ($3 <> '' AND COALESCE(meta->>'cart_item_id', '') = $3)
             )
             AND lower(COALESCE(meta->>'client_cancelled', 'false')) = 'true'
           ORDER BY created_at DESC
           LIMIT 1`,
          [reservedChannel.id, reservationId || '', cartItemId || ''],
        );
        await client.query("ROLLBACK");
        if (cancelledReservedQ.rowCount > 0) {
          return res.status(409).json({
            ok: false,
            code: "client_cancelled",
            error: "Клиент отказался от товара",
          });
        }
        return res.status(404).json({ ok: false, error: "Резерв не найден" });
      }

      const item = reservationQ.rows[0];
      const userIdText = String(item.user_id || "").trim();
      await client.query(
        `INSERT INTO user_shelves (user_id, shelf_number, shelf_label, created_at, updated_at)
         VALUES ($1, $2, $3, now(), now())
         ON CONFLICT (user_id) DO UPDATE
           SET shelf_number = EXCLUDED.shelf_number,
               shelf_label = EXCLUDED.shelf_label,
               updated_at = now()`,
        [userIdText, shelfNumber, shelfLabel],
      );

      const updatedReservedMessages = await client.query(
        `UPDATE messages
         SET meta = jsonb_set(
               jsonb_set(
                 COALESCE(meta, '{}'::jsonb),
                 '{shelf_number}',
                 CASE
                   WHEN $2::int IS NULL THEN 'null'::jsonb
                   ELSE to_jsonb($2::int)
                 END,
                 true
               ),
               '{shelf_label}',
               to_jsonb($3::text),
               true
             )
         WHERE chat_id = $1
           AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
           AND COALESCE(meta->>'user_id', '') = $4
           AND lower(COALESCE(meta->>'processing_mode', 'standard')) <> 'oversize'
           AND lower(COALESCE(meta->>'placed', 'false')) <> 'true'
           AND lower(COALESCE(meta->>'client_cancelled', 'false')) <> 'true'
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
        [reservedChannel.id, shelfNumber, shelfLabel, userIdText],
      );

      const updatedDeliveryCustomers = await client.query(
        `UPDATE delivery_batch_customers c
         SET shelf_number = $1,
             shelf_label = $2,
             updated_at = now()
         WHERE c.user_id = $3::uuid
           AND EXISTS (
             SELECT 1
             FROM delivery_batches b
             JOIN users u ON u.id = c.user_id
             WHERE b.id = c.batch_id
               AND b.status IN ('calling', 'couriers_assigned', 'handed_off')
               AND ($4::uuid IS NULL OR u.tenant_id = $4::uuid)
           )
         RETURNING c.batch_id::text AS batch_id`,
        [shelfNumber, shelfLabel, userIdText, req.user.tenant_id || null],
      );

      if (updatedReservedMessages.rowCount > 0) {
        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          reservedChannel.id,
        ]);
      }

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const message of updatedReservedMessages.rows) {
          io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
            chatId: reservedChannel.id,
            message: decryptMessageRow(message),
          });
          emitReservedOrderUpdated(io, req.user?.tenant_id || null, reservedChannel.id, {
            action: "shelf_changed",
            message_id: message.id,
            user_id: userIdText,
            shelf_number: shelfNumber,
            shelf_label: shelfLabel,
          });
        }
        if (updatedReservedMessages.rowCount > 0) {
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId: reservedChannel.id,
          });
        }
        emitToTenant(io, req.user?.tenant_id || null, "delivery:updated", {
          batchId: "reset",
          updatedAt: new Date().toISOString(),
        });
        io.to(`user:${userIdText}`).emit("cart:updated", {
          userId: userIdText,
          shelf_number: shelfNumber,
          shelf_label: shelfLabel,
          reason: "shelf_changed",
        });
      }

      return res.json({
        ok: true,
        data: {
          reservation_id: String(item.id),
          cart_item_id: item.cart_item_id ? String(item.cart_item_id) : null,
          user_id: userIdText,
          shelf_number: shelfNumber,
          shelf_label: shelfLabel,
          shelf_display: shelfLabel,
          updated_reserved_messages: updatedReservedMessages.rowCount,
          updated_delivery_customers: updatedDeliveryCustomers.rowCount,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.orders.change_shelf error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Отметить товар как "положил" (обработан)
router.post(
  "/orders/mark_placed",
  requireAuth,
  requireRole("admin", "creator"),
  requireReservationFulfillPermission,
  async (req, res) => {
    const reservationId = String(req.body?.reservation_id || "").trim();
    const cartItemId = String(req.body?.cart_item_id || "").trim();
    const processingModeRaw = String(req.body?.processing_mode || "standard")
      .trim()
      .toLowerCase();
    const manualShelfLabel = normalizeShelfLabel(req.body?.shelf_number);
    const manualShelfNumber = parsePositiveShelfNumber(req.body?.shelf_number);
    if (
      processingModeRaw !== "standard" &&
      processingModeRaw !== "oversize"
    ) {
      return res.status(400).json({
        ok: false,
        error: "Некорректный processing_mode",
      });
    }
    const processingMode = processingModeRaw;
    // Для габаритного товара полка не спрашивается:
    // он уходит в отдельную зону логистики.
    const requiresManualShelf = processingMode !== "oversize";

    if (!reservationId && !cartItemId) {
      return res
        .status(400)
        .json({ ok: false, error: "reservation_id или cart_item_id обязателен" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { reservedChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );

      const reservationQ = await client.query(
        `SELECT r.id,
                r.user_id,
                r.product_id,
                r.cart_item_id,
                r.quantity,
                r.is_fulfilled,
                c.status AS cart_status,
                c.processing_mode AS cart_processing_mode,
                p.product_code,
                p.title,
                p.price
         FROM reservations r
         LEFT JOIN cart_items c ON c.id = r.cart_item_id
         JOIN products p ON p.id = r.product_id
         JOIN users buyer ON buyer.id = r.user_id
         WHERE (
           ($1::uuid IS NOT NULL AND r.id = $1::uuid)
           OR
           ($1::uuid IS NULL AND $2::uuid IS NOT NULL AND r.cart_item_id = $2::uuid)
         )
           AND ($3::uuid IS NULL OR buyer.tenant_id = $3::uuid)
         ORDER BY r.created_at DESC
         LIMIT 1
         FOR UPDATE OF r`,
        [reservationId || null, cartItemId || null, req.user.tenant_id || null],
      );
      if (reservationQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Резерв не найден" });
      }
      const item = reservationQ.rows[0];
      const targetCartItemId = item.cart_item_id ? String(item.cart_item_id) : "";
      const carryShelfQ = await client.query(
        `SELECT NULLIF(BTRIM(COALESCE(meta->>'shelf_label', '')), '') AS shelf_label,
                CASE
                  WHEN COALESCE(meta->>'shelf_number', '') ~ '^-?\\d+$'
                    THEN (meta->>'shelf_number')::int
                  ELSE NULL
                END AS shelf_number,
                NULLIF(BTRIM(COALESCE(meta->>'processing_mode', '')), '') AS processing_mode,
                NULLIF(BTRIM(COALESCE(meta->>'processed_by_name', '')), '') AS processed_by_name
         FROM messages
         WHERE chat_id = $1
           AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
           AND (
             COALESCE(meta->>'reservation_id', '') = $2
             OR ($3 <> '' AND COALESCE(meta->>'cart_item_id', '') = $3)
           )
           AND (
             NULLIF(BTRIM(COALESCE(meta->>'shelf_label', '')), '') IS NOT NULL
             OR COALESCE(meta->>'shelf_number', '') ~ '^-?\\d+$'
           )
         ORDER BY created_at DESC
         LIMIT 1`,
        [reservedChannel.id, String(item.id), targetCartItemId],
      );

      const activeShelfContextQ = await client.query(
        `SELECT 1
         FROM cart_items
         WHERE user_id = $1
           AND status = ANY($2::text[])
         LIMIT 1`,
        [String(item.user_id), ["processed", "preparing_delivery", "handing_to_courier"]],
      );
      const hasActiveShelfContext = activeShelfContextQ.rowCount > 0;
      const messageShelfLabel = carryShelfQ.rowCount > 0
        ? displayShelfValue(
            carryShelfQ.rows[0]?.shelf_label,
            carryShelfQ.rows[0]?.shelf_number,
          )
        : null;

      let persistedUserShelfLabel = null;
      let persistedUserShelfNumber = null;
      if (hasActiveShelfContext) {
        const userShelfQ = await client.query(
          `SELECT shelf_number, shelf_label
           FROM user_shelves
           WHERE user_id = $1
           LIMIT 1`,
          [String(item.user_id)],
        );
        if (userShelfQ.rowCount > 0) {
          const parsed = Number(userShelfQ.rows[0]?.shelf_number);
          persistedUserShelfNumber =
            Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : null;
          persistedUserShelfLabel = displayShelfValue(
            userShelfQ.rows[0]?.shelf_label,
            userShelfQ.rows[0]?.shelf_number,
          );
        }
      }

      const existingShelfLabel =
        messageShelfLabel && messageShelfLabel !== "не назначена"
          ? messageShelfLabel
          : persistedUserShelfLabel;
      const existingShelfNumber = messageShelfLabel && messageShelfLabel !== "не назначена"
        ? parsePositiveShelfNumber(messageShelfLabel)
        : persistedUserShelfNumber;
      const canReuseExistingShelf =
        existingShelfLabel != null && existingShelfLabel !== "не назначена";
      const existingProcessingMode =
        String(carryShelfQ.rows[0]?.processing_mode || item.cart_processing_mode || processingMode)
          .trim()
          .toLowerCase() || processingMode;
      const existingProcessedByName = String(
        carryShelfQ.rows[0]?.processed_by_name || "",
      ).trim();
      if (item.is_fulfilled === true) {
        let resolvedProcessingMode =
          existingProcessingMode === "oversize" ? "oversize" : "standard";
        if (processingMode === "oversize" && resolvedProcessingMode !== "oversize") {
          if (targetCartItemId) {
            await client.query(
              `UPDATE cart_items
               SET processing_mode = 'oversize',
                   updated_at = now()
               WHERE id = $1`,
              [targetCartItemId],
            );
          }

          const updatedReservedMessages = await client.query(
            `UPDATE messages
             SET meta = COALESCE(meta, '{}'::jsonb) || jsonb_build_object(
                   'placed', true,
                   'processing_mode', 'oversize',
                   'is_oversize', true,
                   'processed_by_id', $2::text,
                   'processed_by_name', $3::text
                 )
             WHERE chat_id = $1
               AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
               AND (
                 COALESCE(meta->>'reservation_id', '') = $4
                 OR ($5 <> '' AND COALESCE(meta->>'cart_item_id', '') = $5)
               )
             RETURNING id, chat_id, sender_id, text, meta, created_at`,
            [
              reservedChannel.id,
              String(req.user.id),
              existingProcessedByName,
              String(item.id),
              targetCartItemId,
            ],
          );

          await client.query("COMMIT");

          const io = req.app.get("io");
          if (io) {
            for (const message of updatedReservedMessages.rows) {
              io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
                chatId: reservedChannel.id,
                message: decryptMessageRow(message),
              });
              emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
                chatId: reservedChannel.id,
              });
              emitReservedOrderUpdated(io, req.user?.tenant_id || null, reservedChannel.id, {
                action: "oversize_after_processed",
                message_id: message.id,
                reservation_id: item.id,
                cart_item_id: targetCartItemId || null,
                user_id: item.user_id,
                shelf_number: existingShelfNumber,
                shelf_label: existingShelfLabel,
                processing_mode: "oversize",
              });
            }
            io.to(`user:${item.user_id}`).emit("cart:updated", {
              userId: String(item.user_id),
              product_id: item.product_id ? String(item.product_id) : "",
              cart_item_id: targetCartItemId || null,
              status: "processed",
              shelf_number: existingShelfNumber,
              shelf_label: existingShelfLabel,
              processing_mode: "oversize",
              processed_by_name: existingProcessedByName,
              reason: "item_marked_oversize_after_processed",
            });
          }

          return res.json({
            ok: true,
            data: {
              reservation_id: item.id,
              cart_item_id: targetCartItemId || null,
              status: "processed",
              shelf_number: existingShelfNumber,
              shelf_label: existingShelfLabel,
              shelf_display: displayShelfValue(
                existingShelfLabel,
                existingShelfNumber,
              ),
              processing_mode: "oversize",
              processed_by_name: existingProcessedByName,
            },
          });
        }
        await client.query("ROLLBACK");
        return res.json({
          ok: true,
          data: {
            reservation_id: item.id,
            cart_item_id: targetCartItemId || null,
            status: "processed",
            shelf_number: existingShelfNumber,
            shelf_label: existingShelfLabel,
            shelf_display: displayShelfValue(
              existingShelfLabel,
              existingShelfNumber,
            ),
            processing_mode:
              existingProcessingMode === "oversize" ? "oversize" : "standard",
            processed_by_name: existingProcessedByName,
          },
        });
      }
      if (requiresManualShelf && !manualShelfLabel && !canReuseExistingShelf) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          code: "manual_shelf_required",
          error: "Для первого товара в корзине нужно вручную указать номер полки",
        });
      }

      let finalShelfLabel = null;
      let finalShelfNumber = null;
      if (requiresManualShelf) {
        finalShelfLabel = manualShelfLabel;
        finalShelfNumber = manualShelfNumber;
        if (!finalShelfLabel) {
          finalShelfLabel = canReuseExistingShelf ? existingShelfLabel : null;
          finalShelfNumber = canReuseExistingShelf ? existingShelfNumber : null;
        }
        if (!finalShelfLabel) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            error: "Не удалось определить полку. Укажите номер полки вручную",
          });
        }
        await client.query(
          `INSERT INTO user_shelves (user_id, shelf_number, shelf_label, created_at, updated_at)
           VALUES ($1, $2, $3, now(), now())
           ON CONFLICT (user_id) DO UPDATE
             SET shelf_number = EXCLUDED.shelf_number,
                 shelf_label = EXCLUDED.shelf_label,
                 updated_at = now()`,
          [item.user_id, finalShelfNumber, finalShelfLabel],
        );
      }

      await client.query(
        `UPDATE reservations
         SET is_fulfilled = true,
             is_sent = true,
             fulfilled_by_id = $2,
             fulfilled_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [item.id, req.user.id],
      );

      if (targetCartItemId) {
        await client.query(
          `UPDATE cart_items
           SET status = 'processed',
               processing_mode = $2,
               updated_at = now()
           WHERE id = $1`,
          [targetCartItemId, processingMode],
        );
      }

      const processedByQ = await client.query(
        `SELECT name, email
         FROM users
         WHERE id = $1
         LIMIT 1`,
        [req.user.id],
      );
      const processedByRow =
        processedByQ.rowCount > 0 ? processedByQ.rows[0] : null;
      const processedByName =
        String(processedByRow?.name || "").trim() ||
        String(processedByRow?.email || "").trim() ||
        "Сотрудник";

      const updatedReservedMessages = await client.query(
        `UPDATE messages
         SET meta = COALESCE(meta, '{}'::jsonb) || jsonb_build_object(
               'placed', true,
               'processing_mode', $3::text,
               'is_oversize', ($3::text = 'oversize'),
               'shelf_number', $2::int,
               'shelf_label', $4::text,
               'processed_by_id', $5::text,
               'processed_by_name', $6::text
             )
         WHERE chat_id = $1
           AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
           AND (
             COALESCE(meta->>'reservation_id', '') = $7
             OR ($8 <> '' AND COALESCE(meta->>'cart_item_id', '') = $8)
           )
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
        [
          reservedChannel.id,
          finalShelfNumber,
          processingMode,
          finalShelfLabel,
          String(req.user.id),
          processedByName,
          String(item.id),
          targetCartItemId,
        ],
      );
      const syncedPendingClientMessages =
        finalShelfLabel == null
          ? { rows: [] }
          : await client.query(
              `UPDATE messages
               SET meta = jsonb_set(
                     jsonb_set(
                       COALESCE(meta, '{}'::jsonb),
                       '{shelf_number}',
                       CASE
                         WHEN $2::int IS NULL THEN 'null'::jsonb
                         ELSE to_jsonb($2::int)
                       END,
                       true
                     ),
                     '{shelf_label}',
                     to_jsonb($3::text),
                     true
                   )
               WHERE chat_id = $1
                 AND COALESCE(meta->>'kind', '') = 'reserved_order_item'
                 AND COALESCE(meta->>'user_id', '') = $4
                 AND lower(COALESCE(meta->>'placed', 'false')) <> 'true'
               RETURNING id, chat_id, sender_id, text, meta, created_at`,
              [
                reservedChannel.id,
                finalShelfNumber,
                finalShelfLabel,
                String(item.user_id),
              ],
            );

      let hiddenCatalogMessages = [];
      const productIdText = String(item.product_id || "").trim();
      if (productIdText) {
        const productQ = await client.query(
          `SELECT id, quantity
           FROM products
           WHERE id = $1
           LIMIT 1
           FOR UPDATE`,
          [productIdText],
        );
        if (
          productQ.rowCount > 0 &&
          Number(productQ.rows[0].quantity || 0) <= 0
        ) {
          const unresolvedQ = await client.query(
            `SELECT 1
             FROM reservations r
             JOIN users u ON u.id = r.user_id
             WHERE r.product_id = $1
               AND r.is_fulfilled = false
               AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
             LIMIT 1`,
            [productIdText, req.user.tenant_id || null],
          );
          if (unresolvedQ.rowCount === 0) {
            await client.query(
              `UPDATE products
               SET status = 'archived',
                   reusable_at = now() + interval '2 months',
                   updated_at = now()
               WHERE id = $1
                 AND status <> 'archived'`,
              [productIdText],
            );

            const hiddenQ = await client.query(
              `UPDATE messages
               SET meta = jsonb_set(
                     jsonb_set(
                       COALESCE(meta, '{}'::jsonb),
                       '{hidden_for_all}',
                       'true'::jsonb,
                       true
                     ),
                     '{sold_out_processed}',
                     'true'::jsonb,
                     true
                   )
               WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
                 AND COALESCE(meta->>'product_id', '') = $1::text
                 AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false
               RETURNING id, chat_id, sender_id, text, meta, created_at`,
              [productIdText],
            );
            hiddenCatalogMessages = hiddenQ.rows;
          }
        }
      }

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        reservedChannel.id,
      ]);

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        const reservationMessagesById = new Map();
        for (const message of updatedReservedMessages.rows) {
          reservationMessagesById.set(String(message.id), message);
        }
        for (const message of syncedPendingClientMessages.rows) {
          reservationMessagesById.set(String(message.id), message);
        }
        for (const message of reservationMessagesById.values()) {
          io.to(`chat:${reservedChannel.id}`).emit("chat:message", {
            chatId: reservedChannel.id,
            message: decryptMessageRow(message),
          });
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId: reservedChannel.id,
          });
          emitReservedOrderUpdated(io, req.user?.tenant_id || null, reservedChannel.id, {
            action: "processed",
            message_id: message.id,
            reservation_id: item.id,
            cart_item_id: targetCartItemId || null,
            user_id: item.user_id,
            shelf_number: finalShelfNumber,
            shelf_label: finalShelfLabel,
            processing_mode: processingMode,
          });
        }
        io.to(`user:${item.user_id}`).emit("cart:updated", {
          userId: String(item.user_id),
          product_id: item.product_id ? String(item.product_id) : "",
          cart_item_id: targetCartItemId || null,
          status: "processed",
          shelf_number: finalShelfNumber,
          shelf_label: finalShelfLabel,
          processing_mode: processingMode,
          processed_by_name: processedByName,
          reason: "item_processed",
        });
        for (const hiddenMessage of hiddenCatalogMessages) {
          io.to(`chat:${hiddenMessage.chat_id}`).emit("chat:message", {
            chatId: hiddenMessage.chat_id,
            message: decryptMessageRow(hiddenMessage),
          });
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId: hiddenMessage.chat_id,
          });
        }
      }

      return res.json({
        ok: true,
        data: {
          reservation_id: item.id,
          cart_item_id: targetCartItemId || null,
          status: "processed",
          shelf_number: finalShelfNumber,
          shelf_label: finalShelfLabel,
          shelf_display: displayShelfValue(finalShelfLabel, finalShelfNumber),
          processing_mode: processingMode,
          processed_by_name: processedByName,
          product_hidden_after_sellout: hiddenCatalogMessages.length > 0,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.orders.mark_placed error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Подтвердить и отправить посты на канал
router.post(
  "/channels/publish_pending",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireProductPublishPermission,
  antifraudGuard("admin.publish_pending", (req) => ({
    channel_id: req.body?.channel_id || null,
    queue_count: Array.isArray(req.body?.queue_ids) ? req.body.queue_ids.length : 0,
  })),
  async (req, res) => {
    const rawChannelId = req.body?.channel_id
      ? String(req.body.channel_id).trim()
      : "";
    if (rawChannelId && !isUuidLike(rawChannelId)) {
      return res.status(400).json({
        ok: false,
        error: "Некорректный channel_id",
      });
    }
    const channelId = rawChannelId || null;

    const rawQueueIds = Array.isArray(req.body?.queue_ids)
      ? req.body.queue_ids
      : [];
    const queueIds = normalizeUuidList(rawQueueIds);
    if (rawQueueIds.length > 0 && queueIds.length === 0) {
      return res.status(400).json({
        ok: false,
        error: "Некорректные queue_ids",
      });
    }
    const onlySelected = queueIds.length > 0;

    const client = await db.pool.connect();
    try {
      const tenantSettings = await getTenantFeatureSettings(req.user.tenant_id || null);
      const rawRequestedInterval =
        req.body?.publication_interval_ms ??
        (req.body?.publication_interval_seconds == null
          ? null
          : Number(req.body.publication_interval_seconds) * 1000);
      let publicationIntervalMs = Number(tenantSettings.publication_interval_ms) ||
        DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS;
      if (tenantSettings.custom_workflows_enabled && rawRequestedInterval != null) {
        publicationIntervalMs = Math.round(
          Math.min(10 * 60 * 1000, Math.max(500, Number(rawRequestedInterval) || publicationIntervalMs)),
        );
        await patchTenantFeatureSettings(req.user.tenant_id || null, {
          publication_interval_ms: publicationIntervalMs,
        });
      }
      if (process.env.PHX_PUBLICATION_DEBUG_LOGS === "1") {
        console.log("[PHX:PUBLISH] publish_pending request", {
          tenant_id: req.user?.tenant_id || null,
          user_id: req.user?.id || null,
          role: req.user?.role || null,
          requested_channel_id: channelId,
          only_selected: onlySelected,
          queue_ids: queueIds,
          raw_requested_interval: rawRequestedInterval,
          effective_interval_ms: publicationIntervalMs,
        });
      }
      await client.query("BEGIN");
      const enqueueResult = await enqueueChannelPublicationBatches({
        queryable: client,
        tenantId: req.user.tenant_id || null,
        createdBy: req.user.id || null,
        channelId,
        queueIds: onlySelected ? queueIds : [],
        intervalMs: publicationIntervalMs,
      });
      const batches = Array.isArray(enqueueResult.batches)
        ? enqueueResult.batches
        : [];

      await client.query("COMMIT");
      if (process.env.PHX_PUBLICATION_DEBUG_LOGS === "1") {
        console.log("[PHX:PUBLISH] publish_pending committed", {
          tenant_id: req.user?.tenant_id || null,
          accepted_count: enqueueResult.accepted_count,
          batch_count: batches.length,
          batches: batches.map((item) => ({
            batch_id: item.batch_id,
            channel_id: item.channel_id,
            total_count: item.total_count,
            interval_ms: item.interval_ms,
          })),
          already_running_channels:
            enqueueResult.already_running_channels || [],
        });
      }

      emitCatalogQueueUpdated(req.app.get("io"), req.user?.tenant_id || null, {
        action: "publish_enqueued",
        channel_id: channelId,
        queue_ids: queueIds,
        batch_ids: batches.map((item) => item.batch_id).filter(Boolean),
      });
      setImmediate(() => {
        void notifyChannelPublicationBatchesStarted({
          tenantId: req.user.tenant_id || null,
          batches,
        }).catch((notifyErr) => {
          console.error(
            "admin.channels.publish_pending batch notification error",
            notifyErr,
          );
        });
      });
      kickChannelPublicationProcessor(req.app.get("io"));
      if (process.env.PHX_PUBLICATION_DEBUG_LOGS === "1") {
        console.log(
          "[PHX:PUBLISH] publish_pending realtime emitted and processor kicked",
          {
            tenant_id: req.user?.tenant_id || null,
            channel_id: channelId,
            batch_ids: batches.map((item) => item.batch_id).filter(Boolean),
          },
        );
      }

      const alreadyRunningChannels = Array.isArray(
        enqueueResult.already_running_channels,
      )
        ? enqueueResult.already_running_channels
        : [];

      return res.json({
        ok: true,
        accepted_count: Number(enqueueResult.accepted_count || 0),
        interval_ms: Number(
          enqueueResult.interval_ms || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS,
        ),
        batch_id: batches.length === 1 ? batches[0].batch_id : null,
        already_running_for_channel: alreadyRunningChannels.length > 0,
        already_running_channels: alreadyRunningChannels,
        data: batches,
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.channels.publish_pending error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/test/tenants/matrix",
  requireAuth,
  async (req, res) => {
    if (String(req.user?.base_role || req.user?.role || "") !== "creator") {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только создателю платформы",
      });
    }

    const includeDeleted = req.body?.include_deleted === true;
    const includeDefault = req.body?.include_default === true;

    const where = [
      includeDeleted
        ? "1=1"
        : "COALESCE(t.is_deleted, false) = false",
      includeDefault ? "1=1" : "lower(t.code) <> 'default'",
    ].join(" AND ");

    const client = await db.platformConnect();
    try {
      const q = await client.query(
        `SELECT t.id,
                t.code,
                t.name,
                t.status,
                t.db_mode,
                t.db_name,
                t.db_schema,
                t.is_deleted,
                t.subscription_expires_at,
                t.last_payment_confirmed_at,
                t.created_at,
                t.updated_at,
                COALESCE(uc.user_count, 0)::int AS user_count,
                COALESCE(uc.client_count, 0)::int AS client_count,
                COALESCE(uc.staff_count, 0)::int AS staff_count,
                COALESCE(cc.chat_count, 0)::int AS chat_count,
                COALESCE(cc.channel_count, 0)::int AS channel_count,
                COALESCE(cc.private_chat_count, 0)::int AS private_chat_count,
                EXISTS (
                  SELECT 1
                    FROM chats cm
                   WHERE cm.tenant_id = t.id
                     AND lower(COALESCE(cm.type, '')) = 'channel'
                     AND (
                       lower(COALESCE(cm.settings->>'system_key', '')) = 'main_channel'
                       OR lower(COALESCE(cm.settings->>'kind', '')) = 'main_channel'
                       OR COALESCE(cm.settings->>'is_main_channel', '') = 'true'
                       OR lower(COALESCE(cm.title, '')) LIKE 'основной канал%'
                     )
                ) AS has_main_channel
           FROM tenants t
      LEFT JOIN (
             SELECT tenant_id,
                    COUNT(*)::int AS user_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(role, '')) = 'client'
                    )::int AS client_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(role, '')) IN ('creator', 'tenant', 'admin', 'worker')
                    )::int AS staff_count
               FROM users
           GROUP BY tenant_id
      ) uc
             ON uc.tenant_id = t.id
      LEFT JOIN (
             SELECT tenant_id,
                    COUNT(*)::int AS chat_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(type, '')) = 'channel'
                    )::int AS channel_count,
                    COUNT(*) FILTER (
                      WHERE lower(COALESCE(type, '')) = 'private'
                    )::int AS private_chat_count
               FROM chats
           GROUP BY tenant_id
      ) cc
             ON cc.tenant_id = t.id
          WHERE ${where}
       ORDER BY lower(t.code) ASC, t.created_at ASC`,
      );

      const now = Date.now();
      let active = 0;
      let blocked = 0;
      let expiringSoon = 0;
      let expired = 0;
      let missingMainChannel = 0;
      let missingStaff = 0;
      let isolated = 0;
      let schemaIsolated = 0;
      let shared = 0;

      for (const row of q.rows) {
        const status = String(row.status || "")
          .toLowerCase()
          .trim();
        if (status === "active") active += 1;
        if (status === "blocked") blocked += 1;

        const expiresAtRaw = row.subscription_expires_at
          ? new Date(row.subscription_expires_at).getTime()
          : NaN;
        if (Number.isFinite(expiresAtRaw)) {
          if (expiresAtRaw <= now) {
            expired += 1;
          } else if (expiresAtRaw - now <= 24 * 60 * 60 * 1000) {
            expiringSoon += 1;
          }
        }

        if (!row.has_main_channel) missingMainChannel += 1;
        if (Number(row.staff_count || 0) <= 0) missingStaff += 1;

        const dbMode = String(row.db_mode || "")
          .toLowerCase()
          .trim();
        if (dbMode === "isolated") isolated += 1;
        if (dbMode === "schema_isolated") schemaIsolated += 1;
        if (dbMode === "shared") shared += 1;
      }

      return res.json({
        ok: true,
        data: {
          include_deleted: includeDeleted,
          include_default: includeDefault,
          total: q.rows.length,
          summary: {
            active,
            blocked,
            expiring_soon_24h: expiringSoon,
            expired,
            missing_main_channel: missingMainChannel,
            missing_staff: missingStaff,
            isolated,
            schema_isolated: schemaIsolated,
            shared,
          },
          rows: q.rows,
        },
      });
    } catch (err) {
      console.error("admin.test.tenants.matrix error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/test/tenants/subscriptions",
  requireAuth,
  async (req, res) => {
    if (String(req.user?.base_role || req.user?.role || "") !== "creator") {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    if (req.user?.is_platform_creator !== true) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только создателю платформы",
      });
    }

    const mode = String(req.body?.mode || "")
      .toLowerCase()
      .trim();
    const includeDefault = req.body?.include_default === true;
    const dryRun = req.body?.dry_run === true;
    const warningHoursRaw = Number(req.body?.warning_hours);
    const warningHours = Number.isFinite(warningHoursRaw)
      ? Math.max(1, Math.min(72, Math.floor(warningHoursRaw)))
      : 20;

    const allowedModes = new Set([
      "block_all",
      "activate_all",
      "warn_soon_all",
      "expire_all",
      "restore_snapshot",
    ]);
    if (!allowedModes.has(mode)) {
      return res.status(400).json({
        ok: false,
        error:
          "Некорректный mode. Разрешено: block_all, activate_all, warn_soon_all, expire_all, restore_snapshot",
      });
    }

    let snapshotRows = [];
    if (mode === "restore_snapshot") {
      const rawSnapshot = Array.isArray(req.body?.snapshot)
        ? req.body.snapshot
        : [];
      snapshotRows = rawSnapshot
        .map((row) => {
          const id = String(row?.id || "").trim();
          const status = String(row?.status || "")
            .toLowerCase()
            .trim();
          const expiresRaw = String(
            row?.subscription_expires_at || row?.subscriptionExpiresAt || "",
          ).trim();
          if (!isUuidLike(id)) return null;
          if (status !== "active" && status !== "blocked") return null;
          return {
            id,
            status,
            subscription_expires_at: expiresRaw || null,
          };
        })
        .filter(Boolean);
      if (snapshotRows.length === 0) {
        return res.status(400).json({
          ok: false,
          error: "Для restore_snapshot нужен непустой snapshot",
        });
      }
    }

    const whereSql = includeDefault
      ? "COALESCE(is_deleted, false) = false"
      : "COALESCE(is_deleted, false) = false AND lower(code) <> 'default'";

    const client = await db.platformConnect();
    try {
      await client.query("BEGIN");

      const beforeQ = await client.query(
        `SELECT id, code, name, status, subscription_expires_at
         FROM tenants
         WHERE ${whereSql}
         ORDER BY created_at DESC`,
      );
      const before = beforeQ.rows;

      if (!dryRun && before.length > 0) {
        if (mode === "block_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'blocked',
                 updated_at = now()
             WHERE ${whereSql}`,
          );
        } else if (mode === "activate_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'active',
                 updated_at = now()
             WHERE ${whereSql}`,
          );
        } else if (mode === "warn_soon_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'active',
                 subscription_expires_at = now() + make_interval(hours => $1::int),
                 updated_at = now()
             WHERE ${whereSql}`,
            [warningHours],
          );
        } else if (mode === "expire_all") {
          await client.query(
            `UPDATE tenants
             SET status = 'active',
                 subscription_expires_at = now() - interval '5 minutes',
                 updated_at = now()
             WHERE ${whereSql}`,
          );
        } else if (mode === "restore_snapshot") {
          await client.query(
            `WITH payload AS (
               SELECT *
               FROM jsonb_to_recordset($1::jsonb)
                 AS p(id uuid, status text, subscription_expires_at timestamptz)
             )
             UPDATE tenants t
             SET status = lower(p.status),
                 subscription_expires_at = p.subscription_expires_at,
                 updated_at = now()
             FROM payload p
             WHERE t.id = p.id
               AND ${whereSql}`,
            [JSON.stringify(snapshotRows)],
          );
        }
      }

      const afterQ = await client.query(
        `SELECT id, code, name, status, subscription_expires_at
         FROM tenants
         WHERE ${whereSql}
         ORDER BY created_at DESC`,
      );
      const after = afterQ.rows;

      const beforeById = new Map(before.map((row) => [String(row.id), row]));
      let changed = 0;
      const changedRows = [];
      for (const row of after) {
        const prev = beforeById.get(String(row.id));
        if (!prev) continue;
        const prevStatus = String(prev.status || "");
        const nextStatus = String(row.status || "");
        const prevExpiry = String(prev.subscription_expires_at || "");
        const nextExpiry = String(row.subscription_expires_at || "");
        if (prevStatus !== nextStatus || prevExpiry !== nextExpiry) {
          changed += 1;
          changedRows.push(row);
        }
      }

      const activeCount = after.filter(
        (row) => String(row.status || "").toLowerCase().trim() === "active",
      ).length;
      const blockedCount = after.length - activeCount;

      await client.query("COMMIT");

      if (!dryRun && changedRows.length > 0) {
        const io = req.app.get("io");
        for (const row of changedRows) {
          emitTenantSubscriptionUpdate(
            io,
            row.id,
            row,
            `test_bulk:${mode}`,
          );
        }
      }

      return res.json({
        ok: true,
        data: {
          mode,
          include_default: includeDefault,
          dry_run: dryRun,
          warning_hours: warningHours,
          total: after.length,
          changed,
          active_count: activeCount,
          blocked_count: blockedCount,
          before,
          after,
        },
      });
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      console.error("admin.test.tenants.subscriptions error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/test/publish-demo-posts",
  requireAuth,
  async (req, res) => {
    if (String(req.user?.base_role || req.user?.role || "") !== "creator") {
      return res.status(403).json({ ok: false, error: "Forbidden" });
    }
    const requestedCount = Number(req.body?.count);
    const count = Number.isFinite(requestedCount)
      ? Math.max(1, Math.min(50, Math.floor(requestedCount)))
      : 10;

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const { mainChannel } = await ensureSystemChannels(
        client,
        req.user.id,
        req.user.tenant_id,
      );
      const imageUrl = ensureDemoProductImage(req);
      await client.query("COMMIT");

      publishDemoPostsSequentially({
        io: req.app.get("io"),
        count,
        channelId: mainChannel.id,
        channelTitle: mainChannel.title,
        tenantId: req.user?.tenant_id || null,
        createdBy: req.user.id,
        imageUrl,
      });

      return res.json({
        ok: true,
        data: {
          count,
          scheduled: true,
          interval_ms: PUBLISH_POST_INTERVAL_MS,
          channel_id: mainChannel.id,
          channel_title: mainChannel.title,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("admin.test.publish_demo_posts error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Архивировать товар и сразу освободить номер товара для повторного использования
router.post(
  "/products/:id/archive",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const { id } = req.params;
      const upd = await db.query(
        `UPDATE products
       SET status = 'archived',
           reusable_at = now(),
           updated_at = now()
       WHERE id = $1
       RETURNING id, product_code, title, status, reusable_at`,
        [id],
      );
      if (upd.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Товар не найден" });
      }
      return res.json({ ok: true, data: upd.rows[0] });
    } catch (err) {
      console.error("admin.products.archive error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/products/:id/full",
  requireAuth,
  requireRole("tenant", "creator"),
  requireProductPublishPermission,
  async (req, res) => {
    const productId = String(req.params?.id || "").trim();
    if (!productId) {
      return res.status(400).json({ ok: false, error: "productId обязателен" });
    }

    try {
      const result = await runInRequestTenantScope(req, async () => {
        const client = await db.pool.connect();
        try {
          await client.query("BEGIN");
          const productQ = await client.query(
            `SELECT p.id,
                    p.product_code,
                    p.title,
                    p.status,
                    p.deleted_at
             FROM products p
             WHERE p.id = $1
               AND (
                 $2::uuid IS NULL
                 OR EXISTS (
                   SELECT 1
                   FROM users cu
                   WHERE cu.id = p.created_by
                     AND cu.tenant_id = $2::uuid
                 )
                 OR EXISTS (
                   SELECT 1
                   FROM product_publication_queue q
                   JOIN chats c ON c.id = q.channel_id
                   WHERE q.product_id = p.id
                     AND c.tenant_id = $2::uuid
                 )
                 OR EXISTS (
                   SELECT 1
                   FROM cart_items ci
                   JOIN users u ON u.id = ci.user_id
                   WHERE ci.product_id = p.id
                     AND u.tenant_id = $2::uuid
                 )
               )
             LIMIT 1
             FOR UPDATE`,
            [productId, req.user?.tenant_id || null],
          );
          if (productQ.rowCount === 0) {
            await client.query("ROLLBACK");
            return null;
          }

          const affectedUsersQ = await client.query(
            `SELECT DISTINCT ci.user_id::text AS user_id
             FROM cart_items ci
             JOIN users u ON u.id = ci.user_id
             WHERE ci.product_id = $1
               AND ci.status NOT IN ('in_delivery', 'delivered')
               AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)`,
            [productId, req.user?.tenant_id || null],
          );

          await client.query(
            `UPDATE reservations r
             SET is_fulfilled = true,
                 fulfilled_at = COALESCE(fulfilled_at, now()),
                 updated_at = now()
             WHERE r.product_id = $1
               AND r.is_fulfilled = false
               AND (
                 $2::uuid IS NULL
                 OR EXISTS (
                   SELECT 1
                   FROM users u
                   WHERE u.id = r.user_id
                     AND u.tenant_id = $2::uuid
                 )
               )`,
            [productId, req.user?.tenant_id || null],
          );

          await client.query(
            `UPDATE delivery_batch_items i
             SET assembly_status = 'removed',
                 removed_reason = COALESCE(NULLIF(removed_reason, ''), 'Товар полностью удален'),
                 removed_at = COALESCE(removed_at, now()),
                 removed_by = COALESCE(removed_by, $3)
             FROM delivery_batches b
             JOIN delivery_batch_customers c ON c.batch_id = b.id
             JOIN users u ON u.id = c.user_id
             WHERE i.batch_id = b.id
               AND i.batch_customer_id = c.id
               AND i.product_id = $1
               AND b.status IN ('calling', 'couriers_assigned')
               AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)`,
            [productId, req.user?.tenant_id || null, req.user?.id || null],
          );

          await client.query(
            `UPDATE cart_items ci
             SET status = 'cancelled',
                 updated_at = now()
             WHERE ci.product_id = $1
               AND ci.status NOT IN ('in_delivery', 'delivered')
               AND (
                 $2::uuid IS NULL
                 OR EXISTS (
                   SELECT 1
                   FROM users u
                   WHERE u.id = ci.user_id
                     AND u.tenant_id = $2::uuid
                 )
               )`,
            [productId, req.user?.tenant_id || null],
          );

          await client.query(
            `UPDATE product_publication_queue q
             SET status = 'deleted',
                 is_sent = true
             WHERE q.product_id = $1
               AND (
                 $2::uuid IS NULL
                 OR EXISTS (
                   SELECT 1
                   FROM chats c
                   WHERE c.id = q.channel_id
                     AND c.tenant_id = $2::uuid
                 )
               )`,
            [productId, req.user?.tenant_id || null],
          );

          const hiddenMessagesQ = await client.query(
            `UPDATE messages m
             SET meta = jsonb_set(
                   jsonb_set(
                     jsonb_set(
                       COALESCE(m.meta, '{}'::jsonb),
                       '{hidden_for_all}',
                       'true'::jsonb,
                       true
                     ),
                     '{product_deleted}',
                     'true'::jsonb,
                     true
                   ),
                   '{deleted_by}',
                   to_jsonb($3::text),
                   true
                 )
             FROM chats c
             WHERE c.id = m.chat_id
               AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
               AND COALESCE(m.meta->>'product_id', '') = $1::text
               AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
             RETURNING m.id, m.chat_id`,
            [productId, req.user?.tenant_id || null, String(req.user?.id || "")],
          );

          const hiddenMessageIds = hiddenMessagesQ.rows
            .map((row) => String(row.id || "").trim())
            .filter(Boolean);
          if (hiddenMessageIds.length > 0) {
            await client.query(
              `DELETE FROM message_search_documents
               WHERE message_id = ANY($1::uuid[])`,
              [hiddenMessageIds],
            );
          }

          await client.query(
            `UPDATE products
             SET status = 'deleted',
                 deleted_at = COALESCE(deleted_at, now()),
                 deleted_by = COALESCE(deleted_by, $2),
                 deletion_reason = COALESCE(NULLIF(deletion_reason, ''), 'full_delete'),
                 reusable_at = NULL,
                 updated_at = now()
             WHERE id = $1`,
            [productId, req.user?.id || null],
          );

          const depsQ = await client.query(
            `SELECT
               (SELECT COUNT(*) FROM cart_items WHERE product_id = $1)::int AS cart_count,
               (SELECT COUNT(*) FROM reservations WHERE product_id = $1)::int AS reservation_count,
               (SELECT COUNT(*) FROM delivery_batch_items WHERE product_id = $1)::int AS delivery_count`,
            [productId],
          );
          const deps = depsQ.rows[0] || {};
          const canPhysicallyDelete =
            Number(deps.cart_count || 0) === 0 &&
            Number(deps.reservation_count || 0) === 0 &&
            Number(deps.delivery_count || 0) === 0;
          let physicallyDeleted = false;
          if (canPhysicallyDelete) {
            const deleteQ = await client.query(
              `DELETE FROM products
               WHERE id = $1
               RETURNING id`,
              [productId],
            );
            physicallyDeleted = deleteQ.rowCount > 0;
          }

          const chatIds = Array.from(
            new Set(
              hiddenMessagesQ.rows
                .map((row) => String(row.chat_id || "").trim())
                .filter(Boolean),
            ),
          );
          await client.query("COMMIT");
          return {
            product: productQ.rows[0],
            hidden_messages: hiddenMessagesQ.rows,
            hidden_message_count: hiddenMessagesQ.rowCount,
            affected_user_ids: affectedUsersQ.rows.map((row) => row.user_id),
            chat_ids: chatIds,
            physically_deleted: physicallyDeleted,
          };
        } catch (err) {
          try {
            await client.query("ROLLBACK");
          } catch (_) {}
          throw err;
        } finally {
          client.release();
        }
      });

      if (!result) {
        return res.status(404).json({ ok: false, error: "Товар не найден" });
      }

      const io = req.app.get("io");
      if (io) {
        for (const row of result.hidden_messages) {
          const chatId = String(row.chat_id || "").trim();
          const messageId = String(row.id || "").trim();
          if (!chatId || !messageId) continue;
          io.to(`chat:${chatId}`).emit("chat:message:deleted", {
            chatId,
            messageId,
            reason: "product_full_delete",
            product_id: productId,
          });
        }
        for (const chatId of result.chat_ids) {
          emitToTenant(io, req.user?.tenant_id || null, "chat:updated", {
            chatId,
            action: "product_deleted",
            product_id: productId,
          });
        }
        for (const userId of result.affected_user_ids) {
          io.to(`user:${userId}`).emit("cart:updated", {
            userId,
            reason: "product_deleted",
            product_id: productId,
          });
        }
        emitCatalogQueueUpdated(io, req.user?.tenant_id || null, {
          action: "product_deleted",
          product_id: productId,
        });
      }

      return res.json({
        ok: true,
        data: {
          product_id: productId,
          hidden_message_count: result.hidden_message_count,
          affected_user_count: result.affected_user_ids.length,
          physically_deleted: result.physically_deleted,
        },
      });
    } catch (err) {
      console.error("admin.products.fullDelete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

function isCreatorBase(user) {
  const base = String(user?.base_role || user?.role || "")
    .toLowerCase()
    .trim();
  return base === "creator";
}

function tenantFilterSql(alias = "u", tenantIdParamIndex = 1) {
  return `($${tenantIdParamIndex}::uuid IS NULL OR ${alias}.tenant_id = $${tenantIdParamIndex}::uuid)`;
}

function canAccessPlatformGlobalRows(user) {
  return isCreatorBase(user) && user?.is_creator_tenant_scoped !== true;
}

function tenantVisibilitySql(column = "tenant_id", tenantParamIndex = 1, allowNullParamIndex = 2) {
  return `(${column} = $${tenantParamIndex}::uuid OR ($${allowNullParamIndex}::boolean = true AND ${column} IS NULL))`;
}

router.get(
  "/role-templates",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    try {
      const tenantId = req.user.tenant_id || null;
      const templatesQ = await db.query(
        `SELECT rt.id,
                rt.tenant_id,
                rt.code,
                rt.title,
                rt.description,
                rt.permissions,
                rt.is_system,
                rt.created_at,
                rt.updated_at,
                COUNT(urt.user_id)::int AS assigned_users
         FROM role_templates rt
         LEFT JOIN user_role_templates urt ON urt.template_id = rt.id
         WHERE rt.tenant_id = $1::uuid
            OR rt.tenant_id IS NULL
         GROUP BY rt.id
         ORDER BY
           CASE WHEN rt.tenant_id IS NULL THEN 1 ELSE 0 END,
           rt.is_system DESC,
           rt.updated_at DESC`,
        [tenantId],
      );
      return res.json({ ok: true, data: templatesQ.rows });
    } catch (err) {
      console.error("admin.roleTemplates.list error", err);
      await logMonitoringEvent({
        tenantId: req.user.tenant_id || null,
        userId: req.user.id,
        level: "error",
        code: "admin_role_templates_list_failed",
        source: "admin.role-templates",
        message: "Не удалось загрузить шаблоны ролей",
        details: { error: String(err?.message || err) },
      });
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/role-templates",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    try {
      const code = String(req.body?.code || "")
        .trim()
        .toLowerCase();
      const title = String(req.body?.title || "").trim();
      const description = String(req.body?.description || "").trim();
      const permissions =
        req.body?.permissions &&
        typeof req.body.permissions === "object" &&
        !Array.isArray(req.body.permissions)
          ? req.body.permissions
          : {};

      if (!/^[a-z0-9_.-]{2,40}$/.test(code)) {
        return res.status(400).json({
          ok: false,
          error: "code должен содержать 2-40 символов: a-z, 0-9, _, -, .",
        });
      }
      if (!title) {
        return res.status(400).json({ ok: false, error: "title обязателен" });
      }

      const result = await db.query(
        `INSERT INTO role_templates (
           id,
           tenant_id,
           code,
           title,
           description,
           permissions,
           is_system,
           created_by,
           created_at,
           updated_at
         )
         VALUES (
           gen_random_uuid(),
           $1,
           $2,
           $3,
           NULLIF($4, ''),
           $5::jsonb,
           false,
           $6,
           now(),
           now()
         )
         RETURNING *`,
        [
          req.user.tenant_id || null,
          code,
          title,
          description,
          JSON.stringify(permissions),
          req.user.id,
        ],
      );
      return res.status(201).json({ ok: true, data: result.rows[0] });
    } catch (err) {
      console.error("admin.roleTemplates.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/role-templates/:id",
  requireAuth,
  requireRole("creator"),
  async (req, res) => {
    try {
      const templateId = String(req.params?.id || "").trim();
      if (!isUuidLike(templateId)) {
        return res.status(400).json({ ok: false, error: "Некорректный id" });
      }

      const title = String(req.body?.title || "").trim();
      const description = String(req.body?.description || "").trim();
      const permissions =
        req.body?.permissions &&
        typeof req.body.permissions === "object" &&
        !Array.isArray(req.body.permissions)
          ? req.body.permissions
          : null;

      const existingQ = await db.query(
        `SELECT id, tenant_id, is_system
         FROM role_templates
         WHERE id = $1
         LIMIT 1`,
        [templateId],
      );
      if (existingQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Шаблон не найден" });
      }
      const existing = existingQ.rows[0];
      if (existing.is_system === true) {
        return res.status(403).json({
          ok: false,
          error: "Системный шаблон редактировать нельзя",
        });
      }
      if (String(existing.tenant_id || "") !== String(req.user.tenant_id || "")) {
        return res.status(403).json({ ok: false, error: "Нет доступа" });
      }

      const upd = await db.query(
        `UPDATE role_templates
         SET title = COALESCE(NULLIF($1, ''), title),
             description = CASE WHEN $2::text IS NULL THEN description ELSE NULLIF($2, '') END,
             permissions = CASE
               WHEN $3::jsonb IS NULL THEN permissions
               ELSE $3::jsonb
             END,
             updated_at = now()
         WHERE id = $4
         RETURNING *`,
        [title, description || null, permissions ? JSON.stringify(permissions) : null, templateId],
      );
      return res.json({ ok: true, data: upd.rows[0] });
    } catch (err) {
      console.error("admin.roleTemplates.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/role-templates/assign",
  requireAuth,
  requireRole("admin", "creator"),
  requirePermission("tenant.users.manage"),
  async (req, res) => {
    try {
      const userId = String(req.body?.user_id || "").trim();
      const templateId = String(req.body?.template_id || "").trim();
      if (!isUuidLike(userId) || !isUuidLike(templateId)) {
        return res.status(400).json({
          ok: false,
          error: "user_id и template_id должны быть UUID",
        });
      }

      const userQ = await db.query(
        `SELECT id, tenant_id
         FROM users
         WHERE id = $1
           AND ${tenantFilterSql("users", 2)}
         LIMIT 1`,
        [userId, req.user.tenant_id || null],
      );
      if (userQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Пользователь не найден" });
      }

      const templateQ = await db.query(
        `SELECT id, tenant_id, code
         FROM role_templates
         WHERE id = $1
           AND (
             tenant_id = $2::uuid
             OR tenant_id IS NULL
           )
         LIMIT 1`,
        [templateId, req.user.tenant_id || null],
      );
      if (templateQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Шаблон роли не найден" });
      }
      const template = templateQ.rows[0];
      const templateCode = String(template.code || "").toLowerCase().trim();
      if (templateCode === "creator") {
        return res.status(403).json({
          ok: false,
          error: "Назначение шаблона creator запрещено",
        });
      }
      if (templateCode === "tenant" && !isCreatorBase(req.user)) {
        return res.status(403).json({
          ok: false,
          error: "Шаблон tenant может назначать только создатель",
        });
      }

      await db.query(
        `INSERT INTO user_role_templates (
           user_id,
           template_id,
           assigned_by,
           assigned_at,
           updated_at
         )
         VALUES ($1, $2, $3, now(), now())
         ON CONFLICT (user_id) DO UPDATE
           SET template_id = EXCLUDED.template_id,
               assigned_by = EXCLUDED.assigned_by,
               assigned_at = now(),
               updated_at = now()`,
        [userId, templateId, req.user.id],
      );
      return res.json({ ok: true });
    } catch (err) {
      console.error("admin.roleTemplates.assign error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get("/problem-report", requireAuth, async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Доступ только создателю" });
    }
    const tenantId = req.user.tenant_id || null;
    const allowNullTenantRows = canAccessPlatformGlobalRows(req.user);

    const pendingPostsQ = await db.query(
      `SELECT COUNT(*)::int AS total,
              COUNT(*) FILTER (WHERE q.created_at < now() - interval '12 hours')::int AS stale
       FROM product_publication_queue q
       JOIN chats c ON c.id = q.channel_id
       WHERE q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
         AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)`,
      [tenantId],
    );
    const reservationsQ = await db.query(
      `SELECT COUNT(*)::int AS total,
              COALESCE(SUM(r.quantity), 0)::int AS units
       FROM reservations r
       JOIN users u ON u.id = r.user_id
       WHERE r.is_fulfilled = false
         AND (${tenantFilterSql("u", 1)})`,
      [tenantId],
    );
    const deliveryQ = await db.query(
      `SELECT COUNT(*)::int AS waiting_for_courier
       FROM delivery_batch_customers c
       JOIN delivery_batches b ON b.id = c.batch_id
       JOIN users u ON u.id = c.user_id
       WHERE b.status IN ('calling', 'couriers_assigned')
         AND c.call_status = 'accepted'
         AND COALESCE(c.courier_name, '') = ''
         AND (${tenantFilterSql("u", 1)})`,
      [tenantId],
    );
    const monitoringQ = await db.query(
      `SELECT level,
              COUNT(*)::int AS total
       FROM monitoring_events
       WHERE resolved = false
         AND created_at >= now() - interval '7 days'
         AND ${tenantVisibilitySql("tenant_id", 1, 2)}
       GROUP BY level`,
      [tenantId, allowNullTenantRows],
    );
    const sourceQ = await db.query(
      `SELECT COALESCE(NULLIF(TRIM(source), ''), 'unknown') AS source,
              COUNT(*)::int AS total
       FROM monitoring_events
       WHERE created_at >= now() - interval '7 days'
         AND level IN ('error', 'critical')
         AND ${tenantVisibilitySql("tenant_id", 1, 2)}
       GROUP BY 1
       ORDER BY total DESC, source ASC
       LIMIT 8`,
      [tenantId, allowNullTenantRows],
    );

    const byLevel = {};
    for (const row of monitoringQ.rows) {
      byLevel[row.level] = Number(row.total) || 0;
    }

    const pendingPosts = Number(pendingPostsQ.rows[0]?.total || 0);
    const stalePendingPosts = Number(pendingPostsQ.rows[0]?.stale || 0);
    const unresolvedReservations = Number(reservationsQ.rows[0]?.total || 0);
    const unresolvedReservationUnits = Number(reservationsQ.rows[0]?.units || 0);
    const waitingForCourier = Number(deliveryQ.rows[0]?.waiting_for_courier || 0);
    const criticalErrors = Number(byLevel.critical || 0);
    const errorEvents = Number(byLevel.error || 0);

    const hotspots = [];
    if (stalePendingPosts > 0) {
      hotspots.push({
        key: "stale_pending_posts",
        title: "Зависшие посты в модерации",
        value: stalePendingPosts,
        severity: stalePendingPosts > 25 ? "high" : "medium",
      });
    }
    if (waitingForCourier > 0) {
      hotspots.push({
        key: "waiting_for_courier",
        title: "Клиенты без назначенного курьера",
        value: waitingForCourier,
        severity: waitingForCourier > 15 ? "high" : "medium",
      });
    }
    if (criticalErrors + errorEvents > 0) {
      hotspots.push({
        key: "monitoring_errors",
        title: "Ошибки сервера за 7 дней",
        value: criticalErrors + errorEvents,
        severity: criticalErrors > 0 ? "high" : "medium",
      });
    }

    return res.json({
      ok: true,
      data: {
        summary: {
          pending_posts: pendingPosts,
          stale_pending_posts: stalePendingPosts,
          unresolved_reservations: unresolvedReservations,
          unresolved_reservation_units: unresolvedReservationUnits,
          waiting_for_courier: waitingForCourier,
          monitoring_errors_7d: errorEvents,
          monitoring_critical_7d: criticalErrors,
        },
        hotspots,
        error_sources_7d: sourceQ.rows.map((row) => ({
          source: row.source,
          total: Number(row.total) || 0,
        })),
      },
    });
  } catch (err) {
    console.error("admin.problemReport error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/monitoring/events", requireAuth, async (req, res) => {
  try {
    if (!monitoringEnabled()) {
      return res.status(404).json({ ok: false, error: "Мониторинг отключен" });
    }
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Доступ только создателю" });
    }
    const tenantId = req.user.tenant_id || null;
    const allowNullTenantRows = canAccessPlatformGlobalRows(req.user);
    const limitRaw = Number(req.query?.limit || 120);
    const limit = Number.isFinite(limitRaw)
      ? Math.max(20, Math.min(500, Math.floor(limitRaw)))
      : 120;

    const rows = await db.query(
      `SELECT id,
              tenant_id,
              user_id,
              scope,
              level,
              code,
              message,
              source,
              details,
              resolved,
              created_at
       FROM monitoring_events
       WHERE ${tenantVisibilitySql("tenant_id", 1, 3)}
       ORDER BY created_at DESC
       LIMIT $2`,
      [tenantId, limit, allowNullTenantRows],
    );
    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error("admin.monitoring.list error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.patch("/monitoring/events/:id/resolve", requireAuth, async (req, res) => {
  try {
    if (!monitoringEnabled()) {
      return res.status(404).json({ ok: false, error: "Мониторинг отключен" });
    }
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Доступ только создателю" });
    }
    const id = String(req.params?.id || "").trim();
    if (!isUuidLike(id)) {
      return res.status(400).json({ ok: false, error: "Некорректный id события" });
    }
    const tenantId = req.user.tenant_id || null;
    const allowNullTenantRows = canAccessPlatformGlobalRows(req.user);
    const upd = await db.query(
      `UPDATE monitoring_events
       SET resolved = true
       WHERE id = $1
         AND ${tenantVisibilitySql("tenant_id", 2, 3)}
       RETURNING id, resolved`,
      [id, tenantId, allowNullTenantRows],
    );
    if (upd.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Событие не найдено" });
    }
    return res.json({ ok: true, data: upd.rows[0] });
  } catch (err) {
    console.error("admin.monitoring.resolve error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
