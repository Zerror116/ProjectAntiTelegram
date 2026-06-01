const db = require('../db');
const { emitToTenant } = require('./socket');

const DEFAULT_SWEEP_MS = 5 * 60 * 1000;
const MIN_SWEEP_MS = 30 * 1000;
const BATCH_LIMIT = Math.max(
  10,
  Number(process.env.AUTO_PRODUCT_PROCESSING_BATCH_LIMIT || 250),
);

let timer = null;
let running = false;

function sweepIntervalMs() {
  const configured = Number(process.env.AUTO_PRODUCT_PROCESSING_SWEEP_MS || DEFAULT_SWEEP_MS);
  if (!Number.isFinite(configured)) return DEFAULT_SWEEP_MS;
  return Math.max(MIN_SWEEP_MS, Math.round(configured));
}

function parseDelayMinutes(raw) {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return 60;
  return Math.min(24 * 60, Math.max(1, Math.round(parsed)));
}

async function loadAutoProcessingTenants() {
  const q = await db.platformQuery(
    `SELECT t.id::text AS tenant_id,
            t.code,
            t.name,
            t.status,
            t.db_mode,
            t.db_url,
            t.db_name,
            t.db_schema,
            COALESCE(
              NULLIF(s.settings->'product_processing'->>'auto_delay_minutes', ''),
              NULLIF(s.settings->>'auto_product_processing_delay_minutes', ''),
              '60'
            ) AS delay_minutes
     FROM tenant_feature_settings s
     JOIN tenants t ON t.id = s.tenant_id
     WHERE COALESCE(s.settings->'product_processing'->>'mode', s.settings->>'product_processing_mode', '') = 'auto_after_delay'
       AND COALESCE(t.status, 'active') <> 'deleted'`,
  );
  return q.rows.map((row) => ({
    ...row,
    delay_minutes: parseDelayMinutes(row.delay_minutes),
  }));
}

async function markMessagesAutoProcessed(queryable, cartItemIds) {
  if (!Array.isArray(cartItemIds) || cartItemIds.length === 0) return [];
  const q = await queryable.query(
    `UPDATE messages m
     SET meta = COALESCE(m.meta, '{}'::jsonb) || jsonb_build_object(
           'placed', true,
           'processing_mode', 'standard',
           'is_oversize', false,
           'auto_processed', true,
           'processed_by_id', 'system',
           'processed_by_name', 'Система'
         )
     WHERE COALESCE(m.meta->>'kind', '') = 'reserved_order_item'
       AND COALESCE(m.meta->>'cart_item_id', '') = ANY($1::text[])
     RETURNING m.id::text AS id, m.chat_id::text AS chat_id, m.meta`,
    [cartItemIds.map(String)],
  );
  return q.rows;
}

async function processTenantAutoItems(io, tenantRow, delayMinutes) {
  const tenantId = String(tenantRow?.id || tenantRow?.tenant_id || '').trim();
  if (!tenantId) return 0;
  const tenantContextRow = await db.resolveTenantById(tenantId).catch(() => null);
  if (!tenantContextRow) return 0;

  return db.runWithTenantRow(tenantContextRow, async () => {
    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const updatedQ = await client.query(
        `WITH eligible AS (
           SELECT ci.id, ci.user_id, ci.product_id
           FROM cart_items ci
           JOIN users u ON u.id = ci.user_id
           WHERE ci.status = 'pending_processing'
             AND u.tenant_id = $1::uuid
             AND ci.created_at <= now() - ($2::int * interval '1 minute')
           ORDER BY ci.created_at ASC
           LIMIT $3
           FOR UPDATE SKIP LOCKED
         )
         UPDATE cart_items ci
         SET status = 'processed',
             processing_mode = 'standard',
             updated_at = now()
         FROM eligible e
         WHERE ci.id = e.id
         RETURNING ci.id::text AS id,
                   ci.user_id::text AS user_id,
                   ci.product_id::text AS product_id`,
        [tenantId, delayMinutes, BATCH_LIMIT],
      );
      const rows = updatedQ.rows;
      if (rows.length === 0) {
        await client.query('COMMIT');
        return 0;
      }

      const cartItemIds = rows.map((row) => String(row.id));
      await client.query(
        `UPDATE reservations
         SET is_fulfilled = true,
             is_sent = true,
             fulfilled_at = COALESCE(fulfilled_at, now()),
             updated_at = now()
         WHERE cart_item_id = ANY($1::uuid[])`,
        [cartItemIds],
      );
      const updatedMessages = await markMessagesAutoProcessed(client, cartItemIds);
      await client.query('COMMIT');

      if (io) {
        const byUser = new Map();
        for (const row of rows) {
          const userId = String(row.user_id || '').trim();
          if (!userId) continue;
          if (!byUser.has(userId)) byUser.set(userId, []);
          byUser.get(userId).push(row);
        }
        for (const [userId, userItems] of byUser.entries()) {
          io.to(`user:${userId}`).emit('cart:updated', {
            userId,
            status: 'processed',
            reason: 'auto_product_processed',
            processed_count: userItems.length,
          });
        }
        for (const message of updatedMessages) {
          const chatId = String(message.chat_id || '').trim();
          if (!chatId) continue;
          io.to(`chat:${chatId}`).emit('reserved:order:updated', {
            chatId,
            message_id: message.id,
            action: 'auto_processed',
            tenant_id: tenantId,
          });
        }
        emitToTenant(io, tenantId, 'delivery:updated', {
          reason: 'auto_product_processed',
          updatedAt: new Date().toISOString(),
        });
      }
      return rows.length;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  });
}

async function runAutoProductProcessingSweep({ io, reason = 'timer' } = {}) {
  if (running) return { skipped: true, reason: 'already_running' };
  running = true;
  try {
    const tenants = await loadAutoProcessingTenants();
    let processed = 0;
    for (const tenant of tenants) {
      processed += await processTenantAutoItems(io, tenant, tenant.delay_minutes);
    }
    if (processed > 0) {
      console.log('[auto-product-processing] processed', { reason, processed });
    }
    return { skipped: false, processed };
  } finally {
    running = false;
  }
}

function startAutoProductProcessing({ io } = {}) {
  if (timer) return timer;
  const intervalMs = sweepIntervalMs();
  timer = setInterval(() => {
    void runAutoProductProcessingSweep({ io, reason: 'timer' }).catch((err) => {
      console.error('auto product processing sweep error:', err);
    });
  }, intervalMs);
  if (typeof timer.unref === 'function') timer.unref();
  void runAutoProductProcessingSweep({ io, reason: 'startup' }).catch((err) => {
    console.error('auto product processing startup sweep error:', err);
  });
  return timer;
}

module.exports = {
  runAutoProductProcessingSweep,
  startAutoProductProcessing,
};
