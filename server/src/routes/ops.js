const express = require('express');
const os = require('os');
const { v4: uuidv4 } = require('uuid');
const ExcelJS = require('exceljs');
const PDFDocument = require('pdfkit');

const db = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');
const requirePermission = require('../middleware/requirePermission');
const { logAudit } = require('../utils/audit');
const { guardAction } = require('../utils/antifraud');
const { logMonitoringEvent } = require('../utils/monitoring');
const { emitToTenant } = require('../utils/socket');
const { ensureSystemChannels } = require('../utils/systemChannels');
const {
  renderSupportTemplateBody,
  normalizeTriggerRule,
  normalizePriority: normalizeSupportTemplatePriority,
} = require('../utils/supportAutoReply');
const {
  encryptMessageText,
  decryptMessageText,
  decryptMessageRow,
} = require('../utils/messageCrypto');

const router = express.Router();
const requireSupportWritePermission = requirePermission('chat.write.support');
const requireDeliveryManagePermission = requirePermission('delivery.manage');
const requireTenantUsersManagePermission = requirePermission('tenant.users.manage');

const MONEY_STATUSES = [
  'processed',
  'preparing_delivery',
  'in_delivery',
  'delivered',
];
const CART_RETENTION_WARNING_DAYS = 30;
const ROLE_PERMISSION_MODULES = [
  { key: 'chat.read', title: 'Чтение чатов' },
  { key: 'chat.write.public', title: 'Писать в публичные каналы' },
  { key: 'chat.write.support', title: 'Писать в поддержку' },
  { key: 'chat.pin', title: 'Закреплять сообщения' },
  { key: 'chat.delete.all', title: 'Удалять сообщения у всех' },
  { key: 'product.create', title: 'Создавать товары' },
  { key: 'product.requeue', title: 'Переотправлять старые товары в очередь' },
  { key: 'product.edit.own_pending', title: 'Редактировать свои посты до публикации' },
  { key: 'product.publish', title: 'Публиковать посты на канал' },
  { key: 'reservation.fulfill', title: 'Обрабатывать забронированные товары' },
  { key: 'delivery.manage', title: 'Управлять доставкой' },
  { key: 'tenant.users.manage', title: 'Управлять ролями и правами пользователей' },
];

function normalizeRole(value) {
  return String(value || '').toLowerCase().trim();
}

function normalizeTemplateCode(value, fallback = 'custom-role') {
  const safeFallback = String(fallback || 'custom-role')
    .toLowerCase()
    .replace(/[^a-z0-9_.-]+/g, '-')
    .replace(/[-_.]{2,}/g, '-')
    .replace(/^[-_.]+|[-_.]+$/g, '');

  let normalized = String(value || '')
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9_.-]+/g, '-')
    .replace(/[-_.]{2,}/g, '-')
    .replace(/^[-_.]+|[-_.]+$/g, '');

  if (!normalized) normalized = safeFallback || 'custom-role';
  if (normalized.length > 40) normalized = normalized.slice(0, 40);
  if (normalized.length < 2) normalized = `${normalized}x`;
  return normalized;
}

function isCreatorBase(user) {
  const baseRole = normalizeRole(user?.base_role || user?.role);
  return baseRole === 'creator';
}

function normalizePermissionsPayload(raw) {
  const source =
    raw && typeof raw === 'object' && !Array.isArray(raw)
      ? raw
      : {};
  const normalized = {};

  if (source.all === true) {
    normalized.all = true;
    return normalized;
  }

  for (const module of ROLE_PERMISSION_MODULES) {
    if (source[module.key] === true) {
      normalized[module.key] = true;
    }
  }
  return normalized;
}

function toMoney(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Number(parsed.toFixed(2));
}

function parsePositiveInt(raw, fallback, min, max) {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.trunc(parsed);
  return Math.max(min, Math.min(max, normalized));
}

function phoneTail(raw) {
  const digits = String(raw || '').replace(/\D/g, '');
  if (digits.length < 4) return '';
  return digits.slice(-4);
}

function shelfLabel(raw) {
  const shelf = Number(raw);
  if (!Number.isFinite(shelf) || shelf <= 0) return 'не назначена';
  return String(Math.trunc(shelf));
}

function tenantFilterSql(alias = 'u', tenantParamIndex = 1) {
  return `($${tenantParamIndex}::uuid IS NULL OR ${alias}.tenant_id = $${tenantParamIndex}::uuid)`;
}

function periodStartExpression(period) {
  switch (period) {
    case 'day':
      return "date_trunc('day', now())";
    case 'week':
      return "date_trunc('week', now())";
    case 'month':
      return "date_trunc('month', now())";
    default:
      return null;
  }
}

function csvEscape(value) {
  const raw = String(value ?? '');
  if (raw.includes(',') || raw.includes('"') || raw.includes('\n')) {
    return `"${raw.replace(/"/g, '""')}"`;
  }
  return raw;
}

function normalizeClock(value) {
  const normalized = String(value || '').trim();
  if (!normalized) return '';
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(normalized)) return '';
  return normalized;
}

function normalizePriority(value) {
  const normalized = String(value || '').toLowerCase().trim();
  if (['low', 'normal', 'high', 'critical'].includes(normalized)) {
    return normalized;
  }
  return 'normal';
}

function normalizeType(value) {
  const normalized = String(value || '').toLowerCase().trim();
  if (['order', 'support', 'delivery'].includes(normalized)) {
    return normalized;
  }
  return 'support';
}

function withinQuietHours({ enabled, from, to, now = new Date() }) {
  if (!enabled || !from || !to) return false;
  const [fromH, fromM] = from.split(':').map((x) => Number(x));
  const [toH, toM] = to.split(':').map((x) => Number(x));
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

async function saveSmartNotificationEvent({
  id = uuidv4(),
  tenantId = null,
  profileUserId = null,
  eventType = 'support',
  priority = 'normal',
  title = '',
  message = '',
  payload = {},
  isQuiet = false,
}) {
  const insert = await db.query(
    `INSERT INTO smart_notification_events (
       id,
       tenant_id,
       profile_user_id,
       event_type,
       priority,
       title,
       message,
       payload,
       is_quiet,
       created_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, now())
     RETURNING id,
               tenant_id,
               profile_user_id,
               event_type,
               priority,
               title,
               message,
               payload,
               is_quiet,
               created_at`,
    [
      id,
      tenantId || null,
      profileUserId || null,
      normalizeType(eventType),
      normalizePriority(priority),
      String(title || '').trim(),
      String(message || '').trim(),
      JSON.stringify(payload && typeof payload === 'object' ? payload : {}),
      Boolean(isQuiet),
    ],
  );
  return insert.rows[0] || null;
}

async function getFinanceSummary({
  tenantId,
  period,
}) {
  const periodExpr = periodStartExpression(period);
  const params = [tenantId || null];
  let rangeSql = '';
  if (periodExpr) {
    rangeSql = `AND COALESCE(c.updated_at, c.created_at) >= ${periodExpr}`;
  }

  const summaryQ = await db.query(
    `WITH base AS (
       SELECT c.user_id,
              c.quantity::numeric AS qty,
              p.price::numeric AS price,
              COALESCE(p.cost_price, 0)::numeric AS cost_price,
              COALESCE(c.updated_at, c.created_at) AS ts
       FROM cart_items c
       JOIN products p ON p.id = c.product_id
       JOIN users u ON u.id = c.user_id
       WHERE c.status = ANY($2::text[])
         AND (${tenantFilterSql('u', 1)})
         ${rangeSql}
     )
     SELECT COALESCE(SUM(qty * price), 0)::numeric(14,2) AS revenue,
            COALESCE(SUM(qty * cost_price), 0)::numeric(14,2) AS cost,
            COUNT(*)::int AS lines,
            COUNT(DISTINCT user_id)::int AS buyers
     FROM base`,
    [params[0], MONEY_STATUSES],
  );

  const row = summaryQ.rows[0] || {};
  const revenue = toMoney(row.revenue);
  const cost = toMoney(row.cost);
  const margin = toMoney(revenue - cost);
  const profit = margin;
  const avgCheck = row.buyers > 0 ? toMoney(revenue / Number(row.buyers)) : 0;

  const byDayQ = await db.query(
    `SELECT to_char(date_trunc('day', COALESCE(c.updated_at, c.created_at)), 'YYYY-MM-DD') AS bucket,
            COALESCE(SUM(c.quantity * p.price), 0)::numeric(14,2) AS revenue,
            COALESCE(SUM(c.quantity * COALESCE(p.cost_price, 0)), 0)::numeric(14,2) AS cost
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     JOIN users u ON u.id = c.user_id
     WHERE c.status = ANY($2::text[])
       AND (${tenantFilterSql('u', 1)})
       AND COALESCE(c.updated_at, c.created_at) >= now() - interval '30 days'
     GROUP BY 1
     ORDER BY 1 ASC`,
    [tenantId || null, MONEY_STATUSES],
  );

  const byWeekQ = await db.query(
    `SELECT to_char(date_trunc('week', COALESCE(c.updated_at, c.created_at)), 'IYYY-IW') AS bucket,
            COALESCE(SUM(c.quantity * p.price), 0)::numeric(14,2) AS revenue,
            COALESCE(SUM(c.quantity * COALESCE(p.cost_price, 0)), 0)::numeric(14,2) AS cost
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     JOIN users u ON u.id = c.user_id
     WHERE c.status = ANY($2::text[])
       AND (${tenantFilterSql('u', 1)})
       AND COALESCE(c.updated_at, c.created_at) >= now() - interval '24 weeks'
     GROUP BY 1
     ORDER BY 1 ASC`,
    [tenantId || null, MONEY_STATUSES],
  );

  const byMonthQ = await db.query(
    `SELECT to_char(date_trunc('month', COALESCE(c.updated_at, c.created_at)), 'YYYY-MM') AS bucket,
            COALESCE(SUM(c.quantity * p.price), 0)::numeric(14,2) AS revenue,
            COALESCE(SUM(c.quantity * COALESCE(p.cost_price, 0)), 0)::numeric(14,2) AS cost
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     JOIN users u ON u.id = c.user_id
     WHERE c.status = ANY($2::text[])
       AND (${tenantFilterSql('u', 1)})
       AND COALESCE(c.updated_at, c.created_at) >= now() - interval '18 months'
     GROUP BY 1
     ORDER BY 1 ASC`,
    [tenantId || null, MONEY_STATUSES],
  );

  const mapSeries = (rows) =>
    rows.map((item) => {
      const revenueVal = toMoney(item.revenue);
      const costVal = toMoney(item.cost);
      const profitVal = toMoney(revenueVal - costVal);
      return {
        bucket: item.bucket,
        revenue: revenueVal,
        cost: costVal,
        margin: profitVal,
        profit: profitVal,
      };
    });

  return {
    summary: {
      revenue,
      cost,
      margin,
      profit,
      avg_check: avgCheck,
      buyers: Number(row.buyers || 0),
      lines: Number(row.lines || 0),
      margin_percent: revenue > 0 ? toMoney((margin / revenue) * 100) : 0,
    },
    by_day: mapSeries(byDayQ.rows),
    by_week: mapSeries(byWeekQ.rows),
    by_month: mapSeries(byMonthQ.rows),
  };
}

function normalizeTemplateCategory(value) {
  const normalized = String(value || '').toLowerCase().trim();
  if (['general', 'product', 'delivery', 'cart'].includes(normalized)) {
    return normalized;
  }
  return 'general';
}

function mapClaimWorkflowStatus(status, customerDiscountStatus = '') {
  const decision = String(customerDiscountStatus || '').trim();
  switch (String(status || '').trim()) {
    case 'pending':
      return 'Новая заявка';
    case 'approved_return':
      return 'Подтвержден возврат';
    case 'approved_discount':
      if (decision === 'pending') return 'Скидка предложена клиенту';
      if (decision === 'accepted') return 'Скидка подтверждена клиентом';
      if (decision === 'rejected') return 'Клиент отказался от скидки';
      return 'Подтверждена скидка';
    case 'rejected':
      return 'Отклонено';
    case 'settled':
      return 'Закрыто';
    default:
      return 'Неизвестно';
  }
}

function allowedClaimActions(status, customerDiscountStatus = '') {
  const current = String(status || '').trim();
  const decision = String(customerDiscountStatus || '').trim();
  if (current === 'pending') {
    return ['approve_return', 'approve_discount', 'reject'];
  }
  if (current === 'approved_return') {
    return ['settle'];
  }
  if (current === 'approved_discount') {
    if (decision === 'pending') return [];
    return ['settle'];
  }
  return [];
}

function mapSupportTicketStatusLabel(status) {
  switch (String(status || '').trim()) {
    case 'open':
      return 'Открыт';
    case 'waiting_customer':
      return 'Ждем клиента';
    case 'resolved':
      return 'Решен';
    case 'archived':
      return 'В архиве';
    default:
      return 'Неизвестно';
  }
}

function mapClaimTypeLabel(claimType) {
  return String(claimType || '').trim() === 'discount' ? 'Скидка' : 'Возврат';
}

function mapOpsEventPriority({
  type,
  status,
  customerDiscountStatus = '',
}) {
  const normalizedType = String(type || '').trim();
  const normalizedStatus = String(status || '').trim();
  const discountDecision = String(customerDiscountStatus || '').trim();

  if (normalizedType === 'cart_retention') {
    return 'high';
  }

  if (normalizedType === 'support_ticket') {
    if (normalizedStatus === 'open') return 'high';
    if (normalizedStatus === 'waiting_customer') return 'normal';
    if (normalizedStatus === 'resolved') return 'low';
    return 'low';
  }

  if (normalizedType === 'claim') {
    if (normalizedStatus === 'pending') return 'high';
    if (
      normalizedStatus === 'approved_discount' &&
      discountDecision === 'pending'
    ) {
      return 'high';
    }
    if (normalizedStatus === 'approved_return') return 'normal';
    if (normalizedStatus === 'approved_discount') return 'normal';
    if (normalizedStatus === 'rejected') return 'normal';
    if (normalizedStatus === 'settled') return 'low';
  }

  return 'normal';
}

async function resolveCartSumsForUser(userId) {
  const sumsQ = await db.query(
    `SELECT COALESCE(SUM(c.quantity * p.price), 0)::numeric(14,2) AS total,
            COALESCE(SUM(c.quantity * p.price) FILTER (
              WHERE c.status IN ('processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')
            ), 0)::numeric(14,2) AS processed
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     WHERE c.user_id = $1
       AND c.status IN ('pending_processing', 'processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')`,
    [userId],
  );
  const claimsQ = await db.query(
    `SELECT COALESCE(SUM(approved_amount), 0)::numeric(14,2) AS claims_total
     FROM customer_claims
     WHERE user_id = $1
       AND status IN ('approved_return', 'approved_discount', 'settled')`,
    [userId],
  );
  const claimsTotal = toMoney(claimsQ.rows[0]?.claims_total);
  const total = Math.max(0, toMoney(sumsQ.rows[0]?.total) - claimsTotal);
  const processed = Math.max(
    0,
    toMoney(sumsQ.rows[0]?.processed) - claimsTotal,
  );
  return {
    total,
    processed,
    claims_total: claimsTotal,
  };
}

async function hydrateSupportMessage(messageId) {
  const q = await db.query(
    `SELECT m.id,
            m.chat_id,
            m.sender_id,
            m.text,
            m.meta,
            m.created_at,
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
    [messageId],
  );
  return decryptMessageRow(q.rows[0] || null);
}

async function insertAuditFromReq(req, payload) {
  await logAudit({
    tenantId: req.user?.tenant_id || null,
    actorUserId: req.user?.id || null,
    actorRole: req.user?.role || null,
    ...payload,
  });
}

router.get('/finance/summary', requireAuth, requireRole('admin', 'tenant', 'creator'), async (req, res) => {
  try {
    const periodRaw = String(req.query?.period || 'month').toLowerCase().trim();
    const period = ['day', 'week', 'month', 'all'].includes(periodRaw)
      ? periodRaw
      : 'month';
    const data = await getFinanceSummary({
      tenantId: req.user?.tenant_id || null,
      period,
    });
    await insertAuditFromReq(req, {
      action: 'finance.summary.view',
      entityType: 'finance',
      meta: { period },
    });
    return res.json({ ok: true, data });
  } catch (err) {
    console.error('ops.finance.summary error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/audit/logs', requireAuth, requireRole('tenant', 'creator'), async (req, res) => {
  try {
    const action = String(req.query?.action || '').trim();
    const actorId = String(req.query?.actor_user_id || '').trim();
    const entityType = String(req.query?.entity_type || '').trim();
    const dateFrom = String(req.query?.date_from || '').trim();
    const dateTo = String(req.query?.date_to || '').trim();
    const limit = parsePositiveInt(req.query?.limit, 200, 1, 1000);

    const params = [req.user?.tenant_id || null];
    const where = ['($1::uuid IS NULL OR al.tenant_id = $1::uuid OR al.tenant_id IS NULL)'];

    if (action) {
      params.push(action);
      where.push(`al.action = $${params.length}`);
    }
    if (actorId) {
      params.push(actorId);
      where.push(`al.actor_user_id = $${params.length}::uuid`);
    }
    if (entityType) {
      params.push(entityType);
      where.push(`al.entity_type = $${params.length}`);
    }
    if (dateFrom) {
      params.push(dateFrom);
      where.push(`al.created_at >= $${params.length}::timestamptz`);
    }
    if (dateTo) {
      params.push(dateTo);
      where.push(`al.created_at <= $${params.length}::timestamptz`);
    }
    params.push(limit);

    const query = await db.query(
      `SELECT al.id,
              al.tenant_id,
              al.actor_user_id,
              al.actor_role,
              al.action,
              al.entity_type,
              al.entity_id,
              al.before_data,
              al.after_data,
              al.meta,
              al.created_at,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS actor_name,
              u.email AS actor_email
       FROM audit_logs al
       LEFT JOIN users u ON u.id = al.actor_user_id
       WHERE ${where.join(' AND ')}
       ORDER BY al.created_at DESC
       LIMIT $${params.length}`,
      params,
    );

    return res.json({ ok: true, data: query.rows });
  } catch (err) {
    console.error('ops.audit.logs error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/audit/logs/export', requireAuth, requireRole('tenant', 'creator'), async (req, res) => {
  try {
    const action = String(req.query?.action || '').trim();
    const params = [req.user?.tenant_id || null];
    const where = ['($1::uuid IS NULL OR al.tenant_id = $1::uuid OR al.tenant_id IS NULL)'];

    if (action) {
      params.push(action);
      where.push(`al.action = $${params.length}`);
    }

    const rows = await db.query(
      `SELECT al.created_at,
              al.action,
              al.entity_type,
              al.entity_id,
              al.actor_role,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Система') AS actor_name,
              al.meta
       FROM audit_logs al
       LEFT JOIN users u ON u.id = al.actor_user_id
       WHERE ${where.join(' AND ')}
       ORDER BY al.created_at DESC
       LIMIT 10000`,
      params,
    );

    const header = [
      'created_at',
      'action',
      'entity_type',
      'entity_id',
      'actor_role',
      'actor_name',
      'meta_json',
    ];

    const csv = [header.join(',')]
      .concat(
        rows.rows.map((row) =>
          [
            row.created_at ? new Date(row.created_at).toISOString() : '',
            row.action,
            row.entity_type,
            row.entity_id,
            row.actor_role,
            row.actor_name,
            JSON.stringify(row.meta || {}),
          ]
            .map(csvEscape)
            .join(','),
        ),
      )
      .join('\n');

    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="audit_log.csv"');
    return res.send(csv);
  } catch (err) {
    console.error('ops.audit.export error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/antifraud/events', requireAuth, requireRole('admin', 'creator'), async (req, res) => {
  try {
    const actionKey = String(req.query?.action_key || '').trim();
    const severity = String(req.query?.severity || '').trim();
    const status = String(req.query?.status || '').trim();
    const limit = parsePositiveInt(req.query?.limit, 200, 1, 1000);

    const params = [req.user?.tenant_id || null];
    const where = ['($1::uuid IS NULL OR e.tenant_id = $1::uuid OR e.tenant_id IS NULL)'];

    if (actionKey) {
      params.push(actionKey);
      where.push(`e.action_key = $${params.length}`);
    }
    if (severity) {
      params.push(severity);
      where.push(`e.severity = $${params.length}`);
    }
    if (status) {
      params.push(status);
      where.push(`e.status = $${params.length}`);
    }

    params.push(limit);

    const rows = await db.query(
      `SELECT e.id,
              e.tenant_id,
              e.user_id,
              e.action_key,
              e.severity,
              e.status,
              e.counter_window_seconds,
              e.counter_value,
              e.reason,
              e.details,
              e.created_at,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Неизвестный') AS user_name
       FROM antifraud_events e
       LEFT JOIN users u ON u.id = e.user_id
       WHERE ${where.join(' AND ')}
       ORDER BY e.created_at DESC
       LIMIT $${params.length}`,
      params,
    );

    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error('ops.antifraud.events error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/antifraud/blocks', requireAuth, requireRole('admin', 'creator'), async (req, res) => {
  try {
    const activeOnly = String(req.query?.active_only || '1') !== '0';
    const rows = await db.query(
      `SELECT b.id,
              b.user_id,
              b.action_key,
              b.reason,
              b.blocked_until,
              b.is_active,
              b.created_at,
              b.updated_at,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Неизвестный') AS user_name
       FROM antifraud_blocks b
       LEFT JOIN users u ON u.id = b.user_id
       WHERE ($1::uuid IS NULL OR b.tenant_id = $1::uuid OR b.tenant_id IS NULL)
         AND ($2::boolean = false OR b.is_active = true)
       ORDER BY b.updated_at DESC, b.created_at DESC
       LIMIT 2000`,
      [req.user?.tenant_id || null, activeOnly],
    );
    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error('ops.antifraud.blocks error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.patch('/antifraud/blocks/:id/release', requireAuth, requireRole('admin', 'creator'), async (req, res) => {
  try {
    const blockId = String(req.params?.id || '').trim();
    if (!blockId) {
      return res.status(400).json({ ok: false, error: 'id блокировки обязателен' });
    }
    const updated = await db.query(
      `UPDATE antifraud_blocks
       SET is_active = false,
           blocked_until = now(),
           updated_at = now()
       WHERE id = $1
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid OR tenant_id IS NULL)
       RETURNING id`,
      [blockId, req.user?.tenant_id || null],
    );
    if (updated.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Блокировка не найдена' });
    }
    await insertAuditFromReq(req, {
      action: 'antifraud.block.release',
      entityType: 'antifraud_block',
      entityId: blockId,
    });
    return res.json({ ok: true });
  } catch (err) {
    console.error('ops.antifraud.release error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/notifications/settings', requireAuth, requireRole('creator'), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: 'Доступ только создателю' });
    }
    const q = await db.query(
      `SELECT enabled_types,
              priorities,
              quiet_hours_enabled,
              quiet_from,
              quiet_to,
              test_mode,
              updated_at
       FROM smart_notification_profiles
       WHERE user_id = $1
       LIMIT 1`,
      [req.user.id],
    );

    const defaults = {
      enabled_types: { order: true, support: true, delivery: true },
      priorities: { order: 'high', support: 'normal', delivery: 'high' },
      quiet_hours_enabled: false,
      quiet_from: '',
      quiet_to: '',
      test_mode: true,
      updated_at: null,
    };

    const data = q.rowCount > 0 ? { ...defaults, ...q.rows[0] } : defaults;
    return res.json({ ok: true, data });
  } catch (err) {
    console.error('ops.notifications.settings.get error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.put('/notifications/settings', requireAuth, requireRole('creator'), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: 'Доступ только создателю' });
    }

    const enabledTypesRaw =
      req.body?.enabled_types &&
      typeof req.body.enabled_types === 'object' &&
      !Array.isArray(req.body.enabled_types)
        ? req.body.enabled_types
        : {};
    const prioritiesRaw =
      req.body?.priorities &&
      typeof req.body.priorities === 'object' &&
      !Array.isArray(req.body.priorities)
        ? req.body.priorities
        : {};

    const enabledTypes = {
      order: Boolean(enabledTypesRaw.order ?? true),
      support: Boolean(enabledTypesRaw.support ?? true),
      delivery: Boolean(enabledTypesRaw.delivery ?? true),
    };
    const priorities = {
      order: normalizePriority(prioritiesRaw.order),
      support: normalizePriority(prioritiesRaw.support),
      delivery: normalizePriority(prioritiesRaw.delivery),
    };

    const quietHoursEnabled = Boolean(req.body?.quiet_hours_enabled ?? false);
    const quietFrom = normalizeClock(req.body?.quiet_from);
    const quietTo = normalizeClock(req.body?.quiet_to);
    const testMode = Boolean(req.body?.test_mode ?? true);

    const upsert = await db.query(
      `INSERT INTO smart_notification_profiles (
         tenant_id,
         user_id,
         enabled_types,
         priorities,
         quiet_hours_enabled,
         quiet_from,
         quiet_to,
         test_mode,
         updated_at
       )
       VALUES ($1, $2, $3::jsonb, $4::jsonb, $5, NULLIF($6, ''), NULLIF($7, ''), $8, now())
       ON CONFLICT (user_id) DO UPDATE
       SET tenant_id = EXCLUDED.tenant_id,
           enabled_types = EXCLUDED.enabled_types,
           priorities = EXCLUDED.priorities,
           quiet_hours_enabled = EXCLUDED.quiet_hours_enabled,
           quiet_from = EXCLUDED.quiet_from,
           quiet_to = EXCLUDED.quiet_to,
           test_mode = EXCLUDED.test_mode,
           updated_at = now()
       RETURNING enabled_types,
                 priorities,
                 quiet_hours_enabled,
                 quiet_from,
                 quiet_to,
                 test_mode,
                 updated_at`,
      [
        req.user?.tenant_id || null,
        req.user.id,
        JSON.stringify(enabledTypes),
        JSON.stringify(priorities),
        quietHoursEnabled,
        quietFrom,
        quietTo,
        testMode,
      ],
    );

    await insertAuditFromReq(req, {
      action: 'notifications.settings.update',
      entityType: 'notification_profile',
      entityId: req.user.id,
      after: upsert.rows[0],
    });

    return res.json({ ok: true, data: upsert.rows[0] });
  } catch (err) {
    console.error('ops.notifications.settings.put error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/notifications/history', requireAuth, requireRole('creator'), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: 'Доступ только создателю' });
    }
    const rawType = String(req.query?.type || '').trim().toLowerCase();
    const rawPriority = String(req.query?.priority || '').trim().toLowerCase();
    const type = rawType ? normalizeType(rawType) : '';
    const priority = rawPriority ? normalizePriority(rawPriority) : '';
    const limit = parsePositiveInt(req.query?.limit, 50, 1, 500);
    const rows = await db.query(
      `SELECT id,
              tenant_id,
              profile_user_id,
              event_type,
              priority,
              title,
              message,
              payload,
              is_quiet,
              created_at
       FROM smart_notification_events
       WHERE profile_user_id = $1
         AND ($2::text = '' OR event_type = $2::text)
         AND ($3::text = '' OR priority = $3::text)
       ORDER BY created_at DESC
      LIMIT $4`,
      [req.user.id, type, priority, limit],
    );
    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error('ops.notifications.history error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/notifications/test', requireAuth, requireRole('creator'), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: 'Доступ только создателю' });
    }

    const type = normalizeType(req.body?.type);
    const priority = normalizePriority(req.body?.priority);
    const title = String(req.body?.title || '').trim() || 'Тестовое уведомление';
    const message = String(req.body?.message || '').trim() || 'Проверка умного уведомления';

    const settingsQ = await db.query(
      `SELECT enabled_types,
              priorities,
              quiet_hours_enabled,
              quiet_from,
              quiet_to,
              test_mode
       FROM smart_notification_profiles
       WHERE user_id = $1
       LIMIT 1`,
      [req.user.id],
    );

    const settings = settingsQ.rowCount > 0 ? settingsQ.rows[0] : {
      enabled_types: { order: true, support: true, delivery: true },
      priorities: { order: 'high', support: 'normal', delivery: 'high' },
      quiet_hours_enabled: false,
      quiet_from: '',
      quiet_to: '',
      test_mode: true,
    };

    const enabledTypes =
      settings.enabled_types && typeof settings.enabled_types === 'object'
        ? settings.enabled_types
        : {};
    if (enabledTypes[type] === false) {
      return res.status(400).json({
        ok: false,
        error: `Тип уведомления "${type}" отключен в настройках`,
      });
    }

    const silent = withinQuietHours({
      enabled: Boolean(settings.quiet_hours_enabled),
      from: normalizeClock(settings.quiet_from),
      to: normalizeClock(settings.quiet_to),
      now: new Date(),
    });

    const payload = {
      id: uuidv4(),
      type,
      priority,
      title,
      message,
      is_test: true,
      silent,
      created_at: new Date().toISOString(),
    };

    const saved = await saveSmartNotificationEvent({
      id: payload.id,
      tenantId: req.user?.tenant_id || null,
      profileUserId: req.user.id,
      eventType: type,
      priority,
      title,
      message,
      payload: {
        is_test: true,
        requested_type: type,
        requested_priority: priority,
      },
      isQuiet: silent,
    });
    if (saved) {
      payload.created_at = saved.created_at;
    }

    const io = req.app.get('io');
    if (io) {
      io.to(`user:${req.user.id}`).emit('smart:notification', payload);
      emitToTenant(io, req.user?.tenant_id || null, 'smart:notification:test', {
        ...payload,
        user_id: req.user.id,
      });
    }

    await insertAuditFromReq(req, {
      action: 'notifications.test.send',
      entityType: 'notification',
      entityId: payload.id,
      meta: { type, priority, silent },
    });

    return res.json({ ok: true, data: payload });
  } catch (err) {
    console.error('ops.notifications.test error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/diagnostics/center', requireAuth, requireRole('creator'), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: 'Доступ только создателю' });
    }

    const started = Date.now();
    await db.query('SELECT 1');
    const dbLatencyMs = Date.now() - started;

    const unresolvedQ = await db.query(
      `SELECT level, COUNT(*)::int AS total
       FROM monitoring_events
       WHERE resolved = false
         AND created_at >= now() - interval '7 days'
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid OR tenant_id IS NULL)
       GROUP BY level`,
      [req.user?.tenant_id || null],
    );

    const antifraudBlocksQ = await db.query(
      `SELECT COUNT(*)::int AS total
       FROM antifraud_blocks
       WHERE is_active = true
         AND blocked_until > now()
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid OR tenant_id IS NULL)`,
      [req.user?.tenant_id || null],
    );

    const pendingPostsQ = await db.query(
      `SELECT COUNT(*)::int AS total
       FROM product_publication_queue q
       JOIN chats c ON c.id = q.channel_id
       WHERE q.status = 'pending'
         AND COALESCE(q.is_sent, false) = false
         AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)`,
      [req.user?.tenant_id || null],
    );

    const io = req.app.get('io');
    const sockets = Number(io?.engine?.clientsCount || 0);
    const rooms = Number(io?.sockets?.adapter?.rooms?.size || 0);

    const byLevel = {
      info: 0,
      warn: 0,
      error: 0,
      critical: 0,
    };
    for (const row of unresolvedQ.rows) {
      byLevel[String(row.level || 'info')] = Number(row.total || 0);
    }

    return res.json({
      ok: true,
      data: {
        api: {
          status: 'ok',
          uptime_sec: Math.floor(process.uptime()),
        },
        database: {
          status: 'ok',
          latency_ms: dbLatencyMs,
        },
        socket: {
          connected_clients: sockets,
          rooms,
        },
        queue: {
          pending_posts: Number(pendingPostsQ.rows[0]?.total || 0),
        },
        antifraud: {
          active_blocks: Number(antifraudBlocksQ.rows[0]?.total || 0),
        },
        monitoring: byLevel,
        runtime: {
          node: process.version,
          platform: process.platform,
          load_avg: os.loadavg(),
          memory: process.memoryUsage(),
        },
        generated_at: new Date().toISOString(),
      },
    });
  } catch (err) {
    console.error('ops.diagnostics.center error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/roles/constructor-draft', requireAuth, requireRole('admin', 'creator'), async (req, res) => {
  try {
    const templatesQ = await db.query(
      `SELECT rt.id,
              rt.code,
              rt.title,
              rt.description,
              rt.permissions,
              rt.is_system,
              COUNT(urt.user_id)::int AS assigned_users
       FROM role_templates rt
       LEFT JOIN user_role_templates urt ON urt.template_id = rt.id
       WHERE rt.tenant_id = $1::uuid OR rt.tenant_id IS NULL
       GROUP BY rt.id
       ORDER BY rt.is_system DESC, rt.updated_at DESC`,
      [req.user?.tenant_id || null],
    );

    return res.json({
      ok: true,
      data: {
        draft: true,
        can_manage: true,
        description:
          'Конструктор прав в черновом режиме: можно настраивать доступ по действиям и назначать шаблоны пользователям.',
        modules: ROLE_PERMISSION_MODULES,
        templates: templatesQ.rows,
      },
    });
  } catch (err) {
    console.error('ops.roles.constructorDraft error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get(
  '/roles/users',
  requireAuth,
  requireRole('admin', 'creator'),
  requireTenantUsersManagePermission,
  async (req, res) => {
  try {
    const tenantId = req.user?.tenant_id || null;
    const searchRaw = String(req.query?.search || '').trim().slice(0, 80);
    const searchDigits = searchRaw.replace(/\D/g, '').slice(0, 24);
    const limit = parsePositiveInt(req.query?.limit, 200, 1, 500);

    const usersQ = await db.query(
      `SELECT u.id,
              u.name,
              u.email,
              u.role,
              p.phone,
              urt.template_id,
              rt.title AS template_title,
              rt.code AS template_code
       FROM users u
       LEFT JOIN phones p ON p.user_id = u.id
       LEFT JOIN user_role_templates urt ON urt.user_id = u.id
       LEFT JOIN role_templates rt ON rt.id = urt.template_id
       WHERE (${tenantFilterSql('u', 1)})
         AND u.role <> 'creator'
         AND (
           $2::text = ''
           OR COALESCE(u.name, '') ILIKE '%' || $2 || '%'
           OR COALESCE(u.email, '') ILIKE '%' || $2 || '%'
           OR ($3::text <> '' AND COALESCE(p.phone, '') ILIKE '%' || $3 || '%')
         )
       ORDER BY u.created_at DESC
       LIMIT $4`,
      [tenantId, searchRaw, searchDigits, limit],
    );
    return res.json({ ok: true, data: usersQ.rows });
  } catch (err) {
    console.error('ops.roles.users error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post(
  '/roles/templates',
  requireAuth,
  requireRole('admin', 'creator'),
  requireTenantUsersManagePermission,
  async (req, res) => {
  try {
    const tenantId = req.user?.tenant_id || null;
    const title = String(req.body?.title || '').trim();
    const description = String(req.body?.description || '').trim();
    const permissions = normalizePermissionsPayload(req.body?.permissions);

    if (!title) {
      return res.status(400).json({ ok: false, error: 'Название шаблона обязательно' });
    }

    let code = normalizeTemplateCode(req.body?.code, title);
    let created = null;

    for (let i = 0; i < 5; i += 1) {
      try {
        const candidate = i === 0
          ? code
          : normalizeTemplateCode(`${code}-${Math.floor(Math.random() * 900 + 100)}`);
        const insert = await db.query(
          `INSERT INTO role_templates (
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
           VALUES ($1, $2, $3, NULLIF($4, ''), $5::jsonb, false, $6, now(), now())
           RETURNING *`,
          [tenantId, candidate, title, description, JSON.stringify(permissions), req.user?.id || null],
        );
        created = insert.rows[0] || null;
        break;
      } catch (err) {
        if (String(err?.code || '') === '23505') continue;
        throw err;
      }
    }

    if (!created) {
      return res.status(409).json({ ok: false, error: 'Не удалось создать уникальный code' });
    }

    await insertAuditFromReq(req, {
      action: 'roles.template.create',
      entityType: 'role_template',
      entityId: created.id,
      after: created,
    });

    return res.status(201).json({ ok: true, data: created });
  } catch (err) {
    console.error('ops.roles.templates.create error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.patch(
  '/roles/templates/:id',
  requireAuth,
  requireRole('admin', 'creator'),
  requireTenantUsersManagePermission,
  async (req, res) => {
  try {
    const tenantId = req.user?.tenant_id || null;
    const id = String(req.params?.id || '').trim();
    if (!id) {
      return res.status(400).json({ ok: false, error: 'id шаблона обязателен' });
    }

    const beforeQ = await db.query(
      `SELECT *
       FROM role_templates
       WHERE id = $1
       LIMIT 1`,
      [id],
    );
    if (beforeQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Шаблон не найден' });
    }
    const before = beforeQ.rows[0];
    if (before.is_system === true) {
      return res.status(403).json({ ok: false, error: 'Системный шаблон нельзя редактировать' });
    }
    if (String(before.tenant_id || '') !== String(tenantId || '')) {
      return res.status(403).json({ ok: false, error: 'Нет доступа к шаблону' });
    }

    const title = String(req.body?.title || '').trim();
    const description = String(req.body?.description || '').trim();
    const permissionsProvided =
      req.body &&
      Object.prototype.hasOwnProperty.call(req.body, 'permissions');
    const permissions = permissionsProvided
      ? normalizePermissionsPayload(req.body?.permissions)
      : null;

    const updatedQ = await db.query(
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
      [title, description || null, permissions ? JSON.stringify(permissions) : null, id],
    );
    const updated = updatedQ.rows[0] || null;

    await insertAuditFromReq(req, {
      action: 'roles.template.update',
      entityType: 'role_template',
      entityId: id,
      before,
      after: updated,
    });

    return res.json({ ok: true, data: updated });
  } catch (err) {
    console.error('ops.roles.templates.patch error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.delete(
  '/roles/templates/:id',
  requireAuth,
  requireRole('admin', 'creator'),
  requireTenantUsersManagePermission,
  async (req, res) => {
  const client = await db.connect();
  try {
    const tenantId = req.user?.tenant_id || null;
    const id = String(req.params?.id || '').trim();
    if (!id) {
      return res.status(400).json({ ok: false, error: 'id шаблона обязателен' });
    }

    await client.query('BEGIN');

    const beforeQ = await client.query(
      `SELECT *
       FROM role_templates
       WHERE id = $1
       LIMIT 1`,
      [id],
    );
    if (beforeQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Шаблон не найден' });
    }
    const before = beforeQ.rows[0];
    if (before.is_system === true) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Системный шаблон нельзя удалить' });
    }
    if (String(before.tenant_id || '') !== String(tenantId || '')) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Нет доступа к шаблону' });
    }

    const detachQ = await client.query(
      `DELETE FROM user_role_templates
       WHERE template_id = $1`,
      [id],
    );
    await client.query(
      `DELETE FROM role_templates
       WHERE id = $1`,
      [id],
    );

    await client.query('COMMIT');

    await insertAuditFromReq(req, {
      action: 'roles.template.delete',
      entityType: 'role_template',
      entityId: id,
      before,
      meta: {
        unassigned_users: Number(detachQ.rowCount || 0),
      },
    });

    return res.json({ ok: true, data: { id, unassigned_users: Number(detachQ.rowCount || 0) } });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('ops.roles.templates.delete error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.post(
  '/roles/assign',
  requireAuth,
  requireRole('admin', 'creator'),
  requireTenantUsersManagePermission,
  async (req, res) => {
  const client = await db.connect();
  try {
    const tenantId = req.user?.tenant_id || null;
    const userId = String(req.body?.user_id || '').trim();
    const templateId = String(req.body?.template_id || '').trim();
    if (!userId) {
      return res.status(400).json({ ok: false, error: 'user_id обязателен' });
    }

    await client.query('BEGIN');

    const userQ = await client.query(
      `SELECT id, role, tenant_id
       FROM users
       WHERE id = $1
         AND (${tenantFilterSql('users', 2)})
       LIMIT 1`,
      [userId, tenantId],
    );
    if (userQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    const targetUser = userQ.rows[0];
    if (normalizeRole(targetUser.role) === 'creator') {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Нельзя назначать шаблон создателю' });
    }

    if (!templateId || templateId === 'none') {
      await client.query(
        `DELETE FROM user_role_templates
         WHERE user_id = $1`,
        [userId],
      );
      await client.query('COMMIT');
      await insertAuditFromReq(req, {
        action: 'roles.template.unassign',
        entityType: 'user',
        entityId: userId,
      });
      return res.json({ ok: true, data: { user_id: userId, template_id: null } });
    }

    const templateQ = await client.query(
      `SELECT id, tenant_id, code
       FROM role_templates
       WHERE id = $1
         AND (tenant_id = $2::uuid OR tenant_id IS NULL)
       LIMIT 1`,
      [templateId, tenantId],
    );
    if (templateQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Шаблон роли не найден' });
    }
    const template = templateQ.rows[0];
    const templateCode = normalizeRole(template.code);

    if (templateCode === 'creator') {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Назначение шаблона creator запрещено' });
    }
    if (templateCode === 'tenant' && !isCreatorBase(req.user)) {
      await client.query('ROLLBACK');
      return res.status(403).json({ ok: false, error: 'Шаблон tenant может назначать только создатель' });
    }

    await client.query(
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
      [userId, templateId, req.user?.id || null],
    );

    if (['client', 'worker', 'admin', 'tenant'].includes(templateCode)) {
      await client.query(
        `UPDATE users
         SET role = $1,
             updated_at = now()
         WHERE id = $2`,
        [templateCode, userId],
      );
    }

    await client.query('COMMIT');

    await insertAuditFromReq(req, {
      action: 'roles.template.assign',
      entityType: 'user',
      entityId: userId,
      meta: {
        template_id: templateId,
        template_code: templateCode,
      },
    });

    return res.json({ ok: true, data: { user_id: userId, template_id: templateId } });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('ops.roles.assign error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.get('/support/templates', requireAuth, requireRole('admin', 'creator', 'worker'), async (req, res) => {
  try {
    const rawCategory = String(req.query?.category || '').trim().toLowerCase();
    const category = rawCategory ? normalizeTemplateCategory(rawCategory) : '';
    const rows = await db.query(
      `SELECT id,
              tenant_id,
              title,
              body,
              category,
              trigger_rule,
              auto_reply_enabled,
              priority,
              is_active,
              is_system,
              created_by,
              created_at,
              updated_at
       FROM support_reply_templates
       WHERE (tenant_id = $1::uuid OR tenant_id IS NULL)
         AND category = COALESCE(NULLIF($2, ''), category)
         AND is_active = true
       ORDER BY is_system DESC, updated_at DESC, created_at DESC`,
      [req.user?.tenant_id || null, category || ''],
    );
    return res.json({ ok: true, data: rows.rows });
  } catch (err) {
    console.error('ops.support.templates.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/support/templates', requireAuth, requireRole('admin', 'creator'), async (req, res) => {
  try {
    const title = String(req.body?.title || '').trim();
    const body = String(req.body?.body || '').trim();
    const category = normalizeTemplateCategory(req.body?.category);
    const triggerRule = normalizeTriggerRule(req.body?.trigger_rule);
    const autoReplyEnabled = req.body?.auto_reply_enabled === true;
    const priority = normalizeSupportTemplatePriority(req.body?.priority, 100);

    if (!title || !body) {
      return res.status(400).json({ ok: false, error: 'title и body обязательны' });
    }
    if (autoReplyEnabled && !triggerRule) {
      return res.status(400).json({
        ok: false,
        error: 'Для автоответа укажите trigger_rule или "*" для fallback-режима',
      });
    }

    const ins = await db.query(
      `INSERT INTO support_reply_templates (
         tenant_id,
         title,
         body,
         category,
         trigger_rule,
         auto_reply_enabled,
         priority,
         is_active,
         is_system,
         created_by,
         created_at,
         updated_at
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, true, false, $8, now(), now())
       RETURNING *`,
      [
        req.user?.tenant_id || null,
        title,
        body,
        category,
        triggerRule,
        autoReplyEnabled,
        priority,
        req.user?.id || null,
      ],
    );

    await insertAuditFromReq(req, {
      action: 'support.template.create',
      entityType: 'support_template',
      entityId: ins.rows[0]?.id,
      after: ins.rows[0],
    });

    return res.status(201).json({ ok: true, data: ins.rows[0] });
  } catch (err) {
    console.error('ops.support.templates.create error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.patch('/support/templates/:id', requireAuth, requireRole('admin', 'creator'), async (req, res) => {
  try {
    const id = String(req.params?.id || '').trim();
    if (!id) {
      return res.status(400).json({ ok: false, error: 'id шаблона обязателен' });
    }

    const beforeQ = await db.query(
      `SELECT *
       FROM support_reply_templates
       WHERE id = $1
         AND (tenant_id = $2::uuid OR tenant_id IS NULL)
       LIMIT 1`,
      [id, req.user?.tenant_id || null],
    );
    if (beforeQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Шаблон не найден' });
    }

    const body = String(req.body?.body || '').trim();
    const title = String(req.body?.title || '').trim();
    const isActive = req.body?.is_active;
    const category = normalizeTemplateCategory(req.body?.category);
    const hasTriggerRule = Object.prototype.hasOwnProperty.call(req.body || {}, 'trigger_rule');
    const triggerRule = hasTriggerRule
      ? normalizeTriggerRule(req.body?.trigger_rule)
      : null;
    const hasAutoReplyEnabled = Object.prototype.hasOwnProperty.call(
      req.body || {},
      'auto_reply_enabled',
    );
    const autoReplyEnabled = hasAutoReplyEnabled
      ? req.body?.auto_reply_enabled === true
      : null;
    const hasPriority = Object.prototype.hasOwnProperty.call(req.body || {}, 'priority');
    const priority = hasPriority
      ? normalizeSupportTemplatePriority(req.body?.priority, 100)
      : null;
    const current = beforeQ.rows[0] || {};
    const nextTriggerRule = hasTriggerRule
      ? String(triggerRule || '').trim()
      : String(current.trigger_rule || '').trim();
    const nextAutoReplyEnabled = hasAutoReplyEnabled
      ? autoReplyEnabled === true
      : current.auto_reply_enabled === true;
    if (nextAutoReplyEnabled && !nextTriggerRule) {
      return res.status(400).json({
        ok: false,
        error: 'Для автоответа укажите trigger_rule или "*" для fallback-режима',
      });
    }

    const updated = await db.query(
      `UPDATE support_reply_templates
       SET title = COALESCE(NULLIF($1, ''), title),
           body = COALESCE(NULLIF($2, ''), body),
           category = COALESCE(NULLIF($3, ''), category),
           is_active = CASE WHEN $4::boolean IS NULL THEN is_active ELSE $4::boolean END,
           trigger_rule = CASE WHEN $6::boolean THEN $5 ELSE trigger_rule END,
           auto_reply_enabled = CASE
             WHEN $8::boolean THEN $7::boolean
             ELSE auto_reply_enabled
           END,
           priority = CASE WHEN $10::boolean THEN $9::integer ELSE priority END,
           updated_at = now()
       WHERE id = $11
       RETURNING *`,
      [
        title,
        body,
        category,
        typeof isActive === 'boolean' ? isActive : null,
        triggerRule,
        hasTriggerRule,
        autoReplyEnabled,
        hasAutoReplyEnabled,
        priority,
        hasPriority,
        id,
      ],
    );

    await insertAuditFromReq(req, {
      action: 'support.template.update',
      entityType: 'support_template',
      entityId: id,
      before: beforeQ.rows[0],
      after: updated.rows[0],
    });

    return res.json({ ok: true, data: updated.rows[0] });
  } catch (err) {
    console.error('ops.support.templates.patch error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post(
  '/support/tickets/:ticketId/quick-reply',
  requireAuth,
  requireRole('worker', 'admin', 'tenant'),
  requireSupportWritePermission,
  async (req, res) => {
  const ticketId = String(req.params?.ticketId || '').trim();
  const templateId = String(req.body?.template_id || '').trim();
  const extraText = String(req.body?.extra_text || '').trim();

  if (!ticketId || !templateId) {
    return res.status(400).json({ ok: false, error: 'ticket_id и template_id обязательны' });
  }

  const antifraud = await guardAction({
    queryable: db,
    tenantId: req.user?.tenant_id || null,
    userId: req.user?.id,
    actionKey: 'support.staff_reply',
    details: {
      ticket_id: ticketId,
      template_id: templateId,
    },
  });
  if (!antifraud.allowed) {
    return res.status(429).json({
      ok: false,
      error: antifraud.reason || 'Слишком много быстрых ответов. Попробуйте позже.',
      blocked_until: antifraud.blockedUntil || null,
    });
  }

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');

    const ticketLockQ = await client.query(
      `SELECT st.id,
              st.chat_id,
              st.customer_id,
              st.assignee_id,
              st.status,
              st.subject,
              st.category
       FROM support_tickets st
       WHERE st.id = $1
         AND ($2::uuid IS NULL OR st.tenant_id = $2::uuid)
       LIMIT 1
       FOR UPDATE`,
      [ticketId, req.user?.tenant_id || null],
    );

    if (ticketLockQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Тикет не найден' });
    }

    const ticketBase = ticketLockQ.rows[0];
    const ticketMetaQ = await client.query(
      `SELECT c.title AS chat_title,
              COALESCE(NULLIF(BTRIM(cu.name), ''), NULLIF(BTRIM(cu.email), ''), 'Клиент') AS customer_name,
              latest_dbc.delivery_status
       FROM chats c
       LEFT JOIN users cu ON cu.id = $2
       LEFT JOIN LATERAL (
         SELECT dbc.delivery_status
         FROM delivery_batch_customers dbc
         WHERE dbc.user_id = $2
         ORDER BY dbc.updated_at DESC NULLS LAST, dbc.created_at DESC
         LIMIT 1
       ) latest_dbc ON true
       WHERE c.id = $1
       LIMIT 1`,
      [ticketBase.chat_id, ticketBase.customer_id],
    );
    const ticket = {
      ...ticketBase,
      chat_title: ticketMetaQ.rows[0]?.chat_title || '',
      customer_name: ticketMetaQ.rows[0]?.customer_name || 'Клиент',
      delivery_status: ticketMetaQ.rows[0]?.delivery_status || null,
    };
    if (String(ticket.assignee_id || '') !== String(req.user?.id || '')) {
      await client.query('ROLLBACK');
      return res.status(403).json({
        ok: false,
        error: 'Отправлять шаблон может только назначенный администратор',
      });
    }

    const templateQ = await client.query(
      `SELECT id, title, body, category
       FROM support_reply_templates
       WHERE id = $1
         AND is_active = true
         AND (tenant_id = $2::uuid OR tenant_id IS NULL)
       LIMIT 1`,
      [templateId, req.user?.tenant_id || null],
    );

    if (templateQ.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ ok: false, error: 'Шаблон не найден' });
    }

    const sums = await resolveCartSumsForUser(ticket.customer_id);
    const lastCustomerMessageQ = await client.query(
      `SELECT text
       FROM messages
       WHERE chat_id = $1
         AND sender_id = $2
         AND NULLIF(BTRIM(text), '') IS NOT NULL
       ORDER BY created_at DESC
       LIMIT 1`,
      [ticket.chat_id, ticket.customer_id],
    );
    const lastCustomerMessage = String(
      decryptMessageText(lastCustomerMessageQ.rows[0]?.text || ''),
    ).trim();
    const safeSubject = String(ticket.subject || '').trim();
    const safeLastCustomerMessage = lastCustomerMessage || '—';
    const rendered = renderSupportTemplateBody(templateQ.rows[0].body, {
      customer_name: ticket.customer_name,
      cart_total: sums.total,
      processed_total: sums.processed,
      claims_total: sums.claims_total,
      delivery_status: ticket.delivery_status || '—',
      subject: safeSubject.isNotEmpty ? safeSubject : '—',
      message_text: safeLastCustomerMessage,
    });

    const finalText = [rendered, extraText]
      .map((part) => String(part || '').trim())
      .filter((part) => part.length > 0)
      .join('\n\n')
      .trim();
    if (!finalText) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        ok: false,
        error:
          'Шаблон пустой после подстановки. Добавьте текст в шаблон или дополнительный комментарий.',
      });
    }

    const msgIns = await client.query(
      `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5::jsonb, now())
       RETURNING id`,
      [
        uuidv4(),
        ticket.chat_id,
        req.user?.id || null,
        encryptMessageText(finalText),
        JSON.stringify({
          kind: 'support_quick_reply',
          support_ticket_id: ticket.id,
          template_id: templateQ.rows[0].id,
          template_title: templateQ.rows[0].title,
        }),
      ],
    );

    await client.query(
      `UPDATE support_tickets
       SET status = 'waiting_customer',
           assignee_id = COALESCE(assignee_id, $1),
           last_staff_message_at = now(),
           updated_at = now()
       WHERE id = $2`,
      [req.user?.id || null, ticket.id],
    );

    await client.query('UPDATE chats SET updated_at = now() WHERE id = $1', [ticket.chat_id]);

    await client.query('COMMIT');

    const hydrated = await hydrateSupportMessage(msgIns.rows[0]?.id);
    const io = req.app.get('io');
    if (io && hydrated) {
      io.to(`chat:${ticket.chat_id}`).emit('chat:message', {
        chatId: ticket.chat_id,
        message: hydrated,
      });
      emitToTenant(io, req.user?.tenant_id || null, 'chat:updated', {
        chatId: ticket.chat_id,
      });
    }

    await insertAuditFromReq(req, {
      action: 'support.ticket.quick_reply',
      entityType: 'support_ticket',
      entityId: ticket.id,
      meta: {
        template_id: templateQ.rows[0].id,
        template_title: templateQ.rows[0].title,
      },
    });

    return res.json({
      ok: true,
      data: {
        ticket_id: ticket.id,
        message_id: hydrated?.id || null,
        text: finalText,
      },
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('ops.support.quickReply error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

router.get(
  '/notifications/center',
  requireAuth,
  requireRole('admin', 'tenant', 'creator'),
  async (req, res) => {
  try {
    const tenantId = req.user?.tenant_id || null;
    const limit = parsePositiveInt(req.query?.limit, 60, 10, 200);

    const [supportSummaryQ, claimsSummaryQ, retentionSummaryQ, eventsQ, retentionEventsQ] =
      await Promise.all([
      db.query(
        `SELECT COUNT(*) FILTER (WHERE status = 'open')::int AS support_open,
                COUNT(*) FILTER (WHERE status = 'waiting_customer')::int AS support_waiting_customer,
                COUNT(*) FILTER (WHERE status = 'resolved')::int AS support_resolved
         FROM support_tickets
         WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid)`,
        [tenantId],
      ),
      db.query(
        `SELECT COUNT(*) FILTER (WHERE status = 'pending')::int AS claims_pending,
                COUNT(*) FILTER (WHERE status = 'approved_return')::int AS claims_approved_return,
                COUNT(*) FILTER (
                  WHERE status = 'approved_discount'
                    AND COALESCE(customer_discount_status, '') = 'pending'
                )::int AS claims_discount_waiting_customer,
                COUNT(*) FILTER (WHERE status = 'rejected')::int AS claims_rejected
         FROM customer_claims
         WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid)`,
        [tenantId],
      ),
      db.query(
        `SELECT COUNT(*)::int AS stale_carts
         FROM (
           SELECT c.user_id
           FROM cart_items c
           JOIN users u ON u.id = c.user_id
           WHERE c.status IN ('pending_processing', 'processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')
             AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
           GROUP BY c.user_id
           HAVING MIN(c.created_at) <= now() - make_interval(days => $2::int)
         ) stale`,
        [tenantId, CART_RETENTION_WARNING_DAYS],
      ),
      db.query(
        `SELECT events.*
         FROM (
           SELECT st.id::text AS source_id,
                  'support_ticket'::text AS event_type,
                  st.status::text AS status,
                  NULL::text AS claim_type,
                  NULL::text AS customer_discount_status,
                  COALESCE(NULLIF(BTRIM(st.subject), ''), 'Тикет поддержки') AS title,
                  COALESCE(NULLIF(BTRIM(cu.name), ''), NULLIF(BTRIM(cu.email), ''), 'Клиент') AS customer_name,
                  COALESCE(NULLIF(BTRIM(ch.title), ''), 'Поддержка') AS related_name,
                  NULL::numeric AS amount,
                  st.created_at,
                  st.updated_at,
                  COALESCE(st.updated_at, st.created_at) AS event_at
           FROM support_tickets st
           LEFT JOIN users cu ON cu.id = st.customer_id
           LEFT JOIN chats ch ON ch.id = st.chat_id
           WHERE ($1::uuid IS NULL OR st.tenant_id = $1::uuid)

           UNION ALL

           SELECT cc.id::text AS source_id,
                  'claim'::text AS event_type,
                  cc.status::text AS status,
                  cc.claim_type::text AS claim_type,
                  COALESCE(cc.customer_discount_status, '')::text AS customer_discount_status,
                  COALESCE(NULLIF(BTRIM(p.title), ''), 'Претензия по товару') AS title,
                  COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
                  COALESCE(NULLIF(BTRIM(p.title), ''), 'Товар') AS related_name,
                  CASE
                    WHEN COALESCE(cc.approved_amount, 0) > 0 THEN cc.approved_amount
                    ELSE cc.requested_amount
                  END::numeric AS amount,
                  cc.created_at,
                  cc.updated_at,
                  COALESCE(cc.updated_at, cc.created_at) AS event_at
           FROM customer_claims cc
           LEFT JOIN users u ON u.id = cc.user_id
           LEFT JOIN products p ON p.id = cc.product_id
           WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
         ) events
         ORDER BY events.event_at DESC
         LIMIT $2::int`,
        [tenantId, Math.max(limit * 2, 40)],
      ),
      db.query(
        `SELECT c.user_id::text AS user_id,
                MIN(c.created_at) AS oldest_created_at,
                MAX(c.updated_at) AS latest_updated_at,
                COUNT(*)::int AS items_count,
                COALESCE(
                  SUM((COALESCE(c.custom_price, p.price) * c.quantity)),
                  0
                )::numeric AS total_sum,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
                COALESCE(NULLIF(BTRIM(ph.phone), ''), '') AS customer_phone,
                us.shelf_number
         FROM cart_items c
         JOIN users u ON u.id = c.user_id
         JOIN products p ON p.id = c.product_id
         LEFT JOIN phones ph ON ph.user_id = u.id
         LEFT JOIN user_shelves us ON us.user_id = u.id
         WHERE c.status IN ('pending_processing', 'processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')
           AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
         GROUP BY c.user_id, u.name, u.email, ph.phone, us.shelf_number
         HAVING MIN(c.created_at) <= now() - make_interval(days => $2::int)
         ORDER BY MIN(c.created_at) ASC
         LIMIT $3::int`,
        [tenantId, CART_RETENTION_WARNING_DAYS, Math.max(limit, 20)],
      ),
    ]);

    const supportSummary = supportSummaryQ.rows[0] || {};
    const claimsSummary = claimsSummaryQ.rows[0] || {};
    const retentionSummary = retentionSummaryQ.rows[0] || {};
    const summary = {
      support_open: Number(supportSummary.support_open || 0),
      support_waiting_customer: Number(
        supportSummary.support_waiting_customer || 0,
      ),
      support_resolved: Number(supportSummary.support_resolved || 0),
      claims_pending: Number(claimsSummary.claims_pending || 0),
      claims_approved_return: Number(claimsSummary.claims_approved_return || 0),
      claims_discount_waiting_customer: Number(
        claimsSummary.claims_discount_waiting_customer || 0,
      ),
      claims_rejected: Number(claimsSummary.claims_rejected || 0),
      stale_carts: Number(retentionSummary.stale_carts || 0),
    };
    summary.total_attention =
      summary.support_open +
      summary.support_waiting_customer +
      summary.claims_pending +
      summary.claims_discount_waiting_customer +
      summary.stale_carts;

    const baseItems = eventsQ.rows.map((row) => {
      const eventType = String(row.event_type || '').trim();
      const status = String(row.status || '').trim();
      const customerDiscountStatus = String(
        row.customer_discount_status || '',
      ).trim();
      const statusLabel = eventType === 'support_ticket'
        ? mapSupportTicketStatusLabel(status)
        : mapClaimWorkflowStatus(status, customerDiscountStatus);
      const claimType = String(row.claim_type || '').trim();
      const claimTypeLabel = claimType ? mapClaimTypeLabel(claimType) : '';
      const amount = eventType === 'claim' ? toMoney(row.amount) : null;
      const subtitleBase = `${String(row.customer_name || 'Клиент')} · ${statusLabel}`;
      const subtitle = amount === null
        ? subtitleBase
        : `${subtitleBase} · ${amount.toFixed(2)} ₽`;

      return {
        id: String(row.source_id || ''),
        type: eventType,
        type_label: eventType === 'support_ticket'
          ? 'Поддержка'
          : 'Возврат/Скидка',
        status,
        status_label: statusLabel,
        priority: mapOpsEventPriority({
          type: eventType,
          status,
          customerDiscountStatus,
        }),
        title: eventType === 'claim'
          ? `${claimTypeLabel}: ${String(row.related_name || row.title || 'Заявка')}`
          : String(row.title || 'Тикет поддержки'),
        subtitle,
        customer_name: String(row.customer_name || ''),
        related_name: String(row.related_name || ''),
        claim_type: claimType || null,
        claim_type_label: claimTypeLabel || null,
        amount,
        created_at: row.created_at || null,
        updated_at: row.updated_at || null,
        event_at: row.event_at || null,
      };
    });
    const retentionItems = retentionEventsQ.rows.map((row) => {
      const oldestCreatedAt = row.oldest_created_at
        ? new Date(row.oldest_created_at)
        : null;
      const daysHeld =
        oldestCreatedAt && !Number.isNaN(oldestCreatedAt.getTime())
          ? Math.max(
              0,
              Math.floor((Date.now() - oldestCreatedAt.getTime()) / (24 * 60 * 60 * 1000)),
            )
          : CART_RETENTION_WARNING_DAYS;
      const tail = phoneTail(row.customer_phone);
      const tailLabel = tail ? `••••${tail}` : 'номер не указан';
      const shelf = shelfLabel(row.shelf_number);
      const total = toMoney(row.total_sum);
      return {
        id: `cart-retention:${String(row.user_id || '')}`,
        type: 'cart_retention',
        type_label: 'Корзины',
        status: 'stale',
        status_label: 'Ожидает расформировки',
        priority: mapOpsEventPriority({ type: 'cart_retention', status: 'stale' }),
        title: `Расформировать корзину: ${String(row.customer_name || 'Клиент')}`,
        subtitle: `Телефон ${tailLabel} · Полка ${shelf} · ${daysHeld} дн.`,
        customer_name: String(row.customer_name || ''),
        related_name: `Полка ${shelf}`,
        claim_type: null,
        claim_type_label: null,
        amount: total,
        created_at: row.oldest_created_at || null,
        updated_at: row.latest_updated_at || null,
        event_at: row.latest_updated_at || row.oldest_created_at || null,
      };
    });
    const items = [...baseItems, ...retentionItems]
      .sort((a, b) => {
        const aTs = new Date(a.event_at || 0).getTime();
        const bTs = new Date(b.event_at || 0).getTime();
        return bTs - aTs;
      })
      .slice(0, limit);

    await insertAuditFromReq(req, {
      action: 'ops.notifications.center.view',
      entityType: 'ops_notifications',
      meta: { limit },
    });

    return res.json({ ok: true, data: { summary, items } });
  } catch (err) {
    console.error('ops.notifications.center error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get(
  '/returns/analytics',
  requireAuth,
  requireRole('admin', 'tenant', 'creator'),
  async (req, res) => {
  try {
    const tenantId = req.user?.tenant_id || null;
    const days = parsePositiveInt(req.query?.days, 30, 1, 365);
    const topProductsLimit = parsePositiveInt(req.query?.top_limit, 8, 3, 20);

    const [summaryQ, byTypeQ, byStatusQ, byDayQ, topProductsQ] =
      await Promise.all([
        db.query(
          `WITH base AS (
             SELECT cc.*,
                    CASE
                      WHEN COALESCE(cc.approved_amount, 0) > 0 THEN cc.approved_amount
                      ELSE cc.requested_amount
                    END::numeric AS effective_amount
             FROM customer_claims cc
             WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
               AND cc.created_at >= now() - make_interval(days => $2::int)
           )
           SELECT COUNT(*)::int AS total_claims,
                  COUNT(*) FILTER (WHERE status = 'pending')::int AS pending_claims,
                  COUNT(*) FILTER (WHERE status = 'rejected')::int AS rejected_claims,
                  COUNT(*) FILTER (WHERE status = 'settled')::int AS settled_claims,
                  COUNT(*) FILTER (
                    WHERE status IN ('approved_return', 'approved_discount')
                  )::int AS approved_active_claims,
                  COALESCE(SUM(effective_amount) FILTER (
                    WHERE status IN ('approved_return', 'approved_discount', 'settled')
                  ), 0)::numeric(14,2) AS defect_sum,
                  COALESCE(SUM(effective_amount) FILTER (
                    WHERE claim_type = 'return'
                      AND status IN ('approved_return', 'settled')
                  ), 0)::numeric(14,2) AS returns_sum,
                  COALESCE(SUM(effective_amount) FILTER (
                    WHERE claim_type = 'discount'
                      AND status IN ('approved_discount', 'settled')
                  ), 0)::numeric(14,2) AS discounts_sum
           FROM base`,
          [tenantId, days],
        ),
        db.query(
          `WITH base AS (
             SELECT cc.*,
                    CASE
                      WHEN COALESCE(cc.approved_amount, 0) > 0 THEN cc.approved_amount
                      ELSE cc.requested_amount
                    END::numeric AS effective_amount
             FROM customer_claims cc
             WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
               AND cc.created_at >= now() - make_interval(days => $2::int)
           )
           SELECT claim_type,
                  COUNT(*)::int AS total_claims,
                  COUNT(*) FILTER (WHERE status = 'pending')::int AS pending_claims,
                  COUNT(*) FILTER (WHERE status = 'rejected')::int AS rejected_claims,
                  COALESCE(SUM(effective_amount) FILTER (
                    WHERE status IN ('approved_return', 'approved_discount', 'settled')
                  ), 0)::numeric(14,2) AS approved_sum
           FROM base
           GROUP BY claim_type
           ORDER BY claim_type ASC`,
          [tenantId, days],
        ),
        db.query(
          `WITH base AS (
             SELECT cc.*,
                    CASE
                      WHEN COALESCE(cc.approved_amount, 0) > 0 THEN cc.approved_amount
                      ELSE cc.requested_amount
                    END::numeric AS effective_amount
             FROM customer_claims cc
             WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
               AND cc.created_at >= now() - make_interval(days => $2::int)
           )
           SELECT status,
                  COUNT(*)::int AS total_claims,
                  COALESCE(SUM(effective_amount), 0)::numeric(14,2) AS amount
           FROM base
           GROUP BY status
           ORDER BY status ASC`,
          [tenantId, days],
        ),
        db.query(
          `WITH base AS (
             SELECT cc.*,
                    CASE
                      WHEN COALESCE(cc.approved_amount, 0) > 0 THEN cc.approved_amount
                      ELSE cc.requested_amount
                    END::numeric AS effective_amount
             FROM customer_claims cc
             WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
               AND cc.created_at >= now() - make_interval(days => $2::int)
           )
           SELECT to_char(date_trunc('day', created_at), 'YYYY-MM-DD') AS bucket,
                  COUNT(*)::int AS total_claims,
                  COUNT(*) FILTER (WHERE status = 'pending')::int AS pending_claims,
                  COUNT(*) FILTER (WHERE status = 'rejected')::int AS rejected_claims,
                  COALESCE(SUM(effective_amount) FILTER (
                    WHERE status IN ('approved_return', 'approved_discount', 'settled')
                  ), 0)::numeric(14,2) AS approved_sum
           FROM base
           GROUP BY 1
           ORDER BY 1 ASC`,
          [tenantId, days],
        ),
        db.query(
          `WITH base AS (
             SELECT cc.*,
                    CASE
                      WHEN COALESCE(cc.approved_amount, 0) > 0 THEN cc.approved_amount
                      ELSE cc.requested_amount
                    END::numeric AS effective_amount
             FROM customer_claims cc
             WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
               AND cc.created_at >= now() - make_interval(days => $2::int)
           )
           SELECT base.product_id,
                  COALESCE(NULLIF(BTRIM(p.title), ''), 'Товар') AS product_title,
                  COUNT(*)::int AS total_claims,
                  COALESCE(SUM(base.effective_amount) FILTER (
                    WHERE base.status IN ('approved_return', 'approved_discount', 'settled')
                  ), 0)::numeric(14,2) AS approved_sum
           FROM base
           LEFT JOIN products p ON p.id = base.product_id
           GROUP BY base.product_id, p.title
           ORDER BY total_claims DESC, approved_sum DESC
           LIMIT $3::int`,
          [tenantId, days, topProductsLimit],
        ),
      ]);

    const summaryRow = summaryQ.rows[0] || {};
    const byType = byTypeQ.rows.map((row) => ({
      claim_type: row.claim_type,
      claim_type_label: mapClaimTypeLabel(row.claim_type),
      total_claims: Number(row.total_claims || 0),
      pending_claims: Number(row.pending_claims || 0),
      rejected_claims: Number(row.rejected_claims || 0),
      approved_sum: toMoney(row.approved_sum),
    }));
    const byStatus = byStatusQ.rows.map((row) => ({
      status: row.status,
      status_label: mapClaimWorkflowStatus(row.status),
      total_claims: Number(row.total_claims || 0),
      amount: toMoney(row.amount),
    }));
    const byDay = byDayQ.rows.map((row) => ({
      bucket: row.bucket,
      total_claims: Number(row.total_claims || 0),
      pending_claims: Number(row.pending_claims || 0),
      rejected_claims: Number(row.rejected_claims || 0),
      approved_sum: toMoney(row.approved_sum),
    }));
    const topProducts = topProductsQ.rows.map((row) => ({
      product_id: row.product_id,
      product_title: row.product_title,
      total_claims: Number(row.total_claims || 0),
      approved_sum: toMoney(row.approved_sum),
    }));

    const data = {
      period_days: days,
      summary: {
        total_claims: Number(summaryRow.total_claims || 0),
        pending_claims: Number(summaryRow.pending_claims || 0),
        rejected_claims: Number(summaryRow.rejected_claims || 0),
        settled_claims: Number(summaryRow.settled_claims || 0),
        approved_active_claims: Number(summaryRow.approved_active_claims || 0),
        defect_sum: toMoney(summaryRow.defect_sum),
        returns_sum: toMoney(summaryRow.returns_sum),
        discounts_sum: toMoney(summaryRow.discounts_sum),
      },
      by_type: byType,
      by_status: byStatus,
      by_day: byDay,
      top_products: topProducts,
    };

    await insertAuditFromReq(req, {
      action: 'returns.analytics.view',
      entityType: 'customer_claim',
      meta: {
        days,
        top_limit: topProductsLimit,
      },
    });

    return res.json({ ok: true, data });
  } catch (err) {
    console.error('ops.returns.analytics error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get(
  '/returns/workflow',
  requireAuth,
  requireRole('admin', 'creator'),
  requireDeliveryManagePermission,
  async (req, res) => {
  try {
    const status = String(req.query?.status || '').trim();
    const rows = await db.query(
      `SELECT cc.id,
              cc.user_id,
              cc.user_id AS customer_id,
              cc.cart_item_id,
              cc.product_id,
              cc.delivery_batch_id,
              cc.claim_type,
              cc.status,
              cc.description,
              cc.image_url,
              cc.requested_amount,
              cc.approved_amount,
              cc.customer_discount_status,
              cc.resolution_note,
              cc.handled_by,
              cc.handled_at,
              cc.settled_at,
              cc.created_at,
              COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
              COALESCE(NULLIF(BTRIM(u.email), ''), '') AS customer_email,
              COALESCE(NULLIF(BTRIM(pn.phone), ''), '') AS customer_phone,
              p.title AS product_title
       FROM customer_claims cc
       LEFT JOIN users u ON u.id = cc.user_id
       LEFT JOIN phones pn ON pn.user_id = u.id
       LEFT JOIN products p ON p.id = cc.product_id
       WHERE ($1::uuid IS NULL OR cc.tenant_id = $1::uuid)
         AND ($2::text = '' OR cc.status = $2::text)
       ORDER BY cc.created_at DESC
       LIMIT 1000`,
      [req.user?.tenant_id || null, status],
    );

    const data = rows.rows.map((row) => ({
      ...row,
      requested_amount: toMoney(row.requested_amount),
      approved_amount: toMoney(row.approved_amount),
      workflow_status_label: mapClaimWorkflowStatus(
        row.status,
        row.customer_discount_status,
      ),
      available_actions: allowedClaimActions(
        row.status,
        row.customer_discount_status,
      ),
    }));

    return res.json({
      ok: true,
      data,
      workflow: {
        prototype: true,
        description:
          'Прототип workflow: pending -> approved_return/approved_discount/rejected -> settled.',
      },
    });
  } catch (err) {
    console.error('ops.returns.workflow.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post(
  '/returns/workflow/:id/action',
  requireAuth,
  requireRole('admin', 'creator'),
  requireDeliveryManagePermission,
  async (req, res) => {
  try {
    const id = String(req.params?.id || '').trim();
    const action = String(req.body?.action || '').trim();
    const approvedAmountRaw = req.body?.approved_amount;
    const resolutionNote = String(req.body?.resolution_note || '').trim();

    if (!id || !action) {
      return res.status(400).json({ ok: false, error: 'id и action обязательны' });
    }
    if (action === 'reject' && resolutionNote.length < 3) {
      return res.status(400).json({
        ok: false,
        error: 'Укажите причину отказа (минимум 3 символа)',
      });
    }

    const actionMap = {
      approve_return: 'approved_return',
      approve_discount: 'approved_discount',
      reject: 'rejected',
      settle: 'settled',
    };
    const nextStatus = actionMap[action];
    if (!nextStatus) {
      return res.status(400).json({ ok: false, error: 'Некорректное action' });
    }

    const claimQ = await db.query(
      `SELECT id, status, requested_amount, customer_discount_status
       FROM customer_claims
       WHERE id = $1
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
       LIMIT 1`,
      [id, req.user?.tenant_id || null],
    );
    if (claimQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Заявка не найдена' });
    }

    const currentStatus = String(claimQ.rows[0].status || '');
    const currentDiscountDecision = String(
      claimQ.rows[0].customer_discount_status || '',
    ).trim();
    const allowed = allowedClaimActions(currentStatus, currentDiscountDecision);
    if (!allowed.includes(action)) {
      return res.status(400).json({ ok: false, error: 'Переход статуса запрещен' });
    }
    if (
      nextStatus === 'settled' &&
      currentStatus === 'approved_discount' &&
      currentDiscountDecision === 'pending'
    ) {
      return res.status(400).json({
        ok: false,
        error: 'Клиент еще не подтвердил скидку',
      });
    }

    let approvedAmount = toMoney(claimQ.rows[0].requested_amount);
    if (nextStatus === 'approved_discount') {
      const parsed = Number(approvedAmountRaw);
      if (Number.isFinite(parsed) && parsed > 0) {
        approvedAmount = toMoney(parsed);
      }
    }
    const nextDiscountDecision =
      nextStatus === 'approved_discount'
        ? 'pending'
        : nextStatus === 'settled' && currentStatus === 'approved_discount'
          ? currentDiscountDecision || null
          : null;

    const updated = await db.query(
      `UPDATE customer_claims
       SET status = $2,
           approved_amount = CASE
             WHEN $2 = 'approved_discount' THEN $3::numeric(12,2)
             WHEN $2 = 'approved_return' THEN requested_amount
             ELSE approved_amount
           END,
           customer_discount_status = $6::text,
           resolution_note = CASE WHEN NULLIF($4, '') IS NULL THEN resolution_note ELSE $4 END,
           handled_by = $5,
           handled_at = now(),
           settled_at = CASE WHEN $2 = 'settled' THEN now() ELSE NULL END,
           updated_at = now()
       WHERE id = $1
       RETURNING *`,
      [
        id,
        nextStatus,
        approvedAmount,
        resolutionNote,
        req.user?.id || null,
        nextDiscountDecision,
      ],
    );

    await insertAuditFromReq(req, {
      action: 'returns.workflow.action',
      entityType: 'customer_claim',
      entityId: id,
      after: {
        status: updated.rows[0]?.status,
        approved_amount: updated.rows[0]?.approved_amount,
      },
      meta: {
        action,
      },
    });

    const updatedRow = updated.rows[0] || {};
    const io = req.app.get('io');
    if (io && updatedRow.id) {
      const payload = {
        reason: 'claim_updated',
        claim_id: String(updatedRow.id),
        user_id: String(updatedRow.user_id || ''),
        status: String(updatedRow.status || ''),
        claim_type: String(updatedRow.claim_type || ''),
        approved_amount: toMoney(updatedRow.approved_amount),
        requested_amount: toMoney(updatedRow.requested_amount),
        updated_at: updatedRow.updated_at || null,
      };
      emitToTenant(
        io,
        updatedRow.tenant_id || req.user?.tenant_id || null,
        'claims:updated',
        payload,
      );
      if (updatedRow.user_id) {
        io.to(`user:${updatedRow.user_id}`).emit('claims:updated', payload);
        io.to(`user:${updatedRow.user_id}`).emit('cart:updated', {
          userId: String(updatedRow.user_id),
          reason: 'claim_updated',
          claim_id: String(updatedRow.id),
        });
      }
    }

    return res.json({
      ok: true,
      data: {
        ...updatedRow,
        requested_amount: toMoney(updatedRow.requested_amount),
        approved_amount: toMoney(updatedRow.approved_amount),
      },
    });
  } catch (err) {
    console.error('ops.returns.workflow.action error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

async function fetchBatchRows(batchId, tenantId) {
  const batchQ = await db.query(
    `SELECT b.id,
            b.delivery_date,
            b.delivery_label,
            b.status,
            b.courier_names
     FROM delivery_batches b
     WHERE b.id = $1
       AND (
         $2::uuid IS NULL
         OR EXISTS (
           SELECT 1
           FROM delivery_batch_customers c
           JOIN users u ON u.id = c.user_id
           WHERE c.batch_id = b.id
             AND u.tenant_id = $2::uuid
         )
       )
     LIMIT 1`,
    [batchId, tenantId || null],
  );
  if (batchQ.rowCount === 0) return null;

  const customersQ = await db.query(
    `SELECT c.id,
            c.user_id,
            c.customer_name,
            c.customer_phone,
            c.address_text,
            c.courier_name,
            c.courier_code,
            c.route_order,
            c.processed_sum,
            c.agreed_sum,
            c.package_places,
            c.bulky_places,
            c.bulky_note,
            c.shelf_number,
            c.preferred_time_from,
            c.preferred_time_to,
            c.delivery_status,
            c.call_status
     FROM delivery_batch_customers c
     JOIN users u ON u.id = c.user_id
     WHERE c.batch_id = $1
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
     ORDER BY COALESCE(c.courier_name, ''), c.route_order ASC NULLS LAST, c.customer_name ASC`,
    [batchId, tenantId || null],
  );

  const itemsQ = await db.query(
    `SELECT i.batch_customer_id,
            i.product_title,
            i.product_description,
            i.product_code,
            i.quantity,
            i.unit_price,
            i.line_total
     FROM delivery_batch_items i
     WHERE i.batch_id = $1
     ORDER BY i.batch_customer_id, i.product_title`,
    [batchId],
  );

  const itemsByCustomer = new Map();
  for (const row of itemsQ.rows) {
    const key = String(row.batch_customer_id || '');
    if (!itemsByCustomer.has(key)) itemsByCustomer.set(key, []);
    itemsByCustomer.get(key).push(row);
  }

  const customers = customersQ.rows.map((row) => ({
    ...row,
    processed_sum: toMoney(row.processed_sum),
    agreed_sum: toMoney(row.agreed_sum),
    items: itemsByCustomer.get(String(row.id || '')) || [],
  }));

  return {
    batch: batchQ.rows[0],
    customers,
  };
}

async function registerGeneratedDocument({ tenantId, userId, kind, batchId = null, fileName = null, meta = {} }) {
  try {
    await db.query(
      `INSERT INTO generated_documents (
         tenant_id,
         generated_by,
         kind,
         batch_id,
         file_name,
         meta,
         created_at
       )
       VALUES ($1, $2, $3, $4, NULLIF($5, ''), $6::jsonb, now())`,
      [tenantId || null, userId || null, kind, batchId || null, fileName || '', JSON.stringify(meta || {})],
    );
  } catch (err) {
    console.error('ops.documents.register error', err);
  }
}

function buildRouteSheetWorkbook(batchData) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Маршрутный лист');

  ws.columns = [
    { header: 'Маршрут', key: 'route_order', width: 10 },
    { header: 'Курьер', key: 'courier', width: 12 },
    { header: 'Клиент', key: 'customer', width: 24 },
    { header: 'Телефон', key: 'phone', width: 16 },
    { header: 'Адрес', key: 'address', width: 44 },
    { header: 'Сумма', key: 'sum', width: 12 },
    { header: 'Мест', key: 'places', width: 8 },
    { header: 'Полка', key: 'shelf', width: 10 },
    { header: 'Габарит', key: 'bulky', width: 20 },
  ];

  for (const customer of batchData.customers) {
    const bulky = Number(customer.bulky_places || 0) > 0
      ? `${customer.bulky_places}${customer.bulky_note ? ` (${customer.bulky_note})` : ''}`
      : '';
    ws.addRow({
      route_order: customer.route_order || '',
      courier: customer.courier_code || customer.courier_name || '',
      customer: customer.customer_name || '',
      phone: customer.customer_phone || '',
      address: customer.address_text || '',
      sum: toMoney(customer.agreed_sum || customer.processed_sum),
      places: customer.package_places || 1,
      shelf: customer.shelf_number || '',
      bulky,
    });
  }

  ws.getRow(1).font = { bold: true };
  ws.views = [{ state: 'frozen', ySplit: 1 }];
  return wb;
}

function buildPackingWorkbook(batchData) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Чек-лист сборки');
  ws.columns = [
    { header: 'Клиент', key: 'customer', width: 24 },
    { header: 'Телефон', key: 'phone', width: 16 },
    { header: 'Полка', key: 'shelf', width: 10 },
    { header: 'Товар', key: 'product', width: 32 },
    { header: 'ID', key: 'code', width: 10 },
    { header: 'Кол-во', key: 'qty', width: 8 },
    { header: 'Цена', key: 'price', width: 12 },
    { header: 'Итого', key: 'line', width: 12 },
  ];

  for (const customer of batchData.customers) {
    const items = Array.isArray(customer.items) ? customer.items : [];
    if (items.length === 0) {
      ws.addRow({
        customer: customer.customer_name || '',
        phone: customer.customer_phone || '',
        shelf: customer.shelf_number || '',
        product: '—',
      });
      continue;
    }
    for (const item of items) {
      ws.addRow({
        customer: customer.customer_name || '',
        phone: customer.customer_phone || '',
        shelf: customer.shelf_number || '',
        product: item.product_title || '',
        code: item.product_code || '',
        qty: item.quantity || 0,
        price: toMoney(item.unit_price),
        line: toMoney(item.line_total),
      });
    }
  }

  ws.getRow(1).font = { bold: true };
  ws.views = [{ state: 'frozen', ySplit: 1 }];
  return wb;
}

function buildRouteSheetPdfBuffer(batchData) {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ margin: 32, size: 'A4' });
    const chunks = [];
    doc.on('data', (chunk) => chunks.push(chunk));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    doc.fontSize(16).text('Проект Феникс — Маршрутный лист', { underline: true });
    doc.moveDown(0.6);
    doc.fontSize(11).text(`Дата: ${String(batchData.batch.delivery_date || '')}`);
    doc.text(`Лист: ${String(batchData.batch.delivery_label || '')}`);
    doc.text(`Статус: ${String(batchData.batch.status || '')}`);
    doc.moveDown(0.8);

    for (const customer of batchData.customers) {
      doc.fontSize(10).text(
        `${customer.route_order || '-'} | ${customer.courier_code || customer.courier_name || '-'} | ${customer.customer_name || 'Клиент'} | ${customer.customer_phone || '-'} | ${customer.address_text || '-'} | ${toMoney(customer.agreed_sum || customer.processed_sum)} ₽`,
      );
      doc.moveDown(0.2);
      if (doc.y > 760) {
        doc.addPage();
      }
    }

    doc.end();
  });
}

router.get(
  '/documents/export',
  requireAuth,
  requireRole('admin', 'creator'),
  requireDeliveryManagePermission,
  async (req, res) => {
  try {
    const kind = String(req.query?.kind || '').trim();
    const format = String(req.query?.format || 'excel').toLowerCase().trim();
    const batchId = String(req.query?.batch_id || '').trim();

    const supportedKinds = new Set(['route_sheet', 'packing_checklist', 'finance_summary']);
    if (!supportedKinds.has(kind)) {
      return res.status(400).json({ ok: false, error: 'Некорректный kind' });
    }
    if (!['excel', 'pdf'].includes(format)) {
      return res.status(400).json({ ok: false, error: 'format должен быть excel или pdf' });
    }

    if (kind === 'finance_summary') {
      const data = await getFinanceSummary({
        tenantId: req.user?.tenant_id || null,
        period: 'month',
      });
      const wb = new ExcelJS.Workbook();
      const ws = wb.addWorksheet('Финансы');
      ws.columns = [
        { header: 'Метрика', key: 'metric', width: 28 },
        { header: 'Значение', key: 'value', width: 20 },
      ];
      ws.addRow({ metric: 'Выручка', value: data.summary.revenue });
      ws.addRow({ metric: 'Себестоимость', value: data.summary.cost });
      ws.addRow({ metric: 'Маржа', value: data.summary.margin });
      ws.addRow({ metric: 'Прибыль', value: data.summary.profit });
      ws.addRow({ metric: 'Средний чек', value: data.summary.avg_check });
      ws.getRow(1).font = { bold: true };

      const buffer = await wb.xlsx.writeBuffer();
      const fileName = `finance_summary_${new Date().toISOString().slice(0, 10)}.xlsx`;
      await registerGeneratedDocument({
        tenantId: req.user?.tenant_id || null,
        userId: req.user?.id || null,
        kind: 'finance_summary',
        fileName,
        meta: { period: 'month' },
      });
      res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
      return res.send(Buffer.from(buffer));
    }

    if (!batchId) {
      return res.status(400).json({ ok: false, error: 'batch_id обязателен' });
    }

    const batchData = await fetchBatchRows(batchId, req.user?.tenant_id || null);
    if (!batchData) {
      return res.status(404).json({ ok: false, error: 'Лист доставки не найден' });
    }

    if (format === 'excel') {
      const wb = kind === 'route_sheet'
        ? buildRouteSheetWorkbook(batchData)
        : buildPackingWorkbook(batchData);
      const buffer = await wb.xlsx.writeBuffer();
      const suffix = kind === 'route_sheet' ? 'route' : 'packing';
      const fileName = `${suffix}_${String(batchData.batch.delivery_date || '').slice(0, 10)}.xlsx`;
      await registerGeneratedDocument({
        tenantId: req.user?.tenant_id || null,
        userId: req.user?.id || null,
        kind: kind === 'route_sheet' ? 'route_sheet' : 'packing_checklist',
        batchId,
        fileName,
      });

      res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
      return res.send(Buffer.from(buffer));
    }

    const pdfBuffer = await buildRouteSheetPdfBuffer(batchData);
    const fileName = `route_${String(batchData.batch.delivery_date || '').slice(0, 10)}.pdf`;
    await registerGeneratedDocument({
      tenantId: req.user?.tenant_id || null,
      userId: req.user?.id || null,
      kind: 'route_sheet',
      batchId,
      fileName,
      meta: { format: 'pdf' },
    });

    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
    return res.send(pdfBuffer);
  } catch (err) {
    console.error('ops.documents.export error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

async function allocateProductCode(client, tenantId = null) {
  await client.query("LOCK TABLE products IN SHARE ROW EXCLUSIVE MODE");

  const reusable = await client.query(
    `SELECT p.id, p.product_code, p.reusable_at
     FROM products p
     WHERE p.status = 'archived'
       AND p.reusable_at IS NOT NULL
       AND p.reusable_at <= now()
       AND p.product_code IS NOT NULL
       AND p.product_code > 0
       AND (
         EXISTS (
           SELECT 1
           FROM product_publication_queue q
           JOIN chats c ON c.id = q.channel_id
           WHERE q.product_id = p.id
             AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
         )
         OR EXISTS (
           SELECT 1
           FROM users u
           WHERE u.id = p.created_by
             AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
         )
       )
     ORDER BY p.product_code ASC, p.reusable_at ASC
     FOR UPDATE OF p`,
    [tenantId || null],
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

  const result = await client.query(
    `WITH used AS (
       SELECT DISTINCT p.product_code
       FROM products p
       WHERE p.product_code IS NOT NULL
         AND p.product_code > 0
         AND NOT (p.product_code = ANY($2::int[]))
         AND (
           EXISTS (
             SELECT 1
             FROM product_publication_queue q
             JOIN chats c ON c.id = q.channel_id
             WHERE q.product_id = p.id
              AND ($1::uuid IS NULL OR c.tenant_id = $1::uuid)
           )
           OR EXISTS (
             SELECT 1
             FROM users u
             WHERE u.id = p.created_by
               AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
           )
         )
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
    [tenantId || null, reusableCodes],
  );
  const nextCode = Number(result.rows[0]?.next_code || 1);
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

async function ensureDemoUsers(client, {
  tenantId,
  tenantCode,
  count,
}) {
  const users = [];
  for (let i = 1; i <= count; i += 1) {
    const email = `demo.client.${tenantCode || 'tenant'}.${i}@fenix.local`;
    const name = `Демо клиент ${i}`;
    const passwordHash = '$2b$10$z7dN5Vuj4OVwOB1p5MNDOe4Qw7P3R6Y1V0M8T7bQq3z9g8dY7q0iS';

    const inserted = await client.query(
      `INSERT INTO users (id, email, password_hash, role, name, is_active, tenant_id, created_at)
       VALUES (gen_random_uuid(), $1, $2, 'client', $3, true, $4, now())
       ON CONFLICT (email) DO UPDATE
         SET tenant_id = EXCLUDED.tenant_id,
             role = 'client',
             name = COALESCE(NULLIF(users.name, ''), EXCLUDED.name)
       RETURNING id, email, name`,
      [email, passwordHash, name, tenantId || null],
    );

    const row = inserted.rows[0];
    users.push(row);

    const phone = `79${String(900000000 + i).slice(0, 9)}`;
    await client.query(
      `INSERT INTO phones (id, user_id, phone, status, created_at, verified_at)
       VALUES (gen_random_uuid(), $1, $2, 'verified', now(), now())
       ON CONFLICT (user_id) DO UPDATE
         SET phone = EXCLUDED.phone,
             status = 'verified',
             verified_at = now(),
             created_at = now()`,
      [row.id, phone],
    );
  }
  return users;
}

router.post('/demo-mode/seed', requireAuth, requireRole('creator'), async (req, res) => {
  if (!isCreatorBase(req.user)) {
    return res.status(403).json({ ok: false, error: 'Доступ только создателю' });
  }

  const demoClients = parsePositiveInt(req.body?.clients, 12, 2, 100);
  const demoProducts = parsePositiveInt(req.body?.products, 20, 2, 120);

  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');

    const tenantCode = String(req.user?.tenant_code || 'default').toLowerCase();
    const ensured = await ensureSystemChannels(client, req.user?.id || null, req.user?.tenant_id || null);
    const mainChannelId = ensured.mainChannel.id;

    const users = await ensureDemoUsers(client, {
      tenantId: req.user?.tenant_id || null,
      tenantCode,
      count: demoClients,
    });

    const createdProducts = [];
    for (let i = 0; i < demoProducts; i += 1) {
      const productCode = await allocateProductCode(
        client,
        req.user?.tenant_id || null,
      );
      const shelf = (i % 10) + 1;
      const price = (Math.floor(Math.random() * 10) + 2) * 50;
      const costPrice = Math.max(50, Math.floor(price * 0.62));
      const quantity = Math.floor(Math.random() * 4) + 1;

      const productIns = await client.query(
        `INSERT INTO products (
           id,
           product_code,
           shelf_number,
           title,
           description,
           price,
           cost_price,
           quantity,
           image_url,
           created_by,
           status,
           created_at,
           updated_at
         )
         VALUES (
           gen_random_uuid(),
           $1,
           $2,
           $3,
           $4,
           $5,
           $6,
           $7,
           NULL,
           $8,
           'draft',
           now(),
           now()
         )
         RETURNING id, product_code, shelf_number`,
        [
          productCode,
          shelf,
          `Демо товар ${productCode}`,
          `Авто-генерация демо-режима #${productCode}`,
          price,
          costPrice,
          quantity,
          req.user?.id || null,
        ],
      );

      const product = productIns.rows[0];
      createdProducts.push(product);

      await client.query(
        `INSERT INTO product_publication_queue (
           id,
           product_id,
           channel_id,
           queued_by,
           status,
           payload,
           created_at
         )
         VALUES (gen_random_uuid(), $1, $2, $3, 'pending', '{}'::jsonb, now())`,
        [product.id, mainChannelId, req.user?.id || null],
      );
    }

    let demoCartItems = 0;
    for (let i = 0; i < users.length; i += 1) {
      const user = users[i];
      const product = createdProducts[i % createdProducts.length];
      await client.query(
        `WITH target AS (
           SELECT id
           FROM cart_items
           WHERE user_id = $1
             AND product_id = $2
             AND status = 'processed'
           ORDER BY updated_at DESC NULLS LAST, created_at DESC
           LIMIT 1
           FOR UPDATE
         ),
         updated AS (
           UPDATE cart_items c
           SET quantity = c.quantity + $3,
               updated_at = now()
           WHERE c.id IN (SELECT id FROM target)
           RETURNING c.id
         )
         INSERT INTO cart_items (
           id,
           user_id,
           product_id,
           quantity,
           status,
           created_at,
           updated_at
         )
         SELECT gen_random_uuid(), $1, $2, $3, 'processed', now(), now()
         WHERE NOT EXISTS (SELECT 1 FROM updated)`,
        [user.id, product.id, (i % 3) + 1],
      );
      demoCartItems += 1;
    }

    await client.query('COMMIT');

    await insertAuditFromReq(req, {
      action: 'demo_mode.seed',
      entityType: 'demo_mode',
      meta: {
        clients: users.length,
        products: createdProducts.length,
        queued_posts: createdProducts.length,
        demo_cart_items: demoCartItems,
      },
    });

    await logMonitoringEvent({
      queryable: db,
      tenantId: req.user?.tenant_id || null,
      userId: req.user?.id || null,
      scope: 'demo',
      level: 'info',
      code: 'demo_mode_seeded',
      source: 'ops.demo-mode.seed',
      message: 'Демо-режим заполнен тестовыми данными',
      details: {
        clients: users.length,
        products: createdProducts.length,
      },
    });

    return res.json({
      ok: true,
      data: {
        clients_created_or_reused: users.length,
        products_queued: createdProducts.length,
        demo_cart_items: demoCartItems,
        channel_id: mainChannelId,
        next_step: 'Нажмите "Отправить посты на канал" в модерации.',
      },
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('ops.demoMode.seed error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

module.exports = router;
