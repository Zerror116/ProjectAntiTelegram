// server/src/routes/worker.js
const express = require('express');
const fs = require('fs');
const path = require('path');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();
const db = require('../db');
const { authMiddleware } = require('../utils/auth');
const { requireRole } = require('../utils/roles');
const { ensureSystemChannels } = require('../utils/systemChannels');
const { emitToTenant } = require('../utils/socket');
const { encryptMessageText, decryptMessageRow } = require('../utils/messageCrypto');
const { runInRequestTenantScope } = require('../utils/requestScope');
const { uploadsPath } = require('../utils/storagePaths');
const { registerPublicImageUpload } = require('../utils/publicMediaRegistration');
const { upsertProductCardSnapshot } = require('../utils/productCardSnapshots');
const { toOriginalPublicMediaUrl } = require('../utils/mediaAssets');

const productUploadsDir = uploadsPath('products');
fs.mkdirSync(productUploadsDir, { recursive: true });
const SAMARA_TZ = 'Europe/Samara';
const productImageMaxMb = Math.max(
  1,
  Number.parseInt(String(process.env.PRODUCT_IMAGE_MAX_MB || '8').trim(), 10) || 8,
);
const productImageMaxBytes = productImageMaxMb * 1024 * 1024;
const allowedImageExtensions = new Set([
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.heic',
  '.heif',
  '.avif',
]);

function isAcceptedProductImage(file) {
  const mime = String(file?.mimetype || '')
    .toLowerCase()
    .trim();
  if (mime.startsWith('image/')) return true;

  // Some browsers send octet-stream for Blob uploads.
  if (mime !== '' && mime !== 'application/octet-stream') return false;

  const ext = path.extname(String(file?.originalname || '').toLowerCase());
  return allowedImageExtensions.has(ext);
}

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, productUploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || '').toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : '.jpg';
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: productImageMaxBytes },
  fileFilter: (_req, file, cb) => {
    if (isAcceptedProductImage(file)) {
      cb(null, true);
      return;
    }
    cb(new Error('Можно загружать только изображения'));
  },
});

function uploadProductImage(req, res, next) {
  upload.single('image')(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === 'LIMIT_FILE_SIZE') {
      return res.status(400).json({
        ok: false,
        error: `Размер фото не должен превышать ${productImageMaxMb}MB`,
      });
    }
    return res.status(400).json({ ok: false, error: err.message || 'Некорректный файл' });
  });
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function toAbsoluteImageUrl(req, file) {
  if (!file || !file.filename) return null;
  return `${req.protocol}://${req.get('host')}/uploads/products/${file.filename}`;
}

function normalizeImageUrl(value) {
  if (value == null) return null;
  const trimmed = String(value).trim();
  if (!trimmed) return null;
  return toOriginalPublicMediaUrl(trimmed);
}

function parseSettings(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  return raw;
}

function toPositiveNumber(value, fallback = 0) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) return fallback;
  return n;
}

function toPositiveInteger(value, fallback = 1) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.floor(n);
}

function hasAtLeastTwoLetters(value) {
  const letters = String(value || '').match(/[A-Za-zА-Яа-яЁё]/g) || [];
  return letters.length >= 2;
}

function isIsoDay(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || '').trim());
}

function parseRevisionDates(value) {
  if (Array.isArray(value)) {
    const normalized = value
      .map((item) => String(item || '').trim())
      .filter((item) => item && isIsoDay(item));
    return Array.from(new Set(normalized)).slice(0, 2);
  }
  if (typeof value === 'string') {
    const normalized = value
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item && isIsoDay(item));
    return Array.from(new Set(normalized)).slice(0, 2);
  }
  return [];
}

const REVISION_PENDING_CART_STATUSES = ['pending_processing'];
const REVISION_COMPLETED_CART_STATUSES = [
  'processed',
  'preparing_delivery',
  'handing_to_courier',
  'in_delivery',
  'delivered',
];

function roundPriceToStep(value, step = 50, min = 50) {
  const n = Number(value);
  if (!Number.isFinite(n)) return min;
  const rounded = Math.round(n / step) * step;
  return Math.max(min, rounded);
}

function roundAutoRevisionPrice(originalValue, discountPercent, step = 50, min = 50) {
  const original = Number(originalValue);
  const discount = Math.abs(Number(discountPercent));
  if (!Number.isFinite(original) || original <= 0) return min;
  if (!Number.isFinite(discount) || discount <= 0) {
    return roundPriceToStep(original, step, min);
  }

  const discounted = original * (1 - discount / 100);
  let rounded = roundPriceToStep(discounted, step, min);

  // Keep the step-50 grid, but force an actual decrease whenever
  // a positive revision percent was requested.
  if (rounded >= original) {
    rounded -= step;
  }
  return Math.max(min, rounded);
}

function toShelfNumber(value, fallback = 1) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.floor(n);
}

async function resolveAutoShelfNumber(
  client,
  tenantId = null,
  dateValue = null,
  fallback = 1
) {
  const dayQ = await client.query(
    `SELECT to_char((COALESCE($1::timestamptz, now()) AT TIME ZONE $2)::date, 'YYYY-MM-DD') AS current_day`,
    [dateValue, SAMARA_TZ]
  );
  const currentDay = String(dayQ.rows[0]?.current_day || '').trim();
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
    [tenantId || null]
  );
  if (mainQ.rowCount > 0) {
    const main = mainQ.rows[0];
    const settings = parseSettings(main.settings);
    const savedStart = String(settings.shelf_cycle_start_day || '').trim();
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
        [JSON.stringify(nextSettings), main.id]
      );
      startDay = currentDay;
    }
  }

  const diffQ = await client.query(
    `SELECT GREATEST(0, ($1::date - $2::date))::int AS diff_days`,
    [currentDay, startDay]
  );
  const diffDays = Number(diffQ.rows[0]?.diff_days || 0);
  if (!Number.isFinite(diffDays) || diffDays < 0) return fallback;
  return (diffDays % 10) + 1;
}

function formatProductLabel(productCode, shelfNumber) {
  const code = Number(productCode);
  const shelf = Number(shelfNumber);
  const codePart = Number.isFinite(code) && code > 0 ? String(Math.floor(code)) : '—';
  const shelfPart = Number.isFinite(shelf) && shelf > 0
    ? String(Math.floor(shelf)).padStart(2, '0')
    : '—';
  return `${codePart}--${shelfPart}`;
}

function toBoolean(value, fallback = false) {
  if (typeof value === 'boolean') return value;
  const normalized = String(value ?? '').trim().toLowerCase();
  if (!normalized) return fallback;
  return ['1', 'true', 'yes', 'y', 'on'].includes(normalized);
}

function productMessageText(product) {
  const lines = [
    `🛒 ${product.title}`,
    product.description ? String(product.description).trim() : null,
    `Цена: ${product.price} ₽`,
    `Количество в наличии: ${product.quantity}`,
    'Нажмите "Купить", чтобы добавить в корзину',
  ].filter(Boolean);
  return lines.join('\n');
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    String(value || '').trim(),
  );
}

function normalizeUserRoleForInsert(rawRole) {
  const role = String(rawRole || '').toLowerCase().trim();
  if (['client', 'worker', 'admin', 'tenant', 'creator'].includes(role)) {
    return role;
  }
  return 'client';
}

async function resolveActorUserId(queryable, user) {
  const tokenUserId = String(user?.id || '').trim();
  const tokenEmail = String(user?.email || '').trim();
  const normalizedEmail = tokenEmail.toLowerCase();
  const normalizedName = String(user?.name || '').trim();
  const role = normalizeUserRoleForInsert(user?.base_role || user?.role);
  const tenantId = isUuid(user?.tenant_id) ? String(user.tenant_id).trim() : null;

  if (isUuid(tokenUserId)) {
    const byId = await queryable.query(
      `SELECT id
       FROM users
       WHERE id = $1::uuid
       LIMIT 1`,
      [tokenUserId],
    );
    if (byId.rowCount > 0) return byId.rows[0].id;
  }

  if (normalizedEmail) {
    const byEmail = await queryable.query(
      `SELECT id
       FROM users
       WHERE lower(email) = $1
       ORDER BY created_at DESC
       LIMIT 1`,
      [normalizedEmail],
    );
    if (byEmail.rowCount > 0) return byEmail.rows[0].id;
  }

  if (!isUuid(tokenUserId)) {
    throw new Error('Unable to resolve local actor user id');
  }

  try {
    const inserted = await queryable.query(
      `INSERT INTO users (
         id,
         email,
         role,
         name,
         is_active,
         tenant_id,
         created_at,
         updated_at
       )
       VALUES (
         $1::uuid,
         NULLIF($2::text, ''),
         $3::text,
         NULLIF($4::text, ''),
         true,
         $5::uuid,
         now(),
         now()
       )
       ON CONFLICT (id)
       DO UPDATE SET
         email = COALESCE(users.email, EXCLUDED.email),
         role = COALESCE(NULLIF(users.role, ''), EXCLUDED.role),
         name = COALESCE(users.name, EXCLUDED.name),
         tenant_id = COALESCE(users.tenant_id, EXCLUDED.tenant_id),
         is_active = true,
         updated_at = now()
       RETURNING id`,
      [tokenUserId, normalizedEmail, role, normalizedName, tenantId],
    );
    if (inserted.rowCount > 0) return inserted.rows[0].id;
  } catch (err) {
    if (String(err?.code || '') === '23505' && normalizedEmail) {
      const byEmail = await queryable.query(
        `SELECT id
         FROM users
         WHERE lower(email) = $1
         ORDER BY created_at DESC
         LIMIT 1`,
        [normalizedEmail],
      );
      if (byEmail.rowCount > 0) return byEmail.rows[0].id;
    }
    throw err;
  }

  return tokenUserId;
}

function normalizeRevisionEntry(raw) {
  const item = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const title = String(item.title || '').trim();
  const description = String(item.description || '').trim();
  const price = Number(item.price);
  const quantity = Number(item.quantity);
  const shelfNumber = Number(item.shelf_number);
  return {
    product_id: String(item.product_id || '').trim(),
    message_id: String(item.message_id || '').trim(),
    title,
    description,
    price,
    quantity,
    shelf_number: shelfNumber,
    image_url: normalizeImageUrl(item.image_url),
  };
}

function compareNullableStringsAsc(a, b) {
  return String(a || '').trim().localeCompare(String(b || '').trim(), 'ru', {
    sensitivity: 'base',
    numeric: true,
  });
}

function compareRevisionPosts(a, b) {
  const dayCompare = compareNullableStringsAsc(a.day, b.day);
  if (dayCompare != 0) return dayCompare;

  const shelfCompare =
    toShelfNumber(a.shelf_number, Number.MAX_SAFE_INTEGER) -
    toShelfNumber(b.shelf_number, Number.MAX_SAFE_INTEGER);
  if (shelfCompare !== 0) return shelfCompare;

  const clientCompare = compareNullableStringsAsc(a.client_name, b.client_name);
  if (clientCompare !== 0) return clientCompare;

  const phoneCompare = compareNullableStringsAsc(a.client_phone, b.client_phone);
  if (phoneCompare !== 0) return phoneCompare;

  const createdCompare =
    Date.parse(String(a.created_at || '')) - Date.parse(String(b.created_at || ''));
  if (createdCompare !== 0) return createdCompare;

  const codeCompare =
    toPositiveInteger(a.product_code, Number.MAX_SAFE_INTEGER) -
    toPositiveInteger(b.product_code, Number.MAX_SAFE_INTEGER);
  if (codeCompare !== 0) return codeCompare;

  return compareNullableStringsAsc(a.message_id, b.message_id);
}

function normalizeRevisionState(row) {
  const hasPendingReservation =
    row?.has_pending_processing === true || row?.has_unfulfilled_reservation === true;
  const hasProcessedReservation =
    row?.has_processed_delivery === true || row?.has_fulfilled_reservation === true;

  if (hasProcessedReservation) {
    return {
      revision_state: 'processed',
      revision_allowed: false,
      revision_note: null,
    };
  }

  if (hasPendingReservation) {
    return {
      revision_state: 'bought_pending',
      revision_allowed: false,
      revision_note: 'Купили, отнесите администратору',
    };
  }

  return {
    revision_state: 'available',
    revision_allowed: true,
    revision_note: null,
  };
}

function uniqStrings(values) {
  return Array.from(
    new Set(
      (Array.isArray(values) ? values : [])
        .map((value) => String(value || '').trim())
        .filter(Boolean),
    ),
  );
}

function extractSourceMessageIdsFromPayload(payload) {
  const data = parseSettings(payload);
  const ids = [];
  if (Array.isArray(data.source_message_ids)) {
    ids.push(...data.source_message_ids);
  }
  if (data.source_message_id) {
    ids.push(data.source_message_id);
  }
  return uniqStrings(ids);
}

async function fetchVisibleCatalogMessageIdsForProduct(client, channelId, productId) {
  if (!isUuid(productId)) return [];
  const q = await client.query(
    `SELECT m.id
     FROM messages m
     WHERE m.chat_id = $1
       AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
       AND COALESCE(m.meta->>'product_id', '') = $2::text
       AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
     ORDER BY m.created_at DESC, m.id DESC`,
    [channelId, productId],
  );
  return q.rows.map((row) => String(row.id || '').trim()).filter(Boolean);
}

async function fetchActivePendingQueueForProduct(client, productId, channelId) {
  if (!isUuid(productId)) return null;
  const q = await client.query(
    `SELECT id,
            product_id,
            channel_id,
            queued_by,
            status,
            is_sent,
            payload,
            created_at
     FROM product_publication_queue
     WHERE product_id = $1::uuid
       AND channel_id = $2::uuid
       AND status = 'pending'
       AND COALESCE(is_sent, false) = false
     ORDER BY created_at DESC
     LIMIT 1
     FOR UPDATE`,
    [productId, channelId],
  );
  return q.rowCount > 0 ? q.rows[0] : null;
}

async function hideCatalogMessagesForRevision(client, channelId, messageIds, actorUserId = null) {
  const ids = uniqStrings(messageIds);
  if (!ids.length) return [];
  const q = await client.query(
    `UPDATE messages
     SET meta = COALESCE(meta, '{}'::jsonb)
       || jsonb_build_object(
            'hidden_for_all', true,
            'hidden_by_revision', true,
            'hidden_by_revision_at', now()::text,
            'hidden_by_revision_actor_id', NULLIF($3::text, '')
          )
     WHERE chat_id = $1
       AND id = ANY($2::uuid[])
     RETURNING id, chat_id, sender_id, text, meta, created_at`,
    [channelId, ids, actorUserId ? String(actorUserId) : ''],
  );
  return q.rows;
}

async function restoreCatalogMessagesHiddenByRevision(client, channelId, messageIds) {
  const ids = uniqStrings(messageIds);
  if (!ids.length) return [];
  const q = await client.query(
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
    [channelId, ids],
  );
  return q.rows;
}

async function fetchRevisionTarget(client, channelId, item) {
  if (item.message_id) {
    const q = await client.query(
      `SELECT m.id AS message_id,
              m.chat_id,
              m.created_at,
              to_char((m.created_at AT TIME ZONE $3), 'YYYY-MM-DD') AS day,
              m.meta,
              COALESCE((m.meta->>'hidden_for_all')::boolean, false) AS message_hidden,
              p.id AS product_id,
              p.product_code,
              p.shelf_number AS product_shelf_number,
              p.title AS product_title,
              p.description AS product_description,
              p.price AS product_price,
              p.quantity AS product_quantity,
              p.image_url AS product_image_url
       FROM messages m
       LEFT JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
       WHERE m.id = $1
         AND m.chat_id = $2
         AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
       LIMIT 1`,
      [item.message_id, channelId, SAMARA_TZ],
    );
    return q.rowCount > 0 ? q.rows[0] : null;
  }

  if (!isUuid(item.product_id)) return null;
  const q = await client.query(
    `SELECT m.id AS message_id,
            m.chat_id,
            m.created_at,
            to_char((m.created_at AT TIME ZONE $3), 'YYYY-MM-DD') AS day,
            m.meta,
            COALESCE((m.meta->>'hidden_for_all')::boolean, false) AS message_hidden,
            p.id AS product_id,
            p.product_code,
            p.shelf_number AS product_shelf_number,
            p.title AS product_title,
            p.description AS product_description,
            p.price AS product_price,
            p.quantity AS product_quantity,
            p.image_url AS product_image_url
     FROM products p
     LEFT JOIN LATERAL (
       SELECT mm.id,
              mm.chat_id,
              mm.created_at,
              mm.meta
       FROM messages mm
       WHERE mm.chat_id = $2
         AND COALESCE(mm.meta->>'kind', '') = 'catalog_product'
         AND COALESCE(mm.meta->>'product_id', '') = p.id::text
       ORDER BY COALESCE((mm.meta->>'hidden_for_all')::boolean, false) ASC,
                mm.created_at DESC,
                mm.id DESC
       LIMIT 1
     ) m ON true
     WHERE p.id = $1::uuid
     LIMIT 1`,
    [item.product_id, channelId, SAMARA_TZ],
  );
  return q.rowCount > 0 ? q.rows[0] : null;
}

async function fetchRevisionEligibilityForProduct(client, productId) {
  if (!isUuid(productId)) {
    return normalizeRevisionState({});
  }
  const q = await client.query(
    `SELECT
       EXISTS (
         SELECT 1
         FROM cart_items ci
         WHERE ci.product_id = $1::uuid
           AND ci.status = ANY($2::text[])
       ) AS has_pending_processing,
       EXISTS (
         SELECT 1
         FROM cart_items ci
         WHERE ci.product_id = $1::uuid
           AND ci.status = ANY($3::text[])
       ) AS has_processed_delivery,
       EXISTS (
         SELECT 1
         FROM reservations r
         WHERE r.product_id = $1::uuid
           AND r.is_fulfilled = false
       ) AS has_unfulfilled_reservation,
       EXISTS (
         SELECT 1
         FROM reservations r
         WHERE r.product_id = $1::uuid
           AND r.is_fulfilled = true
       ) AS has_fulfilled_reservation`,
    [
      productId,
      REVISION_PENDING_CART_STATUSES,
      REVISION_COMPLETED_CART_STATUSES,
    ],
  );
  return normalizeRevisionState(q.rows[0] || {});
}

function buildRevisionQueuePayload({
  post,
  title,
  description,
  price,
  quantity,
  shelfNumber,
  imageUrl,
  selectedDates = [],
  sourceMessageIds = [],
  existingPayload = {},
  manual = false,
  auto = false,
}) {
  const previous = parseSettings(existingPayload);
  const mergedSourceMessageIds = uniqStrings([
    ...extractSourceMessageIdsFromPayload(previous),
    ...sourceMessageIds,
  ]);
  return {
    ...previous,
    title,
    description,
    price,
    quantity,
    shelf_number: shelfNumber,
    image_url: imageUrl,
    revision_manual: manual,
    revision_auto: auto,
    source_message_id:
      mergedSourceMessageIds[0] ||
      String(post?.message_id || previous.source_message_id || '').trim() ||
      null,
    source_message_ids: mergedSourceMessageIds,
    hide_old_versions: true,
    source_revision_day:
      String(post?.day || previous.source_revision_day || '').trim() || null,
    revision_dates: uniqStrings(selectedDates),
    revision_created_at: new Date().toISOString(),
  };
}

async function fetchRevisionDays(client, channelId, limit = 2) {
  const safeLimit = Math.min(Math.max(Number(limit) || 2, 1), 10);
  const q = await client.query(
    `WITH visible_catalog AS (
       SELECT m.id AS message_id,
              m.created_at,
              p.id AS product_id
       FROM messages m
       LEFT JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
       WHERE m.chat_id = $1
         AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
     ),
     queue_state AS (
       SELECT q.product_id,
              true AS has_pending
       FROM product_publication_queue q
       WHERE q.channel_id = $1
         AND q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
       GROUP BY q.product_id
     ),
     cart_state AS (
       SELECT ci.product_id,
              BOOL_OR(ci.status = ANY($2::text[])) AS has_pending_processing,
              BOOL_OR(ci.status = ANY($3::text[])) AS has_processed_delivery
       FROM cart_items ci
       GROUP BY ci.product_id
     ),
     reservation_state AS (
       SELECT r.product_id,
              BOOL_OR(r.is_fulfilled = false) AS has_unfulfilled_reservation,
              BOOL_OR(r.is_fulfilled = true) AS has_fulfilled_reservation
       FROM reservations r
       GROUP BY r.product_id
     )
     SELECT to_char((vc.created_at AT TIME ZONE $4), 'YYYY-MM-DD') AS day,
            to_char((vc.created_at AT TIME ZONE $4), 'DD.MM.YYYY') AS label,
            COUNT(*)::int AS posts
     FROM visible_catalog vc
     LEFT JOIN queue_state qs ON qs.product_id = vc.product_id
     LEFT JOIN cart_state cs ON cs.product_id = vc.product_id
     LEFT JOIN reservation_state rs ON rs.product_id = vc.product_id
     WHERE COALESCE(qs.has_pending, false) = false
       AND NOT (
         COALESCE(cs.has_processed_delivery, false) = true
         OR COALESCE(rs.has_fulfilled_reservation, false) = true
       )
     GROUP BY day, label
     ORDER BY day ASC
     LIMIT $5`,
    [
      channelId,
      REVISION_PENDING_CART_STATUSES,
      REVISION_COMPLETED_CART_STATUSES,
      SAMARA_TZ,
      safeLimit,
    ],
  );
  return q.rows;
}

async function fetchRevisionPosts(client, channelId, selectedDates) {
  const dateFilter = Array.isArray(selectedDates) && selectedDates.length > 0 ? selectedDates : null;
  const rows = await client.query(
    `WITH visible_catalog AS (
       SELECT m.id AS message_id,
              m.chat_id,
              m.created_at,
              m.text,
              m.meta,
              p.id AS product_id,
              p.product_code,
              p.shelf_number AS product_shelf_number,
              p.title AS product_title,
              p.description AS product_description,
              p.price AS product_price,
              p.quantity AS product_quantity,
              p.image_url AS product_image_url
       FROM messages m
       LEFT JOIN products p ON p.id::text = COALESCE(m.meta->>'product_id', '')
       WHERE m.chat_id = $1
         AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
         AND (
           $2::text[] IS NULL
           OR to_char((m.created_at AT TIME ZONE $3), 'YYYY-MM-DD') = ANY($2::text[])
         )
     ),
     queue_state AS (
       SELECT q.product_id,
              true AS has_pending
       FROM product_publication_queue q
       WHERE q.channel_id = $1
         AND q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
       GROUP BY q.product_id
     ),
     cart_state AS (
       SELECT ci.product_id,
              BOOL_OR(ci.status = ANY($4::text[])) AS has_pending_processing,
              BOOL_OR(ci.status = ANY($5::text[])) AS has_processed_delivery
       FROM cart_items ci
       GROUP BY ci.product_id
     ),
     reservation_state AS (
       SELECT r.product_id,
              BOOL_OR(r.is_fulfilled = false) AS has_unfulfilled_reservation,
              BOOL_OR(r.is_fulfilled = true) AS has_fulfilled_reservation
       FROM reservations r
       GROUP BY r.product_id
     )
     SELECT vc.message_id,
            vc.chat_id,
            vc.created_at,
            vc.text,
            vc.meta,
            vc.product_id,
            vc.product_code,
            vc.product_shelf_number,
            vc.product_title,
            vc.product_description,
            vc.product_price,
            vc.product_quantity,
            vc.product_image_url,
            to_char((vc.created_at AT TIME ZONE $3), 'YYYY-MM-DD') AS day,
            to_char((vc.created_at AT TIME ZONE $3), 'DD.MM.YYYY') AS day_label,
            COALESCE(qs.has_pending, false) AS has_pending_queue,
            COALESCE(cs.has_pending_processing, false) AS has_pending_processing,
            COALESCE(cs.has_processed_delivery, false) AS has_processed_delivery,
            COALESCE(rs.has_unfulfilled_reservation, false) AS has_unfulfilled_reservation,
            COALESCE(rs.has_fulfilled_reservation, false) AS has_fulfilled_reservation
     FROM visible_catalog vc
     LEFT JOIN queue_state qs ON qs.product_id = vc.product_id
     LEFT JOIN cart_state cs ON cs.product_id = vc.product_id
     LEFT JOIN reservation_state rs ON rs.product_id = vc.product_id
     WHERE COALESCE(qs.has_pending, false) = false
       AND NOT (
         COALESCE(cs.has_processed_delivery, false) = true
         OR COALESCE(rs.has_fulfilled_reservation, false) = true
       )`,
    [
      channelId,
      dateFilter,
      SAMARA_TZ,
      REVISION_PENDING_CART_STATUSES,
      REVISION_COMPLETED_CART_STATUSES,
    ]
  );
  return rows.rows.map((row) => {
    const meta = parseSettings(row.meta);
    const fallbackPrice = toPositiveNumber(meta.price, 0);
    const fallbackQuantity = toPositiveInteger(meta.quantity, 1);
    const fallbackImage = normalizeImageUrl(meta.image_url);
    const state = normalizeRevisionState(row);
    return {
      message_id: row.message_id,
      chat_id: row.chat_id,
      created_at: row.created_at,
      text: row.text,
      meta,
      day: String(row.day || '').trim(),
      day_label: String(row.day_label || '').trim(),
      product_id: row.product_id || meta.product_id || null,
      product_code: row.product_code ?? meta.product_code ?? null,
      shelf_number: Number(row.product_shelf_number ?? meta.shelf_number ?? 1),
      title: String(row.product_title || '').trim(),
      description: String(row.product_description || '').trim(),
      price: Number(row.product_price ?? fallbackPrice),
      quantity: Number(row.product_quantity ?? fallbackQuantity),
      image_url: normalizeImageUrl(row.product_image_url) || fallbackImage,
      revision_state: state.revision_state,
      revision_allowed: state.revision_allowed,
      revision_note: state.revision_note,
      has_pending_processing: row.has_pending_processing === true,
      has_unfulfilled_reservation: row.has_unfulfilled_reservation === true,
    };
  }).sort(compareRevisionPosts);
}

async function allocateProductCode(client, tenantId = null) {
  void tenantId;
  await client.query('LOCK TABLE products IN SHARE ROW EXCLUSIVE MODE');

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

async function getAllowedPostChannels(userRole, tenantId = null) {
  const role = String(userRole || '').toLowerCase().trim();
  if (!['worker', 'admin', 'tenant', 'creator'].includes(role)) {
    return [];
  }

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const { mainChannel } = await ensureSystemChannels(
      client,
      null,
      tenantId || null,
    );
    await client.query('COMMIT');
    return [
      {
        ...mainChannel,
        settings: parseSettings(mainChannel.settings),
      },
    ];
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Список каналов, доступных для очереди публикаций
router.get('/channels', authMiddleware, requireRole('worker', 'admin', 'tenant', 'creator'), async (req, res) => {
  try {
    const data = await getAllowedPostChannels(req.user?.role, req.user?.tenant_id || null);
    return res.json({ ok: true, data });
  } catch (err) {
    console.error('worker.channels.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Поиск старых товаров по названию/описанию
router.get('/products/search', authMiddleware, requireRole('worker', 'admin', 'tenant', 'creator'), async (req, res) => {
  try {
    const q = String(req.query.q || '').trim();
    if (!q) return res.json({ ok: true, data: [] });
    return await runInRequestTenantScope(req, async () => {
      const client = await db.pool.connect();
      try {
        const actorUserId = await resolveActorUserId(client, req.user);
        await client.query('BEGIN');
        const { mainChannel } = await ensureSystemChannels(
          client,
          actorUserId,
          req.user.tenant_id || null,
        );

        const result = await client.query(
          `WITH ranked AS (
             SELECT p.id,
                    p.product_code,
                    p.shelf_number,
                    p.title,
                    p.description,
                    p.price,
                    p.quantity,
                    p.image_url,
                    p.status,
                    p.created_at,
                    p.updated_at,
                    EXISTS (
                      SELECT 1
                      FROM messages m
                      WHERE m.chat_id = $3
                        AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
                        AND COALESCE(m.meta->>'product_id', '') = p.id::text
                        AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
                    ) AS is_visible_in_main_channel,
                    EXISTS (
                      SELECT 1
                      FROM product_publication_queue qp
                      WHERE qp.product_id = p.id
                        AND qp.channel_id = $3
                        AND qp.status = 'pending'
                        AND COALESCE(qp.is_sent, false) = false
                    ) AS has_pending_in_main_channel,
                    ROW_NUMBER() OVER (
                      PARTITION BY LOWER(TRIM(p.title))
                      ORDER BY p.created_at DESC, p.updated_at DESC
                    ) AS title_rank
             FROM products p
             WHERE (p.title ILIKE $1 OR p.description ILIKE $1)
               AND EXISTS (
                 SELECT 1
                 FROM product_publication_queue q
                 JOIN chats c ON c.id = q.channel_id
                 WHERE q.product_id = p.id
                   AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
               )
           )
           SELECT id, product_code, shelf_number, title, description, price, quantity, image_url, status,
                  created_at, updated_at, is_visible_in_main_channel, has_pending_in_main_channel,
                  CASE
                    WHEN is_visible_in_main_channel THEN false
                    WHEN has_pending_in_main_channel THEN false
                    ELSE true
                  END AS requeue_allowed
           FROM ranked
           WHERE title_rank <= 2
           ORDER BY requeue_allowed DESC, created_at DESC, updated_at DESC
           LIMIT 30`,
          [`%${q}%`, req.user?.tenant_id || null, mainChannel.id],
        );
        await client.query('COMMIT');

        const data = result.rows.map((row) => ({
          ...row,
          reuse_hint:
            row.is_visible_in_main_channel === true
              ? 'Сейчас товар в основном канале. Используйте Ревизию.'
              : row.has_pending_in_main_channel === true
                  ? 'Товар уже стоит в очереди публикации.'
                  : null,
        }));
        return res.json({ ok: true, data });
      } catch (err) {
        try {
          await client.query('ROLLBACK');
        } catch (_) {}
        throw err;
      } finally {
        client.release();
      }
    });
  } catch (err) {
    console.error('worker.products.search error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

// Добавить новый товар в очередь публикации
router.post(
  '/channels/:chatId/posts',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  uploadProductImage,
  async (req, res) => {
    try {
      return await runInRequestTenantScope(req, async () => {
        const client = await db.pool.connect();
        try {
          const actorUserId = await resolveActorUserId(client, req.user);
          const {
            title,
            description = '',
            price,
            quantity = 1,
          } = req.body || {};

          const imageUrl = req.file ? toAbsoluteImageUrl(req, req.file) : normalizeImageUrl(req.body?.image_url);
          const normalizedTitle = String(title || '').trim();
          if (!normalizedTitle) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
          }
          if (!imageUrl) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Фото товара обязательно' });
          }

          const normalizedPrice = toPositiveNumber(price, -1);
          if (normalizedPrice <= 0) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Цена товара должна быть больше нуля' });
          }
          const rawQuantity = quantity == null || quantity === '' ? 1 : Number(quantity);
          if (!Number.isFinite(rawQuantity) || rawQuantity <= 0) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Количество должно быть больше нуля' });
          }
          const normalizedQuantity = Math.floor(rawQuantity);
          const normalizedShelfNumber = await resolveAutoShelfNumber(
            client,
            req.user?.tenant_id || null,
            null,
            1
          );
          const normalizedDescription = String(description || '').trim();
          if (!hasAtLeastTwoLetters(normalizedDescription)) {
            removeUploadedFile(req.file);
            return res.status(400).json({
              ok: false,
              error: 'Описание должно содержать минимум 2 буквы',
            });
          }

          await client.query('BEGIN');
          const { mainChannel } = await ensureSystemChannels(
            client,
            actorUserId,
            req.user.tenant_id,
          );
          const targetChannelId = String(mainChannel.id);

          const code = await allocateProductCode(client, req.user?.tenant_id || null);

          const productInsert = await client.query(
            `INSERT INTO products (id, title, description, price, quantity, shelf_number, image_url, created_by, status, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'draft', now(), now())
             RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status`,
            [
              uuidv4(),
              normalizedTitle,
              normalizedDescription,
              normalizedPrice,
              normalizedQuantity,
              normalizedShelfNumber,
              imageUrl,
              actorUserId,
            ]
          );
          const productId = productInsert.rows[0].id;
          const productCodeUpdate = await client.query(
            `UPDATE products
             SET product_code = $1,
                 updated_at = now()
             WHERE id = $2
             RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status`,
            [code, productId]
          );
          const product = productCodeUpdate.rows[0];
          if (product?.image_url) {
            await registerPublicImageUpload({
              queryable: client,
              ownerKind: 'product_image',
              ownerId: product.id,
              rawUrl: product.image_url,
            });
          }
          const cardSnapshot = await upsertProductCardSnapshot(client, product, {
            req,
            tenantId: req.user?.tenant_id || null,
          });

          const payload = {
            title: product.title,
            description: product.description,
            price: Number(product.price),
            quantity: Number(product.quantity),
            shelf_number: Number(product.shelf_number),
            image_url: product.image_url,
            card_snapshot: cardSnapshot,
          };

          const queueInsert = await client.query(
            `INSERT INTO product_publication_queue (id, product_id, channel_id, queued_by, status, is_sent, payload, created_at)
             VALUES ($1, $2, $3, $4, 'pending', false, $5::jsonb, now())
             RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
            [uuidv4(), product.id, targetChannelId, actorUserId, JSON.stringify(payload)]
          );

          await client.query('COMMIT');

          return res.status(201).json({
            ok: true,
            data: {
              queue: queueInsert.rows[0],
              product,
              card_snapshot: cardSnapshot,
              product_label: formatProductLabel(product.product_code, product.shelf_number),
              message: 'Товар отправлен в очередь. Пост появится после подтверждения админом/создателем.',
            },
          });
        } catch (err) {
          try {
            await client.query('ROLLBACK');
          } catch (_) {}
          removeUploadedFile(req.file);
          console.error('worker.channels.post_product error', err);
          return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
        } finally {
          client.release();
        }
      });
    } catch (err) {
      removeUploadedFile(req.file);
      console.error('worker.channels.post_product scope error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

// Переиспользование старого товара (обновить и снова отправить в очередь)
router.post(
  '/products/:productId/requeue',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  uploadProductImage,
  async (req, res) => {
    const { productId } = req.params;
    try {
      return await runInRequestTenantScope(req, async () => {
        const client = await db.pool.connect();
        try {
          const actorUserId = await resolveActorUserId(client, req.user);
          const {
            channel_id,
            title,
            description,
            price,
            quantity,
            merge_pending,
          } = req.body || {};
          const shouldMergePending =
            merge_pending === true || String(merge_pending || '').toLowerCase() === 'true';

          if (!channel_id) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'channel_id обязателен' });
          }

          await client.query('BEGIN');
          const { mainChannel } = await ensureSystemChannels(
            client,
            actorUserId,
            req.user.tenant_id,
          );
          const targetChannelId = String(mainChannel.id);

          const productQ = await client.query(
            `SELECT id, product_code, shelf_number, title, description, price, quantity, image_url
             FROM products
             WHERE id = $1
               AND EXISTS (
                 SELECT 1
                 FROM product_publication_queue q
                 JOIN chats c ON c.id = q.channel_id
                 WHERE q.product_id = products.id
                   AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
               )
             LIMIT 1`,
            [productId, req.user?.tenant_id || null]
          );
          if (productQ.rowCount === 0) {
            removeUploadedFile(req.file);
            return res.status(404).json({ ok: false, error: 'Товар не найден' });
          }
          const current = productQ.rows[0];
          const liveMainChannelQ = await client.query(
            `SELECT 1
             FROM messages m
             WHERE m.chat_id = $1
               AND COALESCE(m.meta->>'kind', '') = 'catalog_product'
               AND COALESCE(m.meta->>'product_id', '') = $2::text
               AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
             LIMIT 1`,
            [targetChannelId, productId],
          );
          if (liveMainChannelQ.rowCount > 0) {
            removeUploadedFile(req.file);
            await client.query('ROLLBACK');
            return res.status(409).json({
              ok: false,
              error: 'Товар уже находится в основном канале. Используйте ревизию.',
            });
          }

          const nextTitle = String(title || current.title || '').trim();
          const nextDescription = String(description ?? current.description ?? '').trim();
          const nextPrice = price != null ? toPositiveNumber(price, -1) : Number(current.price);
          const nextQuantity =
            quantity != null && quantity !== ''
              ? Number(quantity)
              : Number(current.quantity || 1);
          const nextShelfNumber = await resolveAutoShelfNumber(
            client,
            req.user?.tenant_id || null,
            null,
            1
          );
          let nextImageUrl = current.image_url;
          if (req.file) {
            nextImageUrl = toAbsoluteImageUrl(req, req.file);
          } else if (Object.prototype.hasOwnProperty.call(req.body || {}, 'image_url')) {
            nextImageUrl = normalizeImageUrl(req.body.image_url);
          }

          if (!nextTitle) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
          }
          if (!hasAtLeastTwoLetters(nextDescription)) {
            removeUploadedFile(req.file);
            return res.status(400).json({
              ok: false,
              error: 'Описание должно содержать минимум 2 буквы',
            });
          }
          if (!Number.isFinite(nextPrice) || nextPrice <= 0) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Цена товара должна быть больше нуля' });
          }
          if (!Number.isFinite(nextQuantity) || nextQuantity <= 0) {
            removeUploadedFile(req.file);
            return res.status(400).json({
              ok: false,
              error: 'Количество должно быть больше нуля',
            });
          }
          if (!nextImageUrl) {
            removeUploadedFile(req.file);
            return res.status(400).json({ ok: false, error: 'Фото товара обязательно' });
          }

          const nextCode = current.product_code != null
            ? Number(current.product_code)
            : await allocateProductCode(client, req.user?.tenant_id || null);

          const upd = await client.query(
            `UPDATE products
             SET title = $1,
                 description = $2,
                 price = $3,
                 quantity = $4,
                 shelf_number = $5,
                 image_url = $6,
                 product_code = $7,
                 status = 'draft',
                 updated_at = now()
             WHERE id = $8
             RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status`,
            [
              nextTitle,
              nextDescription,
              nextPrice,
              Math.floor(nextQuantity),
              Math.floor(nextShelfNumber),
              nextImageUrl,
              nextCode,
              productId,
            ]
          );
          const product = upd.rows[0];
          if (product?.image_url) {
            await registerPublicImageUpload({
              queryable: client,
              ownerKind: 'product_image',
              ownerId: product.id,
              rawUrl: product.image_url,
            });
          }
          const cardSnapshot = await upsertProductCardSnapshot(client, product, {
            req,
            tenantId: req.user?.tenant_id || null,
          });

          const payload = {
            title: product.title,
            description: product.description,
            price: Number(product.price),
            quantity: Number(product.quantity),
            shelf_number: Number(product.shelf_number),
            image_url: product.image_url,
            card_snapshot: cardSnapshot,
          };

          let queueRow;
          if (shouldMergePending) {
            const existingPending = await client.query(
              `SELECT id
               FROM product_publication_queue
               WHERE product_id = $1
                 AND channel_id = $2
                 AND queued_by = $3
                 AND status = 'pending'
                 AND COALESCE(is_sent, false) = false
               ORDER BY created_at DESC
               LIMIT 1`,
              [product.id, targetChannelId, actorUserId]
            );

            if (existingPending.rowCount > 0) {
              const queueId = existingPending.rows[0].id;
              const mergedQueue = await client.query(
                `UPDATE product_publication_queue
                 SET payload = $2::jsonb,
                     created_at = now()
                 WHERE id = $1
                 RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
                [queueId, JSON.stringify(payload)]
              );
              queueRow = mergedQueue.rows[0];

              await client.query(
                `UPDATE product_publication_queue
                 SET status = 'archived',
                     is_sent = true
                 WHERE product_id = $1
                   AND channel_id = $2
                   AND queued_by = $3
                   AND status = 'pending'
                   AND COALESCE(is_sent, false) = false
                   AND id <> $4`,
                [product.id, targetChannelId, actorUserId, queueId]
              );
            }
          }

          if (!queueRow) {
            const queueInsert = await client.query(
              `INSERT INTO product_publication_queue (id, product_id, channel_id, queued_by, status, is_sent, payload, created_at)
               VALUES ($1, $2, $3, $4, 'pending', false, $5::jsonb, now())
               RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
              [uuidv4(), product.id, targetChannelId, actorUserId, JSON.stringify(payload)]
            );
            queueRow = queueInsert.rows[0];
          }

          await client.query('COMMIT');

          return res.status(201).json({
            ok: true,
            data: {
              queue: queueRow,
              product,
              card_snapshot: cardSnapshot,
              product_label: formatProductLabel(product.product_code, product.shelf_number),
              message: 'Товар переотправлен в очередь',
            },
          });
        } catch (err) {
          try {
            await client.query('ROLLBACK');
          } catch (_) {}
          removeUploadedFile(req.file);
          console.error('worker.products.requeue error', err);
          return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
        } finally {
          client.release();
        }
      });
    } catch (err) {
      removeUploadedFile(req.file);
      console.error('worker.products.requeue scope error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

router.get(
  '/queue/mine',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    try {
      const result = await runInRequestTenantScope(req, async () => {
        const actorUserId = await resolveActorUserId(db, req.user);
        return db.query(
          `SELECT q.id,
                  q.product_id,
                  q.channel_id,
                  q.queued_by,
                  q.status,
                  q.is_sent,
                  q.payload,
                  q.created_at,
                  c.title AS channel_title,
                  p.product_code,
                  COALESCE(NULLIF(q.payload->>'shelf_number', '')::int, p.shelf_number) AS product_shelf_number,
                  COALESCE(NULLIF(BTRIM(q.payload->>'title'), ''), p.title) AS product_title,
                  COALESCE(NULLIF(BTRIM(q.payload->>'description'), ''), p.description) AS product_description,
                  COALESCE(NULLIF(q.payload->>'price', '')::numeric, p.price) AS product_price,
                  COALESCE(NULLIF(q.payload->>'quantity', '')::int, p.quantity) AS product_quantity,
                  COALESCE(NULLIF(BTRIM(q.payload->>'image_url'), ''), p.image_url) AS product_image_url
           FROM product_publication_queue q
           JOIN products p ON p.id = q.product_id
           JOIN chats c ON c.id = q.channel_id
           WHERE q.queued_by = $1
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
           ORDER BY q.created_at DESC, q.id DESC`,
          [actorUserId]
        );
      });
      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error('worker.queue.mine error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

router.patch(
  '/queue/:queueId',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    const queueId = String(req.params.queueId || '').trim();
    const title = String(req.body?.title || '').trim();
    const description = String(req.body?.description || '').trim();
    const price = Number(req.body?.price);
    const quantity = Number(req.body?.quantity);
    const rawShelfNumber = Number(req.body?.shelf_number);
    const shelfNumber =
      Number.isFinite(rawShelfNumber) && rawShelfNumber > 0
        ? Math.floor(rawShelfNumber)
        : null;

    if (!queueId) {
      return res.status(400).json({ ok: false, error: 'queueId обязателен' });
    }
    if (!title) {
      return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
    }
    if (!hasAtLeastTwoLetters(description)) {
      return res.status(400).json({
        ok: false,
        error: 'Описание должно содержать минимум 2 буквы',
      });
    }
    if (!Number.isFinite(price) || price <= 0) {
      return res.status(400).json({ ok: false, error: 'Цена должна быть больше нуля' });
    }
    if (!Number.isFinite(quantity) || quantity <= 0) {
      return res.status(400).json({ ok: false, error: 'Количество должно быть больше нуля' });
    }

    try {
      const result = await runInRequestTenantScope(req, async () => {
        const actorUserId = await resolveActorUserId(db, req.user);
        return db.query(
          `UPDATE product_publication_queue q
           SET payload = jsonb_strip_nulls(
                 COALESCE(q.payload, '{}'::jsonb) ||
                 jsonb_build_object(
                   'title', $3::text,
                   'description', $4::text,
                   'price', $5::numeric,
                   'quantity', $6::int,
                   'shelf_number', COALESCE($7::int, NULLIF(q.payload->>'shelf_number', '')::int),
                   'image_url', NULLIF(BTRIM(COALESCE(q.payload->>'image_url', '')), '')
                 )
               )
           WHERE q.id = $1
             AND q.queued_by = $2
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
           RETURNING q.id`,
          [
            queueId,
            actorUserId,
            title,
            description,
            price,
            Math.floor(quantity),
            shelfNumber,
          ]
        );
      });
      if (result.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: 'Пост не найден, уже опубликован или не принадлежит вам',
        });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error('worker.queue.patch error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

router.delete(
  '/queue/:queueId',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    const queueId = String(req.params.queueId || '').trim();
    if (!queueId) {
      return res.status(400).json({ ok: false, error: 'queueId обязателен' });
    }

    try {
      const client = await db.pool.connect();
      let restoredMessages = [];
      let channelId = null;
      try {
        const actorUserId = await resolveActorUserId(client, req.user);
        await client.query('BEGIN');
        const queueQ = await client.query(
          `SELECT q.id,
                  q.channel_id,
                  q.product_id,
                  q.payload
           FROM product_publication_queue q
           WHERE q.id = $1
             AND q.queued_by = $2
             AND q.status = 'pending'
             AND COALESCE(q.is_sent, false) = false
           LIMIT 1
           FOR UPDATE`,
          [queueId, actorUserId],
        );
        if (queueQ.rowCount === 0) {
          await client.query('ROLLBACK');
          return res.status(404).json({
            ok: false,
            error: 'Пост не найден, уже опубликован или не принадлежит вам',
          });
        }

        const queueRow = queueQ.rows[0];
        channelId = String(queueRow.channel_id || '').trim() || null;
        const payload = parseSettings(queueRow.payload);
        const isRevisionQueue =
          payload.revision_manual === true || payload.revision_auto === true;
        if (isRevisionQueue && channelId) {
          restoredMessages = await restoreCatalogMessagesHiddenByRevision(
            client,
            channelId,
            extractSourceMessageIdsFromPayload(payload),
          );
        }

        await client.query(
          `DELETE FROM product_publication_queue
           WHERE id = $1`,
          [queueId],
        );
        if (channelId) {
          await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [channelId]);
        }
        await client.query('COMMIT');
      } catch (err) {
        try {
          await client.query('ROLLBACK');
        } catch (_) {}
        throw err;
      } finally {
        client.release();
      }

      const io = req.app.get('io');
      if (io && channelId) {
        for (const message of restoredMessages) {
          io.to(`chat:${channelId}`).emit('chat:message', {
            chatId: channelId,
            message: decryptMessageRow(message),
          });
        }
        emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
          chatId: channelId,
        });
      }

      return res.json({
        ok: true,
        data: {
          restored_count: restoredMessages.length,
        },
      });
    } catch (err) {
      console.error('worker.queue.delete error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    }
  }
);

router.get(
  '/revision/dates',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      const actorUserId = await resolveActorUserId(client, req.user);
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        actorUserId,
        req.user.tenant_id || null
      );
      const days = await fetchRevisionDays(client, mainChannel.id, 2);
      await client.query('COMMIT');
      return res.json({ ok: true, data: days });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.dates error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.get(
  '/revision/posts',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    const selectedDates = parseRevisionDates(req.query?.dates);
    const client = await db.pool.connect();
    try {
      const actorUserId = await resolveActorUserId(client, req.user);
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        actorUserId,
        req.user.tenant_id || null
      );
      const fallbackDays = selectedDates.length > 0
        ? selectedDates
        : (await fetchRevisionDays(client, mainChannel.id, 1)).map((x) => x.day);
      const posts = await fetchRevisionPosts(client, mainChannel.id, fallbackDays);
      await client.query('COMMIT');
      return res.json({
        ok: true,
        data: {
          dates: fallbackDays,
          posts,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.posts error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.post(
  '/revision/manual',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    const entries = Array.isArray(req.body?.entries) ? req.body.entries : [];
    if (!entries.length) {
      return res.status(400).json({ ok: false, error: 'Передайте entries для ручной ревизии' });
    }
    if (entries.length > 200) {
      return res.status(400).json({ ok: false, error: 'Слишком много позиций за один запрос' });
    }

    const normalized = entries.map(normalizeRevisionEntry);
    for (const item of normalized) {
      if (!item.product_id && !item.message_id) {
        return res.status(400).json({
          ok: false,
          error: 'Для каждой позиции нужен product_id или message_id',
        });
      }
      if (!item.title) {
        return res.status(400).json({ ok: false, error: 'Название товара обязательно' });
      }
      if (!hasAtLeastTwoLetters(item.description)) {
        return res.status(400).json({
          ok: false,
          error: 'Описание должно содержать минимум 2 буквы',
        });
      }
      if (!Number.isFinite(item.price) || item.price <= 0) {
        return res.status(400).json({ ok: false, error: 'Цена должна быть больше нуля' });
      }
      if (!Number.isFinite(item.quantity) || item.quantity <= 0) {
        return res.status(400).json({ ok: false, error: 'Количество должно быть больше нуля' });
      }
      if (Number.isFinite(item.shelf_number) && item.shelf_number <= 0) {
        return res.status(400).json({ ok: false, error: 'Номер полки должен быть больше нуля' });
      }
    }

    const client = await db.pool.connect();
    try {
      const actorUserId = await resolveActorUserId(client, req.user);
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        actorUserId,
        req.user.tenant_id || null
      );

      const hiddenMessagesById = new Map();
      const queuedItems = [];
      let reusedPendingCount = 0;
      let blockedCount = 0;

      for (const item of normalized) {
        const target = await fetchRevisionTarget(client, mainChannel.id, item);
        if (!target) {
          continue;
        }
        const productId = String(target.product_id || '').trim();
        if (!productId) {
          continue;
        }
        const revisionState = await fetchRevisionEligibilityForProduct(client, productId);
        if (revisionState.revision_state !== 'available') {
          blockedCount += 1;
          continue;
        }

        const existingPending = await fetchActivePendingQueueForProduct(
          client,
          productId,
          mainChannel.id,
        );
        const visibleSourceMessageIds = await fetchVisibleCatalogMessageIdsForProduct(
          client,
          mainChannel.id,
          productId,
        );
        const sourceMessageIds = uniqStrings([
          ...visibleSourceMessageIds,
          ...(existingPending ? extractSourceMessageIdsFromPayload(existingPending.payload) : []),
          String(target.message_id || '').trim(),
        ]);

        const nextQuantity = Math.floor(item.quantity);
        const nextShelfNumber = toShelfNumber(target.product_shelf_number, 1);
        const nextPrice = roundPriceToStep(item.price, 50, 50);
        const nextImageUrl = item.image_url || normalizeImageUrl(target.product_image_url) || null;
        const payload = buildRevisionQueuePayload({
          post: {
            message_id: target.message_id,
            day: String(target.day || '').trim() || null,
          },
          title: item.title,
          description: item.description,
          price: nextPrice,
          quantity: nextQuantity,
          shelfNumber: nextShelfNumber,
          imageUrl: nextImageUrl,
          selectedDates: [],
          sourceMessageIds,
          existingPayload: existingPending?.payload || {},
          manual: true,
          auto: false,
        });

        let queueRow;
        if (existingPending) {
          reusedPendingCount += 1;
          const updatedPending = await client.query(
            `UPDATE product_publication_queue
             SET payload = $1::jsonb,
                 queued_by = $2,
                 created_at = now(),
                 approved_by = NULL,
                 approved_at = NULL
             WHERE id = $3
             RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
            [JSON.stringify(payload), actorUserId, existingPending.id],
          );
          queueRow = updatedPending.rows[0];
        } else {
          const insertedPending = await client.query(
            `INSERT INTO product_publication_queue (
               id,
               product_id,
               channel_id,
               queued_by,
               status,
               is_sent,
               payload,
               created_at
             )
             VALUES ($1, $2::uuid, $3::uuid, $4, 'pending', false, $5::jsonb, now())
             RETURNING id, product_id, channel_id, queued_by, status, is_sent, payload, created_at`,
            [
              uuidv4(),
              productId,
              mainChannel.id,
              actorUserId,
              JSON.stringify(payload),
            ],
          );
          queueRow = insertedPending.rows[0];
        }

        const hiddenMessages = await hideCatalogMessagesForRevision(
          client,
          mainChannel.id,
          sourceMessageIds,
          actorUserId,
        );
        for (const message of hiddenMessages) {
          hiddenMessagesById.set(String(message.id), message);
        }

        queuedItems.push({
          queue_id: queueRow.id,
          product_id: productId,
          source_message_ids: sourceMessageIds,
          product_code: target.product_code,
          product_shelf_number: nextShelfNumber,
          product_title: item.title,
          product_description: item.description,
          product_price: nextPrice,
          product_quantity: nextQuantity,
          product_image_url: nextImageUrl,
          payload,
          created_at: queueRow.created_at,
          mode: existingPending ? 'updated_pending' : 'created_pending',
        });
      }

      await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [mainChannel.id]);
      await client.query('COMMIT');

      const io = req.app.get('io');
      if (io) {
        for (const message of hiddenMessagesById.values()) {
          io.to(`chat:${mainChannel.id}`).emit('chat:message', {
            chatId: mainChannel.id,
            message: decryptMessageRow(message),
          });
        }
        if (queuedItems.length > 0 || hiddenMessagesById.size > 0) {
          emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
            chatId: mainChannel.id,
          });
        }
      }

      return res.json({
        ok: true,
        data: {
          updated_count: queuedItems.length,
          queued_count: queuedItems.length,
          reused_pending_count: reusedPendingCount,
          blocked_count: blockedCount,
          hidden_old_count: hiddenMessagesById.size,
          queued_items: queuedItems,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.manual error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

router.post(
  '/revision/auto',
  authMiddleware,
  requireRole('worker', 'admin', 'tenant', 'creator'),
  async (req, res) => {
    const dates = parseRevisionDates(req.body?.dates);
    const discountPercent = Math.abs(Number(req.body?.percent));
    const hideOldVersions = toBoolean(req.body?.hide_old_versions, true);

    if (!Number.isFinite(discountPercent) || discountPercent <= 0 || discountPercent > 95) {
      return res.status(400).json({
        ok: false,
        error: 'Процент снижения должен быть больше 0 и не больше 95',
      });
    }

    const client = await db.pool.connect();
    try {
      const actorUserId = await resolveActorUserId(client, req.user);
      await client.query('BEGIN');
      const { mainChannel } = await ensureSystemChannels(
        client,
        actorUserId,
        req.user.tenant_id || null
      );
      const selectedDates = dates.length > 0
        ? dates
        : (await fetchRevisionDays(client, mainChannel.id, 1)).map((x) => x.day);
      const posts = await fetchRevisionPosts(client, mainChannel.id, selectedDates);

      const groups = new Map();
      for (const post of posts) {
        if (post.revision_allowed != true) continue;
        const productId = String(post.product_id || '').trim();
        if (!productId) continue;
        if (!groups.has(productId)) groups.set(productId, []);
        groups.get(productId).push(post);
      }

      const keepPosts = [];
      for (const list of groups.values()) {
        list.sort((a, b) => Date.parse(String(b.created_at)) - Date.parse(String(a.created_at)));
        keepPosts.push(list[0]);
      }

      const queuedItems = [];
      let reusedPendingCount = 0;
      const hiddenMessagesById = new Map();

      for (const post of keepPosts) {
        const productId = String(post.product_id || '').trim();
        if (!productId) continue;
        const basePrice = Number(post.price || 0);
        if (!Number.isFinite(basePrice) || basePrice <= 0) continue;

        const revisedPrice = roundAutoRevisionPrice(basePrice, discountPercent, 50, 50);
        const nextQuantity = toPositiveInteger(post.quantity, 1);
        const nextShelfNumber = toShelfNumber(post.shelf_number, 1);
        const title = String(post.title || '').trim();
        if (!title) continue;
        const description = String(post.description || '').trim();
        const imageUrl = normalizeImageUrl(post.image_url);
        const existingPending = await fetchActivePendingQueueForProduct(
          client,
          productId,
          mainChannel.id,
        );
        const sourceMessageIds = uniqStrings([
          ...(await fetchVisibleCatalogMessageIdsForProduct(client, mainChannel.id, productId)),
          ...(existingPending ? extractSourceMessageIdsFromPayload(existingPending.payload) : []),
          String(post.message_id || '').trim(),
        ]);

        const payload = buildRevisionQueuePayload({
          post,
          title,
          description,
          price: revisedPrice,
          quantity: nextQuantity,
          shelfNumber: nextShelfNumber,
          imageUrl,
          selectedDates,
          sourceMessageIds,
          existingPayload: existingPending?.payload || {},
          manual: false,
          auto: true,
        });

        let queueId = null;
        if (existingPending) {
          reusedPendingCount += 1;
          queueId = existingPending.id;
          await client.query(
            `UPDATE product_publication_queue
             SET payload = $1::jsonb,
                 queued_by = $2,
                 created_at = now(),
                 approved_by = NULL,
                 approved_at = NULL
             WHERE id = $3`,
            [JSON.stringify(payload), actorUserId, queueId],
          );
        } else {
          const insertedQueue = await client.query(
            `INSERT INTO product_publication_queue (
               id,
               product_id,
               channel_id,
               queued_by,
               status,
               is_sent,
               payload,
               created_at
             )
             VALUES ($1, $2::uuid, $3::uuid, $4, 'pending', false, $5::jsonb, now())
             RETURNING id`,
            [
              uuidv4(),
              productId,
              mainChannel.id,
              actorUserId,
              JSON.stringify(payload),
            ]
          );
          queueId = insertedQueue.rows[0].id;
        }

        const hiddenMessages = await hideCatalogMessagesForRevision(
          client,
          mainChannel.id,
          sourceMessageIds,
          actorUserId,
        );
        for (const message of hiddenMessages) {
          hiddenMessagesById.set(String(message.id), message);
        }

        queuedItems.push({
          queue_id: queueId,
          product_id: productId,
          source_message_ids: sourceMessageIds,
          mode: existingPending ? 'updated_pending' : 'created_pending',
          revised_price: revisedPrice,
        });
      }
      await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [mainChannel.id]);
      await client.query('COMMIT');

      const io = req.app.get('io');
      if (io) {
        for (const message of hiddenMessagesById.values()) {
          io.to(`chat:${mainChannel.id}`).emit('chat:message', {
            chatId: mainChannel.id,
            message: decryptMessageRow(message),
          });
        }
        if (queuedItems.length > 0 || hiddenMessagesById.size > 0) {
          emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
            chatId: mainChannel.id,
          });
        }
      }

      return res.json({
        ok: true,
        data: {
          dates: selectedDates,
          percent: discountPercent,
          updated_count: queuedItems.length,
          hidden_old_count: hiddenMessagesById.size,
          queued_count: queuedItems.length,
          reused_pending_count: reusedPendingCount,
          queued_items: queuedItems,
        },
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('worker.revision.auto error', err);
      return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
    } finally {
      client.release();
    }
  }
);

module.exports = router;
