const db = require('../db');
const { logMonitoringEvent } = require('./monitoring');

const DEFAULT_LIMIT = {
  windowSeconds: 60,
  maxEvents: 30,
  blockMinutes: 10,
};

const ACTION_LIMITS = {
  'admin.publish_pending': { windowSeconds: 60, maxEvents: 8, blockMinutes: 15 },
  'admin.delivery.broadcast': { windowSeconds: 300, maxEvents: 5, blockMinutes: 20 },
  'support.staff_reply': { windowSeconds: 60, maxEvents: 30, blockMinutes: 10 },
  'cart.buy': { windowSeconds: 60, maxEvents: 20, blockMinutes: 10 },
  'chats.post_message': { windowSeconds: 30, maxEvents: 40, blockMinutes: 10 },
};

function resolveLimit(actionKey) {
  return ACTION_LIMITS[actionKey] || DEFAULT_LIMIT;
}

async function getActiveBlock(queryable, userId, actionKey) {
  const q = await queryable.query(
    `SELECT id, action_key, reason, blocked_until
     FROM antifraud_blocks
     WHERE user_id = $1
       AND is_active = true
       AND blocked_until > now()
       AND (action_key = $2 OR action_key IS NULL)
     ORDER BY blocked_until DESC
     LIMIT 1`,
    [userId, actionKey || null],
  );
  return q.rowCount > 0 ? q.rows[0] : null;
}

async function countRecentEvents(queryable, userId, actionKey, windowSeconds) {
  const q = await queryable.query(
    `SELECT COUNT(*)::int AS total
     FROM antifraud_events
     WHERE user_id = $1
       AND action_key = $2
       AND created_at >= now() - make_interval(secs => $3::int)`,
    [userId, actionKey, windowSeconds],
  );
  return Number(q.rows[0]?.total || 0);
}

async function writeEvent({
  queryable,
  tenantId,
  userId,
  actionKey,
  severity,
  status,
  counterWindowSeconds,
  counterValue,
  reason,
  details,
}) {
  await queryable.query(
    `INSERT INTO antifraud_events (
       tenant_id,
       user_id,
       action_key,
       severity,
       status,
       counter_window_seconds,
       counter_value,
       reason,
       details,
       created_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, NULLIF($8, ''), $9::jsonb, now())`,
    [
      tenantId || null,
      userId || null,
      actionKey,
      severity,
      status,
      counterWindowSeconds,
      counterValue,
      reason || '',
      JSON.stringify(details && typeof details === 'object' ? details : {}),
    ],
  );
}

async function createOrExtendBlock({
  queryable,
  tenantId,
  userId,
  actionKey,
  reason,
  blockMinutes,
}) {
  const existing = await queryable.query(
    `SELECT id
     FROM antifraud_blocks
     WHERE user_id = $1
       AND is_active = true
       AND action_key = $2
     ORDER BY updated_at DESC
     LIMIT 1`,
    [userId, actionKey || null],
  );

  if (existing.rowCount > 0) {
    await queryable.query(
      `UPDATE antifraud_blocks
       SET blocked_until = now() + make_interval(mins => $1::int),
           reason = $2,
           updated_at = now()
       WHERE id = $3`,
      [blockMinutes, reason, existing.rows[0].id],
    );
    return existing.rows[0].id;
  }

  const inserted = await queryable.query(
    `INSERT INTO antifraud_blocks (
       tenant_id,
       user_id,
       action_key,
       reason,
       blocked_until,
       is_active,
       created_at,
       updated_at
     )
     VALUES ($1, $2, $3, $4, now() + make_interval(mins => $5::int), true, now(), now())
     RETURNING id`,
    [tenantId || null, userId, actionKey || null, reason, blockMinutes],
  );
  return inserted.rows[0]?.id || null;
}

async function guardAction({
  queryable = db,
  tenantId = null,
  userId,
  actionKey,
  details = {},
}) {
  if (!userId || !actionKey) {
    return { allowed: true };
  }

  const limits = resolveLimit(actionKey);

  const activeBlock = await getActiveBlock(queryable, userId, actionKey);
  if (activeBlock) {
    await writeEvent({
      queryable,
      tenantId,
      userId,
      actionKey,
      severity: 'critical',
      status: 'blocked',
      counterWindowSeconds: limits.windowSeconds,
      counterValue: null,
      reason: activeBlock.reason || 'active_block',
      details: {
        ...(details && typeof details === 'object' ? details : {}),
        blocked_until: activeBlock.blocked_until,
      },
    });
    return {
      allowed: false,
      blockedUntil: activeBlock.blocked_until,
      reason: activeBlock.reason || 'Действие временно заблокировано',
    };
  }

  const recentCount = await countRecentEvents(
    queryable,
    userId,
    actionKey,
    limits.windowSeconds,
  );
  const nextCount = recentCount + 1;
  const exceeded = nextCount > limits.maxEvents;

  if (!exceeded) {
    await writeEvent({
      queryable,
      tenantId,
      userId,
      actionKey,
      severity: nextCount >= Math.ceil(limits.maxEvents * 0.8) ? 'warn' : 'info',
      status: 'logged',
      counterWindowSeconds: limits.windowSeconds,
      counterValue: nextCount,
      reason: '',
      details,
    });
    return { allowed: true, counter: nextCount };
  }

  const reason = `Лимит превышен: ${actionKey} (${nextCount}/${limits.maxEvents} за ${limits.windowSeconds}с)`;
  const blockId = await createOrExtendBlock({
    queryable,
    tenantId,
    userId,
    actionKey,
    reason,
    blockMinutes: limits.blockMinutes,
  });

  await writeEvent({
    queryable,
    tenantId,
    userId,
    actionKey,
    severity: 'critical',
    status: 'blocked',
    counterWindowSeconds: limits.windowSeconds,
    counterValue: nextCount,
    reason,
    details: {
      ...(details && typeof details === 'object' ? details : {}),
      block_id: blockId,
      block_minutes: limits.blockMinutes,
    },
  });

  await logMonitoringEvent({
    queryable,
    tenantId,
    userId,
    scope: 'security',
    level: 'critical',
    code: 'antifraud_limit_exceeded',
    source: actionKey,
    message: reason,
    details: {
      action_key: actionKey,
      counter: nextCount,
      max_events: limits.maxEvents,
      window_seconds: limits.windowSeconds,
      block_minutes: limits.blockMinutes,
    },
  });

  return {
    allowed: false,
    blockedUntil: new Date(Date.now() + limits.blockMinutes * 60 * 1000).toISOString(),
    reason,
  };
}

function antifraudGuard(actionKey, detailsBuilder = null) {
  return async (req, res, next) => {
    try {
      const userId = req.user?.id;
      if (!userId) return next();
      const details =
        typeof detailsBuilder === 'function'
          ? detailsBuilder(req)
          : {
              method: req.method,
              path: req.path,
              ip: req.ip,
            };
      const result = await guardAction({
        queryable: db,
        tenantId: req.user?.tenant_id || null,
        userId,
        actionKey,
        details,
      });
      if (!result.allowed) {
        return res.status(429).json({
          ok: false,
          error: result.reason || 'Подозрительная активность. Попробуйте позже.',
          blocked_until: result.blockedUntil || null,
        });
      }
      return next();
    } catch (err) {
      console.error('antifraud.guard middleware error', err);
      return next();
    }
  };
}

module.exports = {
  guardAction,
  antifraudGuard,
};
