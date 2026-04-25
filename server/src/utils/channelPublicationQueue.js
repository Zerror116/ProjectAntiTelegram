const { v4: uuidv4 } = require('uuid');

const db = require('../db');
const { ensureSystemChannels } = require('./systemChannels');
const { encryptMessageText, decryptMessageRow } = require('./messageCrypto');
const { emitToTenant } = require('./socket');
const { registerPublicImageUpload } = require('./publicMediaRegistration');
const { toOriginalPublicMediaUrl } = require('./mediaAssets');
const { upsertProductCardSnapshot } = require('./productCardSnapshots');
const { logMonitoringEvent } = require('./monitoring');

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
  Number.parseInt(process.env.CHANNEL_PUBLICATION_RECOVERY_MS || `${5 * 60 * 1000}`, 10) || 5 * 60 * 1000,
);
const SAMARA_TZ = 'Europe/Samara';
const PROCESSOR_ID = process.env.FENIX_CHANNEL_PUBLICATION_PROCESSOR_ID || `api:${process.pid}`;

let processorTimer = null;
let processorTickRunning = false;
let processorStarted = false;

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

function archivedProductMessageText({
  product,
  sourceChannelTitle,
  queuedByName,
  queuedByEmail,
  queuedByPhone,
}) {
  const creator = queuedByName || queuedByEmail || 'Неизвестно';
  const productLabel = formatProductLabel(product.product_code, product.shelf_number);
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

function formatProductLabel(productCode, shelfNumber) {
  const code = Number(productCode);
  const shelf = Number(shelfNumber);
  const codePart = Number.isFinite(code) && code > 0 ? String(Math.floor(code)) : '—';
  const shelfPart = Number.isFinite(shelf) && shelf > 0
    ? String(Math.floor(shelf)).padStart(2, '0')
    : '—';
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
    `SELECT GREATEST(0, ($1::date - $2::date))::int AS diff_days`,
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
            COALESCE(NULLIF(q.payload->>'shelf_number', '')::int, p.shelf_number) AS product_shelf_number
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
    batches.push({
      batch_id: batchId,
      channel_id: group.channel_id,
      channel_title: group.channel_title,
      interval_ms: Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
      total_count: group.items.length,
      published_count: 0,
      failed_count: 0,
      current_product_title: firstProductTitle,
      status: 'queued',
    });
  }

  return {
    accepted_count: acceptedCount,
    interval_ms: Math.max(1000, Number(intervalMs || DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS)),
    batches,
    already_running_channels: alreadyRunningChannels,
  };
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

async function selectDueBatch(client) {
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
       AND COALESCE(b.next_publish_at, now()) <= now()
     ORDER BY b.created_at ASC, b.id ASC
     FOR UPDATE OF b SKIP LOCKED
     LIMIT 1`,
  );
  return batchQ.rows[0] || null;
}

async function processBatchItem(client, batch) {
  await recoverStalePublicationItems(client, batch.id);

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
    return {
      processed: finalized,
      kind: finalized ? 'batch_finalized' : 'idle',
    };
  }

  const row = nextItemQ.rows[0];
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

    const nextTitle = String(payload.title || row.title || '').trim();
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

    const rawNextShelf = Number(payload.shelf_number ?? row.shelf_number ?? 0);
    const nextShelfNumber = Number.isFinite(rawNextShelf) && rawNextShelf > 0
      ? Math.floor(rawNextShelf)
      : await resolveAutoShelfNumber(client, batch.tenant_id || null, null, 1);
    const nextImageUrl = payload.image_url
      ? toOriginalPublicMediaUrl(payload.image_url)
      : row.image_url || null;

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
               image_url = $7,
               status = 'published',
               reusable_at = NULL,
               updated_at = now()
           WHERE id = $8
           RETURNING id, product_code, shelf_number, title, description, price, quantity, image_url, status, updated_at`,
          [
            code,
            nextTitle,
            nextDescription,
            nextPrice,
            nextQuantity,
            nextShelfNumber,
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
      product_label: formatProductLabel(product.product_code, product.shelf_number),
      price: Number(product.price),
      quantity: Number(product.quantity),
      shelf_number: Number(product.shelf_number),
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
        product_label: formatProductLabel(product.product_code, product.shelf_number),
        price: Number(product.price),
        quantity: Number(product.quantity),
        shelf_number: Number(product.shelf_number),
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

    return {
      processed: true,
      kind: 'published',
      tenantId: batch.tenant_id || null,
      channelId: row.channel_id,
      archiveChannelId: emitted.archiveMessages[0]?.chat_id || null,
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
      error: normalized,
      queueItemId: row.id,
    };
  }
}

async function processNextChannelPublicationStep({ io = null } = {}) {
  const client = await db.platformConnect();
  try {
    await client.query('BEGIN');
    const batch = await selectDueBatch(client);
    if (!batch) {
      await client.query('ROLLBACK');
      return null;
    }
    const result = await processBatchItem(client, batch);
    await client.query('COMMIT');

    const socketIo = io || global.__projectPhoenixSocketIo || null;
    if (socketIo && result?.kind === 'published') {
      for (const message of result.emitted.hiddenRevisionMessages || []) {
        socketIo.to(`chat:${message.chat_id}`).emit('chat:message', {
          chatId: message.chat_id,
          message,
        });
        emitToTenant(socketIo, result.tenantId || null, 'chat:updated', {
          chatId: message.chat_id,
        });
      }
      if (result.emitted.mainMessage) {
        socketIo.to(`chat:${result.emitted.mainMessage.chat_id}`).emit('chat:message', {
          chatId: result.emitted.mainMessage.chat_id,
          message: result.emitted.mainMessage,
        });
        emitToTenant(socketIo, result.tenantId || null, 'chat:updated', {
          chatId: result.emitted.mainMessage.chat_id,
        });
      }
      for (const archiveMessage of result.emitted.archiveMessages || []) {
        socketIo.to(`chat:${archiveMessage.chat_id}`).emit('chat:message', {
          chatId: archiveMessage.chat_id,
          message: archiveMessage,
        });
        emitToTenant(socketIo, result.tenantId || null, 'chat:updated', {
          chatId: archiveMessage.chat_id,
        });
      }
    }
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
          stack: String(error?.stack || '').trim() || null,
        },
      });
    } catch (_) {}
    return null;
  } finally {
    client.release();
  }
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
  setImmediate(() => {
    void runProcessorTick(io);
  });
}

module.exports = {
  DEFAULT_CHANNEL_PUBLICATION_INTERVAL_MS,
  enqueueChannelPublicationBatches,
  listActivePublicationBatches,
  buildPublicationSummary,
  getChannelPublicationBatch,
  startChannelPublicationProcessor,
  kickChannelPublicationProcessor,
  processNextChannelPublicationStep,
};
