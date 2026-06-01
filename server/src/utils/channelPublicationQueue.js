const { v4: uuidv4 } = require('uuid');

const db = require('../db');
const { ensureSystemChannels, insertAdminSystemMessage } = require('./systemChannels');
const { encryptMessageText, decryptMessageRow } = require('./messageCrypto');
const { emitToTenant } = require('./socket');
const { emitCatalogQueueUpdated } = require('./catalogQueueSocket');
const { registerPublicImageUpload } = require('./publicMediaRegistration');
const { toOriginalPublicMediaUrl } = require('./mediaAssets');
const { upsertProductCardSnapshot } = require('./productCardSnapshots');
const { logMonitoringEvent } = require('./monitoring');
const { upsertMessageSearchDocument } = require('./chatSearchIndex');
const { normalizeCatalogTitle } = require('./catalogTitle');
const { createNotificationInboxItem } = require('./notifications');

const DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS = Math.max(
  1000,
  Number.parseInt(process.env.CHANNEL_PUBLICATION_INTERVAL_MS || '2000', 10) || 2000,
);
const CHANNEL_PUBLICATION_POLL_MS = Math.max(
  250,
  Number.parseInt(process.env.CHANNEL_PUBLICATION_POLL_MS || '500', 10) || 500,
);
const CHANNEL_PUBLICATION_RECOVERY_MS = Math.max(
  60_000,
  Number.parseInt(process.env.CHANNEL_PUBLICATION_RECOVERY_MS || '60000', 10) || 60_000,
);
const CHANNEL_PUBLICATION_TENANT_CACHE_MS = Math.max(
  5_000,
  Number.parseInt(process.env.CHANNEL_PUBLICATION_TENANT_CACHE_MS || '10000', 10) || 10_000,
);
const SAMARA_TZ = 'Europe/Samara';
const PROCESSOR_ID = process.env.FENIX_CHANNEL_PUBLICATION_PROCESSOR_ID || `api:${process.pid}`;
const PUBLICATION_DEBUG_LOGS = process.env.PHX_PUBLICATION_DEBUG_LOGS === '1';

let processorTimer = null;
let processorTickRunning = false;
let processorStarted = false;
let processorTenantTargetsCache = [];
let processorTenantTargetsCacheExpiresAt = 0;
let processorScopeCursor = 0;

function publicationDebug(label, details = {}) {
  if (!PUBLICATION_DEBUG_LOGS) return;
  try {
    console.log(`[PHX:PUBLISH] ${new Date().toISOString()} ${label}`, details);
  } catch (_) {
    console.log(`[PHX:PUBLISH] ${new Date().toISOString()} ${label}`);
  }
}

function normalizeQueueUuidList(raw) {
  if (!Array.isArray(raw)) return [];
  const seen = new Set();
  const values = [];
  for (const item of raw) {
    const value = String(item || '').trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
      continue;
    }
    if (seen.has(value)) continue;
    seen.add(value);
    values.push(value);
  }
  return values;
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

function buildPublicationChatMessagePayload(
  message,
  { action = 'message_published', queueId = null, tenantId = null } = {},
) {
  if (!message || typeof message !== 'object') return null;
  const chatId = String(message.chat_id || message.chatId || '').trim();
  const messageId = String(message.id || '').trim();
  if (!chatId || !messageId) return null;
  const updatedAt = message.updated_at || message.created_at || new Date().toISOString();
  return {
    type: 'chat:message',
    event_id: `chat-message:${messageId}:${action}`,
    tenant_id: tenantId || message.tenant_id || message.tenantId || null,
    entity: 'chat_message',
    entity_id: messageId,
    action,
    updated_at: updatedAt,
    chatId,
    chat_id: chatId,
    message_id: messageId,
    queue_id: queueId || null,
    message,
  };
}

function emitPublicationChatMessage(socketIo, tenantId, message, options = {}) {
  const payload = buildPublicationChatMessagePayload(message, {
    ...options,
    tenantId: tenantId || options.tenantId || null,
  });
  if (!socketIo || !payload) return;
  const chatRoom = `chat:${payload.chat_id}`;
  const tenantRoom = tenantId ? `tenant:${tenantId}` : null;
  const chatRoomSize = socketIo.sockets?.adapter?.rooms?.get(chatRoom)?.size || 0;
  const tenantRoomSize = tenantRoom
    ? socketIo.sockets?.adapter?.rooms?.get(tenantRoom)?.size || 0
    : 0;
  publicationDebug('emit chat:message', {
    action: payload.action,
    tenant_id: payload.tenant_id,
    tenant_room: tenantRoom,
    tenant_room_sockets: tenantRoomSize,
    chat_id: payload.chat_id,
    chat_room: chatRoom,
    chat_room_sockets: chatRoomSize,
    message_id: payload.message_id,
    queue_id: payload.queue_id,
    event_id: payload.event_id,
  });

  // Primary path: sockets that explicitly joined the currently opened chat.
  socketIo.to(chatRoom).emit('chat:message', payload);
  socketIo.to(chatRoom).emit('chat:message:global', payload);

  // Fallback path: channel publication can happen while the UI is already open.
  // Tenant-scoped delivery prevents "post exists after refresh, but not live" gaps.
  emitToTenant(socketIo, tenantId || null, 'chat:message', payload);
  emitToTenant(socketIo, tenantId || null, 'chat:message:global', payload);
}

function archivedProductMessageText({
  product,
  sourceChannelTitle,
  queuedByName,
  queuedByEmail,
  queuedByPhone,
}) {
  const creator = queuedByName || queuedByEmail || 'Неизвестно';
  const productLabel = formatProductLabel(
    product.product_code,
    product.shelf_number,
    product.manual_shelf_label,
  );
  const lines = [
    '🗂 Архив поста товара',
    `Название: ${product.title}`,
    product.description ? `Описание: ${String(product.description).trim()}` : null,
    `Цена: ${product.price} ₽`,
    `Количество: ${product.quantity}`,
    `ID товара: ${productLabel}`,
    `Канал публикации: ${sourceChannelTitle || 'Основной канал'}`,
    `Кто создал пост: ${creator}`,
    queuedByPhone ? `Телефон создателя: ${queuedByPhone}` : null,
  ].filter(Boolean);
  return lines.join('\n');
}

function formatProductLabel(productCode, shelfNumber, manualShelfLabel = '') {
  const code = Number(productCode);
  const shelf = Number(shelfNumber);
  const codePart = Number.isFinite(code) && code > 0 ? String(Math.floor(code)) : '—';
  const manualShelf = String(manualShelfLabel || '').trim();
  const shelfPart = manualShelf || (
    Number.isFinite(shelf) && shelf > 0
      ? String(Math.floor(shelf)).padStart(2, '0')
      : '—'
  );
  return `${codePart}--${shelfPart}`;
}

function isIsoDay(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || '').trim());
}

async function resolveAutoShelfNumber(client, tenantId = null, dateValue = null, fallback = 1) {
  const dayQ = await client.query(
    `SELECT to_char((COALESCE($1::timestamptz, now()) AT TIME ZONE $2)::date, 'YYYY-MM-DD') AS current_day`,
    [dateValue, SAMARA_TZ],
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
    [tenantId || null],
  );
  if (mainQ.rowCount > 0) {
    const main = mainQ.rows[0];
    const settings = main.settings && typeof main.settings === 'object' && !Array.isArray(main.settings)
      ? main.settings
      : {};
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

function isProductCodeConflictError(err) {
  return (
    String(err?.code || '') === '23505' &&
    String(err?.constraint || '').trim() === 'products_product_code_key'
  );
}

async function resolveUniqueProductCodeForPublish(client, requestedCode, productId, tenantId = null) {
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

function normalizePublicationError(error, fallbackCode = 'publish_item_failed') {
  const code = String(error?.code || fallbackCode).trim() || fallbackCode;
  const message = String(error?.message || 'Ошибка публикации элемента очереди')
    .trim()
    .slice(0, 1000);
  return {
    code,
    message: message || 'Ошибка публикации элемента очереди',
  };
}

function publicationValidationError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function buildPublicationSummary(activeBatches = []) {
  const batches = Array.isArray(activeBatches) ? activeBatches : [];
  const summary = {
    total_batches: batches.length,
    total_count: 0,
    published_count: 0,
    failed_count: 0,
    current_product_title: '',
    current_queue_item_id: '',
    interval_ms: DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS,
    next_publish_in_ms: 0,
  };
  let nextPublishInMs = null;
  for (const batch of batches) {
    summary.total_count += Number(batch.total_count || 0);
    summary.published_count += Number(batch.published_count || 0);
    summary.failed_count += Number(batch.failed_count || 0);
    if (!summary.current_product_title && String(batch.current_product_title || '').trim()) {
      summary.current_product_title = String(batch.current_product_title || '').trim();
      summary.current_queue_item_id = String(batch.current_queue_item_id || '').trim();
      summary.interval_ms = Number(batch.interval_ms || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS);
    }
    const candidateNext = Number(batch.next_publish_in_ms || 0);
    if (nextPublishInMs === null || candidateNext < nextPublishInMs) {
      nextPublishInMs = candidateNext;
    }
  }
  summary.next_publish_in_ms = Math.max(0, Number(nextPublishInMs || 0));
  return summary;
}

async function listActivePublicationBatches(queryable, tenantId = null) {
  const batchesQ = await queryable.query(
    `SELECT b.id,
            b.channel_id,
            c.title AS channel_title,
            b.tenant_id,
            b.created_by,
            b.status,
            b.interval_ms,
            b.total_count,
            b.published_count,
            b.failed_count,
            b.current_queue_item_id,
            b.current_product_id,
            b.current_product_title,
            b.next_publish_at,
            b.started_at,
            b.finished_at,
            b.created_at,
            b.updated_at,
            GREATEST(
              0,
              FLOOR(EXTRACT(EPOCH FROM (COALESCE(b.next_publish_at, now()) - now())) * 1000)
            )::bigint AS next_publish_in_ms
     FROM channel_publication_batches b
     JOIN chats c ON c.id = b.channel_id
     WHERE b.status IN ('queued', 'running')
       AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
     ORDER BY b.created_at ASC, b.id ASC`,
    [tenantId || null],
  );
  return batchesQ.rows.map((row) => ({
    ...row,
    next_publish_in_ms: Number(row.next_publish_in_ms || 0),
  }));
}

async function getChannelPublicationBatch(queryable, batchId, tenantId = null) {
  const batchQ = await queryable.query(
    `SELECT b.id,
            b.channel_id,
            c.title AS channel_title,
            b.tenant_id,
            b.created_by,
            b.status,
            b.interval_ms,
            b.total_count,
            b.published_count,
            b.failed_count,
            b.current_queue_item_id,
            b.current_product_id,
            b.current_product_title,
            b.next_publish_at,
            b.started_at,
            b.finished_at,
            b.created_at,
            b.updated_at,
            GREATEST(
              0,
              FLOOR(EXTRACT(EPOCH FROM (COALESCE(b.next_publish_at, now()) - now())) * 1000)
            )::bigint AS next_publish_in_ms
     FROM channel_publication_batches b
     JOIN chats c ON c.id = b.channel_id
     WHERE b.id = $1
       AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid)
     LIMIT 1`,
    [batchId, tenantId || null],
  );
  if (batchQ.rowCount === 0) return null;
  const batch = {
    ...batchQ.rows[0],
    next_publish_in_ms: Number(batchQ.rows[0].next_publish_in_ms || 0),
  };
  const failedQ = await queryable.query(
    `SELECT q.id,
            q.product_id,
            q.channel_id,
            q.publish_order,
            COALESCE(q.publish_status, 'pending') AS publish_status,
            q.publish_error_code,
            q.publish_error_message,
            COALESCE(NULLIF(BTRIM(q.payload->>'title'), ''), p.title) AS product_title,
            COALESCE(NULLIF(BTRIM(q.payload->>'description'), ''), p.description) AS product_description,
            COALESCE(NULLIF(q.payload->>'price', '')::numeric, p.price) AS product_price,
            COALESCE(NULLIF(q.payload->>'quantity', '')::int, p.quantity) AS product_quantity,
            p.product_code,
            p.shelf_number AS product_shelf_number
     FROM product_publication_queue q
     JOIN products p ON p.id = q.product_id
     WHERE q.publish_batch_id = $1
       AND COALESCE(q.publish_status, 'pending') = 'failed'
     ORDER BY q.publish_order ASC NULLS LAST, q.created_at ASC, q.id ASC`,
    [batchId],
  );
  return {
    ...batch,
    failed_items: failedQ.rows,
  };
}

async function enqueueChannelPublicationBatches({
  queryable,
  tenantId = null,
  createdBy = null,
  channelId = null,
  queueIds = [],
  intervalMs = DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS,
} = {}) {
  const normalizedQueueIds = normalizeQueueUuidList(queueIds);
  publicationDebug('enqueue requested', {
    tenant_id: tenantId || null,
    created_by: createdBy || null,
    channel_id: channelId || null,
    requested_queue_ids: Array.isArray(queueIds) ? queueIds.length : 0,
    normalized_queue_ids: normalizedQueueIds.length,
    interval_ms: intervalMs,
  });
  const params = [];
  let paramIndex = 1;
  const conditions = [
    `q.status = 'pending'`,
    `COALESCE(q.is_sent, false) = false`,
    `COALESCE(q.publish_status, 'pending') IN ('pending', 'failed')`,
    `($${paramIndex}::uuid IS NULL OR c.tenant_id = $${paramIndex}::uuid)`,
  ];
  params.push(tenantId || null);
  paramIndex += 1;
  if (channelId) {
    conditions.push(`q.channel_id = $${paramIndex}::uuid`);
    params.push(channelId);
    paramIndex += 1;
  }
  if (normalizedQueueIds.length > 0) {
    conditions.push(`q.id = ANY($${paramIndex}::uuid[])`);
    params.push(normalizedQueueIds);
    paramIndex += 1;
  }

  const eligibleQ = await queryable.query(
    `SELECT q.id,
            q.product_id,
            q.channel_id,
            c.title AS channel_title,
            c.tenant_id,
            COALESCE(NULLIF(BTRIM(q.payload->>'title'), ''), p.title) AS product_title,
            COALESCE(q.publish_status, 'pending') AS publish_status,
            q.created_at
     FROM product_publication_queue q
     JOIN chats c ON c.id = q.channel_id
     JOIN products p ON p.id = q.product_id
     WHERE ${conditions.join(' AND ')}
     ORDER BY q.created_at ASC, q.id ASC
     FOR UPDATE OF q`,
    params,
  );
  publicationDebug('enqueue eligible rows loaded', {
    tenant_id: tenantId || null,
    channel_id: channelId || null,
    eligible_count: eligibleQ.rowCount,
    queue_ids: eligibleQ.rows.map((row) => row.id),
    product_ids: eligibleQ.rows.map((row) => row.product_id),
  });

  const grouped = new Map();
  for (const row of eligibleQ.rows) {
    const key = String(row.channel_id || '').trim();
    if (!key) continue;
    if (!grouped.has(key)) {
      grouped.set(key, {
        channel_id: key,
        channel_title: row.channel_title,
        tenant_id: row.tenant_id || null,
        items: [],
      });
    }
    grouped.get(key).items.push(row);
  }

  const batches = [];
  const alreadyRunningChannels = [];
  let acceptedCount = 0;

  for (const group of grouped.values()) {
    const activeBatchQ = await queryable.query(
      `SELECT id, status, total_count, published_count, failed_count
       FROM channel_publication_batches
       WHERE channel_id = $1
         AND status IN ('queued', 'running')
       ORDER BY created_at DESC
       LIMIT 1
       FOR UPDATE`,
      [group.channel_id],
    );
    if (activeBatchQ.rowCount > 0) {
      publicationDebug('enqueue skipped: channel already has active batch', {
        channel_id: group.channel_id,
        channel_title: group.channel_title,
        active_batch_id: activeBatchQ.rows[0].id,
        active_status: activeBatchQ.rows[0].status,
        total_count: Number(activeBatchQ.rows[0].total_count || 0),
        published_count: Number(activeBatchQ.rows[0].published_count || 0),
        failed_count: Number(activeBatchQ.rows[0].failed_count || 0),
      });
      alreadyRunningChannels.push({
        batch_id: activeBatchQ.rows[0].id,
        channel_id: group.channel_id,
        channel_title: group.channel_title,
        status: activeBatchQ.rows[0].status,
        total_count: Number(activeBatchQ.rows[0].total_count || 0),
        published_count: Number(activeBatchQ.rows[0].published_count || 0),
        failed_count: Number(activeBatchQ.rows[0].failed_count || 0),
      });
      continue;
    }

    const batchId = uuidv4();
    const queueIdsForBatch = [];
    const publishOrders = [];
    let publishOrder = 1;
    let firstProductTitle = '';
    for (const item of group.items) {
      queueIdsForBatch.push(item.id);
      publishOrders.push(publishOrder);
      publishOrder += 1;
      if (!firstProductTitle && String(item.product_title || '').trim()) {
        firstProductTitle = String(item.product_title || '').trim();
      }
    }

    await queryable.query(
      `INSERT INTO channel_publication_batches (
         id,
         channel_id,
         tenant_id,
         created_by,
         status,
         interval_ms,
         total_count,
         published_count,
         failed_count,
         current_product_title,
         next_publish_at,
         created_at,
         updated_at
       )
       VALUES (
         $1, $2, $3, $4, 'queued', $5, $6, 0, 0, $7, now(), now(), now()
       )`,
      [
        batchId,
        group.channel_id,
        group.tenant_id || null,
        createdBy || null,
        Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
        group.items.length,
        firstProductTitle || null,
      ],
    );

    await queryable.query(
      `WITH ordered AS (
         SELECT *
         FROM UNNEST($1::uuid[], $2::int[]) AS t(id, publish_order)
       )
       UPDATE product_publication_queue q
       SET publish_batch_id = $3::uuid,
           publish_order = ordered.publish_order,
           publish_status = 'queued',
           publish_started_at = NULL,
           publish_finished_at = NULL,
           publish_error_code = NULL,
           publish_error_message = NULL
       FROM ordered
       WHERE q.id = ordered.id`,
      [queueIdsForBatch, publishOrders, batchId],
    );

    acceptedCount += group.items.length;
    publicationDebug('enqueue batch created', {
      batch_id: batchId,
      tenant_id: group.tenant_id || null,
      channel_id: group.channel_id,
      channel_title: group.channel_title,
      item_count: group.items.length,
      queue_ids: queueIdsForBatch,
      publish_orders: publishOrders,
      interval_ms: Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
      first_product_title: firstProductTitle || null,
    });
    batches.push({
      batch_id: batchId,
      channel_id: group.channel_id,
      channel_title: group.channel_title,
      tenant_id: group.tenant_id || null,
      interval_ms: Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
      total_count: group.items.length,
      published_count: 0,
      failed_count: 0,
      current_product_title: firstProductTitle,
      status: 'queued',
    });
  }

  publicationDebug('enqueue finished', {
    tenant_id: tenantId || null,
    accepted_count: acceptedCount,
    batch_count: batches.length,
    already_running_count: alreadyRunningChannels.length,
    interval_ms: Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
  });

  return {
    accepted_count: acceptedCount,
    interval_ms: Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
    batches,
    already_running_channels: alreadyRunningChannels,
  };
}

async function notifyChannelPublicationBatchStarted({
  tenantId = null,
  batch,
} = {}) {
  const normalizedTenantId =
    String(batch?.tenant_id || tenantId || '').trim() || null;
  const batchId = String(batch?.batch_id || '').trim();
  const channelId = String(batch?.channel_id || '').trim();
  if (!batchId || !channelId) return 0;

  const usersQ = await db.query(
    `SELECT id, email, name, role, tenant_id
       FROM users
      WHERE role = 'client'
        AND (
          ($1::uuid IS NULL AND tenant_id IS NULL)
          OR tenant_id = $1::uuid
        )`,
    [normalizedTenantId],
  );

  const totalCount = Math.max(0, Number(batch?.total_count || 0) || 0);
  const channelTitle =
    String(batch?.channel_title || '').trim() || 'Основной канал';
  let created = 0;
  for (const user of usersQ.rows) {
    await createNotificationInboxItem({
      user,
      category: 'chat',
      priority: 'normal',
      channel: 'mixed',
      title: channelTitle,
      body: totalCount > 0
        ? `Идёт выкладка товаров в ${channelTitle}: ${totalCount} шт.`
        : `Идёт выкладка товаров в ${channelTitle}.`,
      deepLink: `/chats?chatId=${encodeURIComponent(channelId)}`,
      payload: {
        category: 'chat',
        tenant_id: normalizedTenantId,
        channel_id: channelId,
        chat_id: channelId,
        batch_id: batchId,
        total_count: totalCount,
        source_type: 'channel_publish_batch',
        source_id: batchId,
      },
      dedupeKey: `channel_publish_batch:${normalizedTenantId || 'global'}:${batchId}`,
      collapseKey: `channel:${channelId}:publish`,
      ttlSeconds: 60 * 60 * 8,
      sourceType: 'channel_publish_batch',
      sourceId: batchId,
      inboxVisibility: 'delivery_only',
      forceShow: false,
      isActionable: true,
      emit: true,
      attemptPush: true,
    });
    created += 1;
  }
  return created;
}

async function notifyChannelPublicationBatchesStarted({
  tenantId = null,
  batches = [],
} = {}) {
  let created = 0;
  for (const batch of Array.isArray(batches) ? batches : []) {
    try {
      created += await notifyChannelPublicationBatchStarted({ tenantId, batch });
    } catch (err) {
      console.error('notifyChannelPublicationBatchStarted error', {
        batchId: batch?.batch_id || null,
        channelId: batch?.channel_id || null,
        message: err?.message || err,
      });
    }
  }
  return created;
}

async function recoverStalePublicationItems(client, batchId) {
  await client.query(
    `UPDATE product_publication_queue
     SET publish_status = 'queued',
         publish_started_at = NULL,
         publish_finished_at = NULL,
         publish_error_code = NULL,
         publish_error_message = NULL
     WHERE publish_batch_id = $1
       AND status = 'pending'
       AND COALESCE(is_sent, false) = false
       AND publish_status = 'publishing'
       AND publish_started_at IS NOT NULL
       AND publish_started_at <= now() - ($2::text)::interval`,
    [batchId, `${Math.floor(CHANNEL_PUBLICATION_RECOVERY_MS / 1000)} seconds`],
  );
}

async function finalizeBatch(client, batchId) {
  const countsQ = await client.query(
    `SELECT COUNT(*) FILTER (WHERE COALESCE(publish_status, 'pending') = 'queued')::int AS queued_count,
            COUNT(*) FILTER (WHERE COALESCE(publish_status, 'pending') = 'publishing')::int AS publishing_count,
            COUNT(*) FILTER (WHERE COALESCE(publish_status, 'pending') = 'failed')::int AS failed_count,
            COUNT(*) FILTER (WHERE COALESCE(publish_status, 'pending') = 'published')::int AS published_count,
            COUNT(*)::int AS total_count
     FROM product_publication_queue
     WHERE publish_batch_id = $1`,
    [batchId],
  );
  const counts = countsQ.rows[0] || {};
  const queuedCount = Number(counts.queued_count || 0);
  const publishingCount = Number(counts.publishing_count || 0);
  const failedCount = Number(counts.failed_count || 0);
  const publishedCount = Number(counts.published_count || 0);
  const totalCount = Number(counts.total_count || 0);
  if (queuedCount > 0 || publishingCount > 0) {
    return false;
  }
  await client.query(
    `UPDATE channel_publication_batches
     SET status = CASE WHEN $2::int > 0 THEN 'completed_with_errors' ELSE 'completed' END,
         published_count = $3,
         failed_count = $2,
         total_count = GREATEST(total_count, $4),
         current_queue_item_id = NULL,
         current_product_id = NULL,
         current_product_title = NULL,
         finished_at = now(),
         next_publish_at = now(),
         updated_at = now()
     WHERE id = $1`,
    [batchId, failedCount, publishedCount, totalCount],
  );
  return true;
}

async function loadProcessorTenantTargets({ force = false } = {}) {
  const now = Date.now();
  if (!force && processorTenantTargetsCacheExpiresAt > now) {
    return processorTenantTargetsCache;
  }

  const tenantsQ = await db.platformQuery(
    `SELECT id,
            code,
            name,
            status,
            subscription_expires_at,
            db_mode,
            db_url,
            db_name,
            db_schema
     FROM tenants
     WHERE COALESCE(is_deleted, false) = false
     ORDER BY created_at ASC, id ASC`,
  );

  processorTenantTargetsCache = tenantsQ.rows;
  processorTenantTargetsCacheExpiresAt = now + CHANNEL_PUBLICATION_TENANT_CACHE_MS;
  return processorTenantTargetsCache;
}

function buildProcessorScopes(tenantRows = []) {
  const scopes = Array.isArray(tenantRows) ? [...tenantRows] : [];
  scopes.push(null);
  return scopes;
}

function rotateProcessorScopes(scopes = []) {
  if (!Array.isArray(scopes) || scopes.length <= 1) return scopes;
  const startIndex = Math.abs(processorScopeCursor) % scopes.length;
  processorScopeCursor = (startIndex + 1) % scopes.length;
  return scopes.slice(startIndex).concat(scopes.slice(0, startIndex));
}

async function selectDueBatch(client, tenantId = null) {
  const batchQ = await client.query(
    `SELECT b.id,
            b.channel_id,
            b.tenant_id,
            b.created_by,
            b.status,
            b.interval_ms,
            b.total_count,
            b.published_count,
            b.failed_count,
            b.current_queue_item_id,
            b.current_product_id,
            b.current_product_title,
            b.next_publish_at,
            b.started_at,
            b.finished_at,
            b.created_at,
            c.title AS channel_title
     FROM channel_publication_batches b
     JOIN chats c ON c.id = b.channel_id
     WHERE b.status IN ('queued', 'running')
       AND (
         ($1::uuid IS NULL AND b.tenant_id IS NULL)
         OR b.tenant_id = $1::uuid
       )
       AND COALESCE(b.next_publish_at, now()) <= now()
     ORDER BY b.created_at ASC, b.id ASC
     FOR UPDATE OF b SKIP LOCKED
     LIMIT 1`,
    [tenantId || null],
  );
  return batchQ.rows[0] || null;
}

async function processBatchItem(client, batch) {
  await recoverStalePublicationItems(client, batch.id);
  publicationDebug('process batch item: looking for next queued item', {
    batch_id: batch.id,
    tenant_id: batch.tenant_id || null,
    channel_id: batch.channel_id || null,
    status: batch.status,
    interval_ms: batch.interval_ms,
    published_count: Number(batch.published_count || 0),
    failed_count: Number(batch.failed_count || 0),
    total_count: Number(batch.total_count || 0),
    next_publish_at: batch.next_publish_at || null,
  });

  const nextItemQ = await client.query(
    `SELECT q.id,
            q.product_id,
            q.channel_id,
            q.queued_by,
            q.status,
            q.is_sent,
            q.payload,
            q.publish_order,
            q.created_at,
            p.title,
            p.description,
            p.price,
            p.quantity,
            p.shelf_number,
            p.manual_shelf_label,
            p.shelf_floor,
            p.pickup_only,
            p.image_url,
            p.product_code,
            c.title AS channel_title,
            u.name AS queued_by_name,
            u.email AS queued_by_email,
            ph.phone AS queued_by_phone
     FROM product_publication_queue q
     JOIN products p ON p.id = q.product_id
     JOIN chats c ON c.id = q.channel_id
     LEFT JOIN users u ON u.id = q.queued_by
     LEFT JOIN LATERAL (
       SELECT phone
       FROM phones
       WHERE user_id = q.queued_by
       LIMIT 1
     ) ph ON TRUE
     WHERE q.publish_batch_id = $1
       AND q.status = 'pending'
       AND COALESCE(q.is_sent, false) = false
       AND COALESCE(q.publish_status, 'pending') = 'queued'
     ORDER BY q.publish_order ASC NULLS LAST, q.created_at ASC, q.id ASC
     FOR UPDATE OF q SKIP LOCKED
     LIMIT 1`,
    [batch.id],
  );

  if (nextItemQ.rowCount === 0) {
    const finalized = await finalizeBatch(client, batch.id);
    publicationDebug('process batch item: no queued item', {
      batch_id: batch.id,
      finalized,
    });
    return {
      processed: finalized,
      kind: finalized ? 'batch_finalized' : 'idle',
    };
  }

  const row = nextItemQ.rows[0];
  publicationDebug('process batch item: selected queue item', {
    batch_id: batch.id,
    tenant_id: batch.tenant_id || null,
    channel_id: row.channel_id,
    queue_item_id: row.id,
    product_id: row.product_id,
    product_code: row.product_code,
    publish_order: row.publish_order,
    title: row.title,
    shelf_number: row.shelf_number,
    manual_shelf_label: row.manual_shelf_label,
    pickup_only: row.pickup_only,
  });
  await client.query(
    `UPDATE channel_publication_batches
     SET status = 'running',
         worker_id = $2,
         started_at = COALESCE(started_at, now()),
         current_queue_item_id = $3,
         current_product_id = $4,
         current_product_title = $5,
         updated_at = now()
     WHERE id = $1`,
    [batch.id, PROCESSOR_ID, row.id, row.product_id, row.title || null],
  );
  await client.query(
    `UPDATE product_publication_queue
     SET publish_status = 'publishing',
         publish_started_at = now(),
         publish_finished_at = NULL,
         publish_error_code = NULL,
         publish_error_message = NULL
     WHERE id = $1`,
    [row.id],
  );

  await client.query('SAVEPOINT publish_batch_item');

  let emitted = {
    mainMessage: null,
    archiveMessages: [],
    hiddenRevisionMessages: [],
  };

  try {
    let code = await resolveUniqueProductCodeForPublish(
      client,
      row.product_code,
      row.product_id,
      batch.tenant_id || null,
    );

    const payload = row.payload && typeof row.payload === 'object' && !Array.isArray(row.payload)
      ? row.payload
      : {};

    const nextTitle = normalizeCatalogTitle(payload.title || row.title || '');
    const nextDescription = String(payload.description || row.description || '').trim();
    if (!nextTitle) {
      throw publicationValidationError('publish_validation_title_empty', 'Пустое название товара');
    }

    const rawNextPrice = Number(payload.price ?? row.price ?? 0);
    const fallbackPrice = Number(row.price ?? 0);
    const nextPrice = Number.isFinite(rawNextPrice) && rawNextPrice > 0
      ? rawNextPrice
      : (Number.isFinite(fallbackPrice) && fallbackPrice > 0 ? fallbackPrice : 0);
    if (!Number.isFinite(nextPrice) || nextPrice <= 0) {
      throw publicationValidationError('publish_validation_price_invalid', 'Цена товара должна быть больше нуля');
    }

    const rawNextQuantity = Number(payload.quantity ?? row.quantity ?? 1);
    const fallbackQuantity = Number(row.quantity ?? 1);
    const nextQuantity = Number.isFinite(rawNextQuantity) && rawNextQuantity > 0
      ? Math.floor(rawNextQuantity)
      : (Number.isFinite(fallbackQuantity) && fallbackQuantity > 0 ? Math.floor(fallbackQuantity) : 1);

    // Product shelf is assigned on creation/requeue and must not be moved by revision payloads.
    const rawProductShelf = Number(row.shelf_number ?? 0);
    const nextShelfNumber = Number.isFinite(rawProductShelf) && rawProductShelf > 0
      ? Math.floor(rawProductShelf)
      : await resolveAutoShelfNumber(client, batch.tenant_id || null, null, 1);
    const nextImageUrl = payload.image_url
      ? toOriginalPublicMediaUrl(payload.image_url)
      : row.image_url || null;
    const nextManualShelfLabel = String(
      payload.manual_shelf_label ?? row.manual_shelf_label ?? '',
    ).trim();
    const nextShelfFloor = String(payload.shelf_floor ?? row.shelf_floor ?? '').trim();
    const nextPickupOnly =
      payload.pickup_only === true ||
      String(payload.pickup_only || '').toLowerCase().trim() === 'true' ||
      row.pickup_only === true;

    let productUpdate = null;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      try {
        productUpdate = await client.query(
          `UPDATE products
           SET product_code = $1,
               title = $2,
               description = $3,
               price = $4,
               quantity = $5,
               shelf_number = $6,
               manual_shelf_label = NULLIF($7, ''),
               shelf_floor = NULLIF($8, ''),
               pickup_only = $9,
               image_url = $10,
               status = 'published',
               reusable_at = NULL,
               updated_at = now()
           WHERE id = $11
           RETURNING id, product_code, shelf_number, manual_shelf_label, shelf_floor, pickup_only,
                     title, description, price, quantity, image_url, status, updated_at`,
          [
            code,
            nextTitle,
            nextDescription,
            nextPrice,
            nextQuantity,
            nextShelfNumber,
            nextManualShelfLabel,
            nextShelfFloor,
            nextPickupOnly,
            nextImageUrl,
            row.product_id,
          ],
        );
        break;
      } catch (error) {
        if (!isProductCodeConflictError(error) || attempt >= 5) {
          throw error;
        }
        code = await allocateProductCode(client, batch.tenant_id || null);
      }
    }
    if (!productUpdate || productUpdate.rowCount === 0) {
      throw publicationValidationError('publish_product_not_found', 'Товар не найден');
    }

    const product = productUpdate.rows[0];
    if (product?.image_url) {
      await registerPublicImageUpload({
        queryable: client,
        ownerKind: 'product_image',
        ownerId: product.id,
        rawUrl: product.image_url,
      });
    }
    const productCardSnapshot = await upsertProductCardSnapshot(client, product, {
      tenantId: batch.tenant_id || null,
    });

    const messageMeta = {
      kind: 'catalog_product',
      product_id: product.id,
      product_code: product.product_code,
      product_label: formatProductLabel(
        product.product_code,
        product.shelf_number,
        product.manual_shelf_label,
      ),
      price: Number(product.price),
      quantity: Number(product.quantity),
      shelf_number: Number(product.shelf_number),
      manual_shelf_label: product.manual_shelf_label || null,
      shelf_floor: product.shelf_floor || null,
      pickup_only: product.pickup_only === true,
      image_url: product.image_url,
      card_snapshot: productCardSnapshot,
    };

    const messageInsert = await client.query(
      `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, NULL, $3, $4::jsonb, clock_timestamp())
       RETURNING id, chat_id, sender_id, text, meta, created_at`,
      [
        uuidv4(),
        row.channel_id,
        encryptMessageText(productMessageText(product)),
        JSON.stringify(messageMeta),
      ],
    );
    const message = messageInsert.rows[0];
    publicationDebug('process batch item: main channel message inserted', {
      batch_id: batch.id,
      tenant_id: batch.tenant_id || null,
      channel_id: row.channel_id,
      queue_item_id: row.id,
      product_id: product.id,
      message_id: message.id,
      message_created_at: message.created_at,
      product_code: product.product_code,
      product_label: messageMeta.product_label,
      title: product.title,
    });
    await upsertMessageSearchDocument({
      queryable: client,
      messageId: message.id,
      chatId: row.channel_id,
      tenantId: batch.tenant_id || null,
      senderId: null,
      text: productMessageText(product),
      meta: messageMeta,
      attachments: [],
      createdAt: message.created_at || null,
    });
    emitted.mainMessage = decryptMessageRow(message);

    const shouldHidePrevious =
      payload?.hide_old_versions === true ||
      String(payload?.hide_old_versions || '').toLowerCase().trim() === 'true';
    const sourceMessageId = String(payload?.source_message_id || '').trim();
    if (shouldHidePrevious && /^[-0-9a-f]{36}$/i.test(sourceMessageId) && sourceMessageId !== String(message.id)) {
      const hiddenQ = await client.query(
        `UPDATE messages
         SET meta = jsonb_set(
               COALESCE(meta, '{}'::jsonb),
               '{hidden_for_all}',
               'true'::jsonb,
               true
             )
         WHERE id = $1
           AND chat_id = $2
           AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
        [sourceMessageId, row.channel_id],
      );
      emitted.hiddenRevisionMessages = hiddenQ.rows.map((item) => decryptMessageRow(item));
    }

    const ensuredSystem = await ensureSystemChannels(
      client,
      batch.created_by || null,
      batch.tenant_id || null,
    );
    const postsArchiveChannelId = String(ensuredSystem?.postsArchiveChannel?.id || '').trim();
    if (postsArchiveChannelId) {
      const archiveMeta = {
        kind: 'catalog_product_archive',
        product_id: product.id,
        product_code: product.product_code,
        product_label: formatProductLabel(
          product.product_code,
          product.shelf_number,
          product.manual_shelf_label,
        ),
        price: Number(product.price),
        quantity: Number(product.quantity),
        shelf_number: Number(product.shelf_number),
        manual_shelf_label: product.manual_shelf_label || null,
        shelf_floor: product.shelf_floor || null,
        pickup_only: product.pickup_only === true,
        image_url: product.image_url,
        source_channel_id: row.channel_id,
        source_channel_title: row.channel_title,
        source_message_id: message.id,
        queued_by: row.queued_by,
        queued_by_name: row.queued_by_name || null,
        queued_by_email: row.queued_by_email || null,
        queued_by_phone: row.queued_by_phone || null,
      };
      const archiveInsert = await client.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, NULL, $3, $4::jsonb, clock_timestamp())
         RETURNING id, chat_id, sender_id, text, meta, created_at`,
        [
          uuidv4(),
          postsArchiveChannelId,
          encryptMessageText(
            archivedProductMessageText({
              product,
              sourceChannelTitle: row.channel_title,
              queuedByName: row.queued_by_name,
              queuedByEmail: row.queued_by_email,
              queuedByPhone: row.queued_by_phone,
            }),
          ),
          JSON.stringify(archiveMeta),
        ],
      );
      await upsertMessageSearchDocument({
        queryable: client,
        messageId: archiveInsert.rows[0]?.id,
        chatId: postsArchiveChannelId,
        tenantId: batch.tenant_id || null,
        senderId: null,
        text: archivedProductMessageText({
          product,
          sourceChannelTitle: row.channel_title,
          queuedByName: row.queued_by_name,
          queuedByEmail: row.queued_by_email,
          queuedByPhone: row.queued_by_phone,
        }),
        meta: archiveMeta,
        attachments: [],
        createdAt: archiveInsert.rows[0]?.created_at || null,
      });
      await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [postsArchiveChannelId]);
      emitted.archiveMessages = archiveInsert.rows.map((item) => decryptMessageRow(item));
    }

    await client.query(
      `UPDATE product_publication_queue
       SET status = 'published',
           is_sent = true,
           approved_by = $1,
           approved_at = now(),
           published_message_id = $2,
           publish_status = 'published',
           publish_finished_at = now(),
           publish_error_code = NULL,
           publish_error_message = NULL
       WHERE id = $3`,
      [batch.created_by || null, message.id, row.id],
    );
    await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [row.channel_id]);

    const remainingQ = await client.query(
      `SELECT COUNT(*)::int AS remaining_count
       FROM product_publication_queue
       WHERE publish_batch_id = $1
         AND status = 'pending'
         AND COALESCE(is_sent, false) = false
         AND COALESCE(publish_status, 'pending') = 'queued'`,
      [batch.id],
    );
    const remainingCount = Number(remainingQ.rows[0]?.remaining_count || 0);
    if (remainingCount > 0) {
      await client.query(
        `UPDATE channel_publication_batches
         SET published_count = published_count + 1,
             current_queue_item_id = $2,
             current_product_id = $3,
             current_product_title = $4,
             next_publish_at = now() + ($5::text)::interval,
             updated_at = now()
         WHERE id = $1`,
        [batch.id, row.id, row.product_id, product.title || row.title || null, `${Math.floor(batch.interval_ms / 1000)} seconds`],
      );
    } else {
      await client.query(
        `UPDATE channel_publication_batches
         SET published_count = published_count + 1,
             current_queue_item_id = NULL,
             current_product_id = NULL,
             current_product_title = NULL,
             status = CASE WHEN failed_count > 0 THEN 'completed_with_errors' ELSE 'completed' END,
             finished_at = now(),
             next_publish_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [batch.id],
      );
    }

    await client.query('RELEASE SAVEPOINT publish_batch_item');
    publicationDebug('process batch item: published successfully', {
      batch_id: batch.id,
      tenant_id: batch.tenant_id || null,
      channel_id: row.channel_id,
      queue_item_id: row.id,
      product_id: product.id,
      message_id: message.id,
      remaining_count: remainingCount,
      next_publish_delay_ms: remainingCount > 0 ? batch.interval_ms : 0,
    });

    return {
      processed: true,
      kind: 'published',
      tenantId: batch.tenant_id || null,
      channelId: row.channel_id,
      archiveChannelId: emitted.archiveMessages[0]?.chat_id || null,
      queueItemId: row.id,
      emitted,
    };
  } catch (error) {
    try {
      await client.query('ROLLBACK TO SAVEPOINT publish_batch_item');
      await client.query('RELEASE SAVEPOINT publish_batch_item');
    } catch (rollbackError) {
      throw rollbackError;
    }
    const normalized = normalizePublicationError(error);
    publicationDebug('process batch item: failed', {
      batch_id: batch.id,
      tenant_id: batch.tenant_id || null,
      channel_id: row.channel_id,
      queue_item_id: row.id,
      product_id: row.product_id,
      error_code: normalized.code,
      error_message: normalized.message,
      stack: String(error?.stack || '').split('\n').slice(0, 6).join('\n'),
    });
    const remainingQ = await client.query(
      `SELECT COUNT(*)::int AS remaining_count
       FROM product_publication_queue
       WHERE publish_batch_id = $1
         AND status = 'pending'
         AND COALESCE(is_sent, false) = false
         AND COALESCE(publish_status, 'pending') = 'queued'`,
      [batch.id],
    );
    const remainingCount = Number(remainingQ.rows[0]?.remaining_count || 0);
    await client.query(
      `UPDATE product_publication_queue
       SET publish_status = 'failed',
           publish_finished_at = now(),
           publish_error_code = $2,
           publish_error_message = $3
       WHERE id = $1`,
      [row.id, normalized.code, normalized.message],
    );
    if (remainingCount > 0) {
      await client.query(
        `UPDATE channel_publication_batches
         SET failed_count = failed_count + 1,
             current_queue_item_id = $2,
             current_product_id = $3,
             current_product_title = $4,
             next_publish_at = now() + ($5::text)::interval,
             updated_at = now()
         WHERE id = $1`,
        [batch.id, row.id, row.product_id, row.title || null, `${Math.floor(batch.interval_ms / 1000)} seconds`],
      );
    } else {
      await client.query(
        `UPDATE channel_publication_batches
         SET failed_count = failed_count + 1,
             current_queue_item_id = NULL,
             current_product_id = NULL,
             current_product_title = NULL,
             status = 'completed_with_errors',
             finished_at = now(),
             next_publish_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [batch.id],
      );
    }
    return {
      processed: true,
      kind: 'failed',
      tenantId: batch.tenant_id || null,
      channelId: row.channel_id,
      batchId: batch.id,
      error: normalized,
      queueItemId: row.id,
      productId: row.product_id,
      productTitle: row.title || null,
    };
  }
}

function emitProcessedPublicationResult(result, io = null) {
  const socketIo = io || global.__projectPhoenixSocketIo || null;
  if (!socketIo || !result?.processed) return;
  if (result.kind === 'published') {
    for (const message of result.emitted.hiddenRevisionMessages || []) {
      emitPublicationChatMessage(socketIo, result.tenantId || null, message, {
        action: 'message_hidden',
        queueId: result.queueItemId || null,
      });
      emitToTenant(socketIo, result.tenantId || null, 'chat:updated', {
        chatId: message.chat_id,
      });
      emitToTenant(socketIo, result.tenantId || null, 'channel:media:updated', {
        entity: 'channel_media',
        entity_id: String(message.chat_id),
        channel_id: message.chat_id,
        chatId: message.chat_id,
        action: 'message_hidden',
      });
    }
    if (result.emitted.mainMessage) {
      emitPublicationChatMessage(socketIo, result.tenantId || null, result.emitted.mainMessage, {
        action: 'message_published',
        queueId: result.queueItemId || null,
      });
      emitToTenant(socketIo, result.tenantId || null, 'chat:updated', {
        chatId: result.emitted.mainMessage.chat_id,
      });
      emitToTenant(socketIo, result.tenantId || null, 'channel:media:updated', {
        entity: 'channel_media',
        entity_id: String(result.emitted.mainMessage.chat_id),
        channel_id: result.emitted.mainMessage.chat_id,
        chatId: result.emitted.mainMessage.chat_id,
        action: 'message_published',
        message_id: result.emitted.mainMessage.id,
        queue_id: result.queueItemId || null,
        message: result.emitted.mainMessage,
      });
    }
    for (const archiveMessage of result.emitted.archiveMessages || []) {
      emitPublicationChatMessage(socketIo, result.tenantId || null, archiveMessage, {
        action: 'message_published',
        queueId: result.queueItemId || null,
      });
      emitToTenant(socketIo, result.tenantId || null, 'chat:updated', {
        chatId: archiveMessage.chat_id,
      });
      emitToTenant(socketIo, result.tenantId || null, 'channel:media:updated', {
        entity: 'channel_media',
        entity_id: String(archiveMessage.chat_id),
        channel_id: archiveMessage.chat_id,
        chatId: archiveMessage.chat_id,
        action: 'message_published',
        message_id: archiveMessage.id,
        queue_id: result.queueItemId || null,
      });
    }
  }
  emitCatalogQueueUpdated(socketIo, result.tenantId || null, {
    action: result.kind || 'updated',
    channel_id: result.channelId || null,
    archive_channel_id: result.archiveChannelId || null,
    queue_id: result.queueItemId || null,
  });
  if (result.kind === 'failed') {
    void insertAdminSystemMessage(db, {
      tenantId: result.tenantId || null,
      text: [
        'Ошибка публикации товара.',
        `Товар: ${String(result.productTitle || 'Без названия').trim()}`,
        `Причина: ${String(result.error?.message || result.error?.code || 'Неизвестная ошибка').trim()}`,
        'Действие: открыть админку модерации.',
      ].join('\n'),
      meta: {
        kind: 'channel_publication_error',
        action: 'open_admin_moderation',
        tenant_id: result.tenantId || null,
        batch_id: result.batchId || null,
        queue_item_id: result.queueItemId || null,
        product_id: result.productId || null,
        channel_id: result.channelId || null,
        error_code: result.error?.code || null,
        error_message: result.error?.message || null,
      },
      dedupeKey: `channel-publication-error:${result.batchId || 'batch'}:${result.queueItemId || 'item'}`,
    }).catch((err) => {
      console.error('channelPublicationQueue.systemMessage error', err?.message || err);
    });
  }
}

async function processNextChannelPublicationStepForScope(scope, { io = null } = {}) {
  return db.runWithTenantRow(scope, async () => {
    const client = await db.connect();
    const scopeTenantId = String(scope?.id || '').trim() || null;
    try {
      await client.query('BEGIN');
      const batch = await selectDueBatch(client, scopeTenantId);
      if (!batch) {
        await client.query('ROLLBACK');
        return null;
      }
      publicationDebug('processor selected due batch', {
        tenant_id: scopeTenantId,
        tenant_code: String(scope?.code || '').trim() || null,
        batch_id: batch.id,
        channel_id: batch.channel_id,
        status: batch.status,
        next_publish_at: batch.next_publish_at || null,
        published_count: Number(batch.published_count || 0),
        failed_count: Number(batch.failed_count || 0),
        total_count: Number(batch.total_count || 0),
      });
      const result = await processBatchItem(client, batch);
      await client.query('COMMIT');
      publicationDebug('processor committed batch step', {
        tenant_id: scopeTenantId,
        batch_id: batch.id,
        kind: result?.kind || null,
        processed: result?.processed === true,
        channel_id: result?.channelId || batch.channel_id || null,
        queue_item_id: result?.queueItemId || null,
        message_id: result?.emitted?.mainMessage?.id || null,
      });
      emitProcessedPublicationResult(result, io);
      return result;
    } catch (error) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {}
      console.error('channel publication processor error', error);
      try {
        await logMonitoringEvent({
          queryable: db,
          scope: 'process',
          subsystem: 'catalog_publish',
          level: 'error',
          code: 'channel_publication_processor_error',
          source: 'server/src/utils/channelPublicationQueue.js',
          message: String(error?.message || error || 'channel publication processor error'),
          details: {
            worker_id: PROCESSOR_ID,
            tenant_id: scopeTenantId,
            tenant_code: String(scope?.code || '').trim() || null,
            stack: String(error?.stack || '').trim() || null,
          },
        });
      } catch (_) {}
      return null;
    } finally {
      client.release();
    }
  });
}

async function processNextChannelPublicationStep({ io = null } = {}) {
  const tenantRows = await loadProcessorTenantTargets();
  const scopes = rotateProcessorScopes(buildProcessorScopes(tenantRows));
  for (const scope of scopes) {
    const result = await processNextChannelPublicationStepForScope(scope, { io });
    if (result?.processed) {
      return result;
    }
  }
  return null;
}

async function runProcessorTick(io = null) {
  if (processorTickRunning) return;
  processorTickRunning = true;
  try {
    for (let index = 0; index < 6; index += 1) {
      const result = await processNextChannelPublicationStep({ io });
      if (!result?.processed) break;
    }
  } finally {
    processorTickRunning = false;
  }
}

function startChannelPublicationProcessor({ io = null } = {}) {
  if (processorStarted) return;
  processorStarted = true;
  publicationDebug('processor started', {
    worker_id: PROCESSOR_ID,
    poll_ms: CHANNEL_PUBLICATION_POLL_MS,
    recovery_ms: CHANNEL_PUBLICATION_RECOVERY_MS,
  });
  processorTimer = setInterval(() => {
    void runProcessorTick(io);
  }, CHANNEL_PUBLICATION_POLL_MS);
  if (typeof processorTimer?.unref === 'function') {
    processorTimer.unref();
  }
  setImmediate(() => {
    void runProcessorTick(io);
  });
}

function kickChannelPublicationProcessor(io = null) {
  publicationDebug('processor kick requested', {
    worker_id: PROCESSOR_ID,
  });
  setImmediate(() => {
    void runProcessorTick(io);
  });
}

module.exports = {
  DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS,
  enqueueChannelPublicationBatches,
  notifyChannelPublicationBatchesStarted,
  listActivePublicationBatches,
  buildPublicationSummary,
  getChannelPublicationBatch,
  startChannelPublicationProcessor,
  kickChannelPublicationProcessor,
  processNextChannelPublicationStep,
};
