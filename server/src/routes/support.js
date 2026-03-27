const express = require("express");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const db = require("../db");
const { authMiddleware } = require("../utils/auth");
const { requireRole } = require("../utils/roles");
const { emitToTenant } = require("../utils/socket");
const { createRateGuard } = require("../utils/rateGuard");
const { buildSupportTemplateAutoReply } = require("../utils/supportAutoReply");
const {
  encryptMessageText,
  decryptMessageRow,
} = require("../utils/messageCrypto");

const TICKET_STATUSES = new Set([
  "open",
  "waiting_customer",
  "resolved",
  "archived",
]);

const STAFF_ROLES = new Set(["worker", "admin", "tenant", "creator"]);

const supportAskRateGuard = createRateGuard({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_SUPPORT_ASK_MAX || 18),
  blockMs: 45 * 1000,
  message: "Слишком много сообщений в поддержку. Повторите немного позже.",
  keyResolver: (req) =>
    [req.ip || "", req.user?.tenant_id || "", req.user?.id || "", "support-ask"].join(
      "|",
    ),
});

const supportBugRateGuard = createRateGuard({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_BUG_REPORT_MAX || 8),
  blockMs: 60 * 1000,
  message: "Слишком много баг-репортов за минуту. Попробуйте позже.",
  keyResolver: (req) =>
    [req.ip || "", req.user?.tenant_id || "", req.user?.id || "", "support-bug"].join(
      "|",
    ),
});

function normalizeRole(raw) {
  return String(raw || "")
    .toLowerCase()
    .trim();
}

function isStaffRole(rawRole) {
  return STAFF_ROLES.has(normalizeRole(rawRole));
}

function isAdminTierRole(rawRole) {
  const role = normalizeRole(rawRole);
  return role === "admin" || role === "tenant" || role === "creator";
}

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function toMoney(value) {
  const parsed = Number(value || 0);
  if (!Number.isFinite(parsed)) return 0;
  return Number(parsed.toFixed(2));
}

function buildCartSummaryReply(total, processed, claimsTotal) {
  return `Общая сумма вашей корзины: ${total} ₽. Обработано на сумму: ${processed} ₽. Сумма брака: ${claimsTotal} ₽.`;
}

function normalizeText(value) {
  return String(value || "").trim();
}

function isCartSummaryQuestion(message) {
  const normalized = normalizeText(message).toLowerCase();
  if (!normalized) return false;
  return normalized.includes("сум") && normalized.includes("корз");
}

function inferSupportCategory(message) {
  const normalized = normalizeText(message).toLowerCase();
  if (!normalized) return "general";
  if (normalized.includes("достав") || normalized.includes("курьер") || normalized.includes("адрес")) {
    return "delivery";
  }
  if (
    normalized.includes("товар") ||
    normalized.includes("фото") ||
    normalized.includes("брак") ||
    normalized.includes("описан") ||
    normalized.includes("цена")
  ) {
    return "product";
  }
  if (normalized.includes("корз") || normalized.includes("сум") || normalized.includes("оплат")) {
    return "cart";
  }
  return "general";
}

function parseTicketStatuses(rawStatuses) {
  const values = String(rawStatuses || "")
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
  const unique = [];
  for (const value of values) {
    if (!TICKET_STATUSES.has(value)) continue;
    if (!unique.includes(value)) unique.push(value);
  }
  return unique;
}

async function hydrateMessageById(messageId, currentUserId = null) {
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
  return decryptMessageRow(result.rows[0] || null);
}

async function emitChatMessage(req, tenantId, chatId, messageId) {
  const io = req.app.get("io");
  if (!io || !messageId) return;

  const message = await hydrateMessageById(messageId, null);
  if (!message) return;

  io.to(`chat:${chatId}`).emit("chat:message", {
    chatId,
    message,
  });
  emitToTenant(io, tenantId || null, "chat:updated", { chatId });
}

async function emitChatCreated(req, tenantId, chat) {
  const io = req.app.get("io");
  if (!io || !chat?.id) return;
  emitToTenant(io, tenantId || null, "chat:created", {
    chatId: chat.id,
    chat,
  });
  emitToTenant(io, tenantId || null, "chat:updated", {
    chatId: chat.id,
    chat,
  });
}

async function insertSupportMessage(client, { chatId, senderId = null, text, meta = {} }) {
  const plainText = String(text || "");
  const encryptedText = encryptMessageText(plainText);
  const inserted = await client.query(
    `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
     VALUES ($1, $2, $3, $4, $5::jsonb, now())
     RETURNING id, chat_id, sender_id, text, meta, created_at`,
    [uuidv4(), chatId, senderId, encryptedText, JSON.stringify(meta || {})],
  );
  await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [chatId]);
  return {
    ...inserted.rows[0],
    text: plainText,
  };
}

async function ensureSupportMembers(
  client,
  {
    chatId,
    customerId,
    assigneeId,
    tenantId = null,
  },
) {
  const allowedIds = Array.from(
    new Set(
      [String(customerId || "").trim(), String(assigneeId || "").trim()].filter(Boolean),
    ),
  );

  await client.query(
    `DELETE FROM chat_members
     WHERE chat_id = $1
       AND NOT (user_id = ANY($2::uuid[]))`,
    [chatId, allowedIds],
  );

  await client.query(
    `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
     VALUES ($1, $2, $3, now(), 'member')
     ON CONFLICT (chat_id, user_id) DO UPDATE SET role = 'member'`,
    [uuidv4(), chatId, customerId],
  );

  if (assigneeId) {
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), 'moderator')
       ON CONFLICT (chat_id, user_id) DO UPDATE SET role = 'moderator'`,
      [uuidv4(), chatId, assigneeId],
    );
  }
}

async function resolveProductCandidate(client, { tenantId = null, messageText }) {
  const text = normalizeText(messageText);
  if (!text) return null;
  const queryText = `%${text.split(/\s+/).slice(0, 6).join(" ")}%`;
  const productRes = await client.query(
    `SELECT p.id,
            p.title,
            p.created_by
     FROM products p
     LEFT JOIN users u ON u.id = p.created_by
     WHERE (p.title ILIKE $1 OR p.description ILIKE $1)
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
     ORDER BY p.updated_at DESC NULLS LAST, p.created_at DESC
     LIMIT 1`,
    [queryText, tenantId || null],
  );
  if (productRes.rowCount === 0) return null;
  return productRes.rows[0];
}

async function resolveAssignee(
  client,
  {
    tenantId = null,
    preferredUserId = null,
    preferWorker = false,
  },
) {
  if (preferredUserId) {
    const preferred = await client.query(
      `SELECT id, role, name, email
       FROM users
       WHERE id = $1
         AND is_active = true
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
       LIMIT 1`,
      [preferredUserId, tenantId || null],
    );
    if (preferred.rowCount > 0 && isStaffRole(preferred.rows[0].role)) {
      return preferred.rows[0];
    }
  }

  const roleOrder = preferWorker
    ? ["worker", "admin", "tenant", "creator"]
    : ["admin", "tenant", "creator", "worker"];

  for (const role of roleOrder) {
    const result = await client.query(
      `SELECT id, role, name, email
       FROM users
       WHERE role = $1
         AND is_active = true
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
       ORDER BY updated_at DESC NULLS LAST, created_at ASC
       LIMIT 1`,
      [role, tenantId || null],
    );
    if (result.rowCount > 0) return result.rows[0];
  }

  return null;
}

async function openOrReuseSupportTicket(client, user, messageText) {
  const tenantId = user.tenant_id || null;
  const category = inferSupportCategory(messageText);

  let product = null;
  if (category === "product") {
    product = await resolveProductCandidate(client, {
      tenantId,
      messageText,
    });
  }

  const assignee = await resolveAssignee(client, {
    tenantId,
    preferredUserId: product?.created_by || null,
    preferWorker: category === "product",
  });

  const existingRes = await client.query(
    `SELECT st.*,
            c.title AS chat_title,
            c.type AS chat_type,
            c.settings AS chat_settings
     FROM support_tickets st
     JOIN chats c ON c.id = st.chat_id
     WHERE st.customer_id = $1
       AND st.category = $2
       AND st.status IN ('open', 'waiting_customer', 'resolved')
       AND ($3::uuid IS NULL OR st.tenant_id = $3::uuid)
     ORDER BY st.updated_at DESC
     LIMIT 1
     FOR UPDATE`,
    [user.id, category, tenantId],
  );

  let chatId;
  let ticketId;
  let chatRecord;
  let createdChat = false;
  let createdTicket = false;
  let ticketSubject = "";

  if (existingRes.rowCount > 0) {
    const row = existingRes.rows[0];
    chatId = row.chat_id;
    ticketId = row.id;
    ticketSubject = String(row.subject || "");

    await client.query(
      `UPDATE support_tickets
       SET assignee_id = COALESCE($1::uuid, assignee_id),
           assigned_role = COALESCE($2, assigned_role),
           product_id = COALESCE($3::uuid, product_id),
           status = 'open',
           archived_at = NULL,
           archive_reason = NULL,
           resolved_at = NULL,
           resolved_by = NULL,
           last_customer_message_at = now(),
           updated_at = now()
       WHERE id = $4`,
      [
        assignee?.id || null,
        normalizeRole(assignee?.role || "") || null,
        product?.id || null,
        ticketId,
      ],
    );

    await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [chatId]);

    chatRecord = {
      id: chatId,
      title: row.chat_title,
      type: row.chat_type,
      settings: normalizeSettings(row.chat_settings),
      updated_at: new Date().toISOString(),
    };
  } else {
    chatId = uuidv4();
    ticketId = uuidv4();
    const settings = {
      kind: "support_ticket",
      support_ticket: true,
      support_ticket_id: ticketId,
      visibility: "private",
      category,
      description: "Диалог поддержки",
    };

    const createdChatRes = await client.query(
      `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
       VALUES ($1, $2, 'private', $3, $4, $5::jsonb, now(), now())
       RETURNING id, title, type, settings, created_at, updated_at`,
      [chatId, "Поддержка", user.id, tenantId, JSON.stringify(settings)],
    );

    ticketSubject =
      category === "product"
        ? "Вопрос по товару"
        : category === "delivery"
        ? "Вопрос по доставке"
        : category === "cart"
        ? "Вопрос по корзине"
        : "Общий вопрос";

    await client.query(
      `INSERT INTO support_tickets (
        id,
        tenant_id,
        chat_id,
        customer_id,
        assignee_id,
        assigned_role,
        category,
        subject,
        product_id,
        status,
        last_customer_message_at,
        created_at,
        updated_at
      )
      VALUES (
        $1,
        $2,
        $3,
        $4,
        $5,
        $6,
        $7,
        $8,
        $9,
        'open',
        now(),
        now(),
        now()
      )`,
      [
        ticketId,
        tenantId,
        chatId,
        user.id,
        assignee?.id || null,
        normalizeRole(assignee?.role || "admin") || "admin",
        category,
        ticketSubject,
        product?.id || null,
      ],
    );

    chatRecord = createdChatRes.rows[0];
    createdChat = true;
    createdTicket = true;
  }

  await ensureSupportMembers(client, {
    chatId,
    customerId: user.id,
    assigneeId: assignee?.id || null,
    tenantId,
  });

  const customerMeta = {
    kind: "support_customer_message",
    support_ticket_id: ticketId,
    support_category: category,
    product_id: product?.id || null,
    product_title: product?.title || null,
  };

  const customerMessage = await insertSupportMessage(client, {
    chatId,
    senderId: user.id,
    text: messageText,
    meta: customerMeta,
  });

  let autoReplyMessage = null;
  const autoReply = await buildSupportTemplateAutoReply(client, {
    tenantId,
    category,
    customerId: user.id,
    subject: ticketSubject,
    messageText,
  });
  if (autoReply?.text) {
    autoReplyMessage = await insertSupportMessage(client, {
      chatId,
      senderId: null,
      text: autoReply.text,
      meta: {
        kind: "support_bot_template_reply",
        support_ticket_id: ticketId,
        support_category: category,
        template_id: autoReply.template.id,
        template_title: autoReply.template.title,
        trigger_rule: autoReply.template.trigger_rule,
      },
    });
  }

  let introMessage = null;
  if (createdTicket && !autoReplyMessage) {
    const assigneeName = normalizeText(assignee?.name || assignee?.email || "");
    const intro = assigneeName
      ? `Ваш вопрос принят. Ответственный: ${assigneeName}.`
      : "Ваш вопрос принят. Ответим в этом чате.";
    introMessage = await insertSupportMessage(client, {
      chatId,
      senderId: null,
      text: intro,
      meta: {
        kind: "support_ticket_intro",
        support_ticket_id: ticketId,
        support_category: category,
      },
    });
  }

  const ticketRes = await client.query(
    `SELECT st.id,
            st.chat_id,
            st.customer_id,
            st.assignee_id,
            st.assigned_role,
            st.category,
            st.subject,
            st.product_id,
            st.status,
            st.created_at,
            st.updated_at,
            COALESCE(NULLIF(BTRIM(cu.name), ''), NULLIF(BTRIM(cu.email), ''), 'Клиент') AS customer_name,
            COALESCE(NULLIF(BTRIM(au.name), ''), NULLIF(BTRIM(au.email), ''), '—') AS assignee_name
     FROM support_tickets st
     LEFT JOIN users cu ON cu.id = st.customer_id
     LEFT JOIN users au ON au.id = st.assignee_id
     WHERE st.id = $1
     LIMIT 1`,
    [ticketId],
  );

  return {
    ticket: ticketRes.rowCount > 0 ? ticketRes.rows[0] : null,
    chat: chatRecord,
    category,
    assignee,
    createdChat,
    createdTicket,
    customerMessage,
    autoReplyMessage,
    introMessage,
  };
}

async function computeCartSummary(userId) {
  const cartRows = await db.query(
    `SELECT c.status, c.quantity, p.price
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     WHERE c.user_id = $1
       AND c.status IN ('pending_processing', 'processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery')`,
    [userId],
  );
  const claimsRows = await db.query(
    `SELECT COALESCE(SUM(approved_amount), 0)::numeric AS claims_total
     FROM customer_claims
     WHERE user_id = $1
       AND status IN ('approved_return', 'approved_discount', 'settled')`,
    [userId],
  );

  let total = 0;
  let processed = 0;

  for (const row of cartRows.rows) {
    const line = Number(row.price || 0) * Number(row.quantity || 0);
    if (!Number.isFinite(line)) continue;
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

  const claimsTotal = toMoney(claimsRows.rows[0]?.claims_total);
  const adjustedTotal = Math.max(0, toMoney(total - claimsTotal));
  const adjustedProcessed = Math.max(0, toMoney(processed - claimsTotal));
  return {
    total: adjustedTotal,
    processed: adjustedProcessed,
    claims_total: claimsTotal,
  };
}

async function ensureBugReportsChannel(client, createdBy, tenantId = null) {
  const existing = await client.query(
    `SELECT id, title, type, settings, created_at, updated_at
     FROM chats
     WHERE type = 'channel'
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
       AND (
         COALESCE(settings->>'kind', '') = 'bug_reports'
         OR LOWER(TRIM(title)) = LOWER(TRIM($1))
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'kind', '') = 'bug_reports' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    ["Баг-репорты", tenantId || null],
  );

  if (existing.rowCount > 0) {
    const current = existing.rows[0];
    const currentSettings = normalizeSettings(current.settings);
    const nextSettings = {
      ...currentSettings,
      kind: "bug_reports",
      visibility: "private",
      admin_only: true,
      worker_can_post: false,
      is_post_channel: false,
      description:
        currentSettings.description || "Служебный канал баг-репортов",
    };

    const updated = await client.query(
      `UPDATE chats
       SET title = $1,
           settings = $2::jsonb,
           updated_at = now()
       WHERE id = $3
       RETURNING id, title, type, settings, created_at, updated_at`,
      ["Баг-репорты", JSON.stringify(nextSettings), current.id],
    );
    return { channel: updated.rows[0], created: false };
  }

  const settings = {
    kind: "bug_reports",
    visibility: "private",
    admin_only: true,
    worker_can_post: false,
    is_post_channel: false,
    description: "Служебный канал баг-репортов",
  };

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, $2, 'channel', $3, $4, $5::jsonb, now(), now())
     RETURNING id, title, type, settings, created_at, updated_at`,
    [
      uuidv4(),
      "Баг-репорты",
      createdBy || null,
      tenantId || null,
      JSON.stringify(settings),
    ],
  );

  return { channel: inserted.rows[0], created: true };
}

async function ensureAdminCreatorMembers(client, chatId, tenantId = null) {
  await client.query(
    `DELETE FROM chat_members cm
     USING users u
     WHERE cm.chat_id = $1
       AND cm.user_id = u.id
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
       AND u.role NOT IN ('admin', 'tenant', 'creator')`,
    [chatId, tenantId || null],
  );

  const staff = await client.query(
    `SELECT id, role
     FROM users
     WHERE role IN ('admin', 'tenant', 'creator')
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)`,
    [tenantId || null],
  );

  for (const user of staff.rows) {
    const normalizedRole = normalizeRole(user.role);
    const role = normalizedRole === "creator" ? "owner" : "moderator";
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), $4)
       ON CONFLICT (chat_id, user_id) DO UPDATE
       SET role = EXCLUDED.role`,
      [uuidv4(), chatId, user.id, role],
    );
  }
}

router.post("/ask", authMiddleware, supportAskRateGuard, async (req, res) => {
  const message = normalizeText(req.body?.message);
  if (!message) {
    return res.status(400).json({ ok: false, error: "Введите вопрос" });
  }

  try {
    if (isCartSummaryQuestion(message)) {
      const sums = await computeCartSummary(req.user.id);
      return res.json({
        ok: true,
        data: {
          mode: "quick_reply",
          source: "cart_summary",
          reply: buildCartSummaryReply(sums.total, sums.processed, sums.claims_total),
          totals: {
            cart_total: sums.total,
            processed_total: sums.processed,
            claims_total: sums.claims_total,
          },
        },
      });
    }

    const client = await db.pool.connect();
    let result;
    try {
      await client.query("BEGIN");
      result = await openOrReuseSupportTicket(client, req.user, message);
      await client.query("COMMIT");
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }

    if (result.createdChat) {
      await emitChatCreated(req, req.user.tenant_id || null, result.chat);
    }

    if (result.customerMessage?.id) {
      await emitChatMessage(
        req,
        req.user.tenant_id || null,
        result.customerMessage.chat_id,
        result.customerMessage.id,
      );
    }

    if (result.introMessage?.id) {
      await emitChatMessage(
        req,
        req.user.tenant_id || null,
        result.introMessage.chat_id,
        result.introMessage.id,
      );
    }
    if (result.autoReplyMessage?.id) {
      await emitChatMessage(
        req,
        req.user.tenant_id || null,
        result.autoReplyMessage.chat_id,
        result.autoReplyMessage.id,
      );
    }

    const autoReplyText = normalizeText(result.autoReplyMessage?.text || "");
    if (autoReplyText) {
      return res.status(201).json({
        ok: true,
        data: {
          mode: "quick_reply",
          reply: autoReplyText,
          source: "template_auto_reply",
          chat_id: result.chat?.id || result.ticket?.chat_id || null,
          chat_title: result.chat?.title || "Поддержка",
          ticket: result.ticket,
        },
      });
    }

    const assigneeName = normalizeText(
      result.ticket?.assignee_name || result.assignee?.name || result.assignee?.email || "",
    );
    const productHint =
      result.category === "product"
        ? " Для ускорения приложите в чат фото товара и его название."
        : "";

    return res.status(201).json({
      ok: true,
      data: {
        mode: "ticket",
        reply: assigneeName
          ? `Вопрос передан в поддержку. Ответственный: ${assigneeName}.${productHint}`
          : `Вопрос передан в поддержку. Ответ придёт в отдельный чат.${productHint}`,
        chat_id: result.chat?.id || result.ticket?.chat_id,
        chat_title: result.chat?.title || "Поддержка",
        ticket: result.ticket,
      },
    });
  } catch (err) {
    console.error("support.ask error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/tickets", authMiddleware, async (req, res) => {
  try {
    const role = normalizeRole(req.user.role);
    const includeArchived = String(req.query.include_archived || "") === "1";
    const statuses = parseTicketStatuses(req.query.status);

    let effectiveStatuses = statuses;
    if (effectiveStatuses.length === 0) {
      effectiveStatuses = includeArchived
        ? ["open", "waiting_customer", "resolved", "archived"]
        : ["open", "waiting_customer", "resolved"];
      if (role === "client" && includeArchived) {
        effectiveStatuses = ["open", "waiting_customer", "resolved", "archived"];
      }
    }

    const params = [
      effectiveStatuses,
      req.user.tenant_id || null,
      req.user.id,
      role,
    ];

    const list = await db.query(
      `SELECT st.id,
              st.chat_id,
              st.customer_id,
              st.assignee_id,
              st.assigned_role,
              st.category,
              st.subject,
              st.product_id,
              st.status,
              st.archive_reason,
              st.created_at,
              st.updated_at,
              st.resolved_at,
              st.archived_at,
              c.title AS chat_title,
              c.type AS chat_type,
              c.settings AS chat_settings,
              COALESCE(NULLIF(BTRIM(cu.name), ''), NULLIF(BTRIM(cu.email), ''), 'Клиент') AS customer_name,
              cu.email AS customer_email,
              COALESCE(NULLIF(BTRIM(au.name), ''), NULLIF(BTRIM(au.email), ''), '—') AS assignee_name,
              au.email AS assignee_email
       FROM support_tickets st
       JOIN chats c ON c.id = st.chat_id
       LEFT JOIN users cu ON cu.id = st.customer_id
       LEFT JOIN users au ON au.id = st.assignee_id
       WHERE st.status = ANY($1::text[])
         AND ($2::uuid IS NULL OR st.tenant_id = $2::uuid)
         AND (
           ($4 = 'client' AND st.customer_id = $3)
           OR st.assignee_id = $3
         )
       ORDER BY
         CASE st.status
           WHEN 'open' THEN 0
           WHEN 'waiting_customer' THEN 1
           WHEN 'resolved' THEN 2
           ELSE 3
         END,
         st.updated_at DESC,
         st.created_at DESC
       LIMIT 300`,
      params,
    );

    return res.json({ ok: true, data: list.rows });
  } catch (err) {
    console.error("support.tickets.list error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post("/tickets/:ticketId/feedback", authMiddleware, async (req, res) => {
  const ticketId = normalizeText(req.params.ticketId);
  const resolved = req.body?.resolved;
  const comment = normalizeText(req.body?.comment);

  if (!ticketId) {
    return res.status(400).json({ ok: false, error: "ticketId обязателен" });
  }
  if (typeof resolved !== "boolean") {
    return res.status(400).json({ ok: false, error: "resolved должен быть true/false" });
  }

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");

    const ticketRes = await client.query(
      `SELECT st.*, c.settings AS chat_settings
       FROM support_tickets st
       JOIN chats c ON c.id = st.chat_id
       WHERE st.id = $1
         AND ($2::uuid IS NULL OR st.tenant_id = $2::uuid)
       LIMIT 1
       FOR UPDATE`,
      [ticketId, req.user.tenant_id || null],
    );

    if (ticketRes.rowCount === 0) {
      await client.query("ROLLBACK");
      return res.status(404).json({ ok: false, error: "Тикет не найден" });
    }

    const ticket = ticketRes.rows[0];
    const role = normalizeRole(req.user.role);
    const isCustomer = String(ticket.customer_id) === String(req.user.id);
    const canModerate = isAdminTierRole(role);

    if (!isCustomer && !canModerate) {
      await client.query("ROLLBACK");
      return res.status(403).json({ ok: false, error: "Недостаточно прав" });
    }

    let commentMessage = null;
    if (comment) {
      commentMessage = await insertSupportMessage(client, {
        chatId: ticket.chat_id,
        senderId: req.user.id,
        text: comment,
        meta: {
          kind: "support_customer_feedback_comment",
          support_ticket_id: ticket.id,
          resolved,
        },
      });
    }

    const nextStatus = resolved ? "archived" : "open";
    await client.query(
      `UPDATE support_tickets
       SET status = $1,
           resolved_by = CASE WHEN $2::boolean THEN $3::uuid ELSE NULL END,
           resolved_at = CASE WHEN $2::boolean THEN now() ELSE NULL END,
           archived_at = CASE WHEN $2::boolean THEN now() ELSE NULL END,
           archive_reason = CASE
             WHEN $2::boolean THEN COALESCE(NULLIF($4, ''), 'customer_confirmed')
             ELSE NULL
           END,
           updated_at = now()
       WHERE id = $5`,
      [
        nextStatus,
        resolved,
        req.user.id,
        resolved ? "customer_confirmed" : "",
        ticket.id,
      ],
    );

    const statusText = resolved
      ? "Отлично, вопрос закрыт и отправлен в архив поддержки."
      : "Поняли, вопрос снова открыт. Поддержка ответит в этом чате.";

    const statusMessage = await insertSupportMessage(client, {
      chatId: ticket.chat_id,
      senderId: null,
      text: statusText,
      meta: {
        kind: "support_feedback_result",
        support_ticket_id: ticket.id,
        feedback_status: resolved ? "resolved" : "reopened",
      },
    });

    await client.query("COMMIT");

    if (commentMessage?.id) {
      await emitChatMessage(
        req,
        req.user.tenant_id || null,
        commentMessage.chat_id,
        commentMessage.id,
      );
    }

    if (statusMessage?.id) {
      await emitChatMessage(
        req,
        req.user.tenant_id || null,
        statusMessage.chat_id,
        statusMessage.id,
      );
    }

    return res.json({
      ok: true,
      data: {
        ticket_id: ticket.id,
        status: nextStatus,
      },
    });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error("support.ticket.feedback error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  } finally {
    client.release();
  }
});

router.post(
  "/tickets/:ticketId/archive",
  authMiddleware,
  requireRole("admin", "creator"),
  async (req, res) => {
    const ticketId = normalizeText(req.params.ticketId);
    const reason = normalizeText(req.body?.reason || "admin_archive");
    if (!ticketId) {
      return res.status(400).json({ ok: false, error: "ticketId обязателен" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const ticketRes = await client.query(
        `SELECT *
         FROM support_tickets
         WHERE id = $1
           AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
         LIMIT 1
         FOR UPDATE`,
        [ticketId, req.user.tenant_id || null],
      );
      if (ticketRes.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Тикет не найден" });
      }

      const ticket = ticketRes.rows[0];
      await client.query(
        `UPDATE support_tickets
         SET status = 'archived',
             archive_reason = $1,
             archived_at = now(),
             updated_at = now()
         WHERE id = $2`,
        [reason || "admin_archive", ticket.id],
      );

      const statusMessage = await insertSupportMessage(client, {
        chatId: ticket.chat_id,
        senderId: null,
        text: "Диалог перенесён в архив поддержки.",
        meta: {
          kind: "support_ticket_archived",
          support_ticket_id: ticket.id,
          archive_reason: reason || "admin_archive",
        },
      });

      await client.query("COMMIT");

      if (statusMessage?.id) {
        await emitChatMessage(
          req,
          req.user.tenant_id || null,
          statusMessage.chat_id,
          statusMessage.id,
        );
      }

      return res.json({
        ok: true,
        data: {
          ticket_id: ticket.id,
          status: "archived",
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("support.ticket.archive error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

// Отправить баг-репорт в отдельный приватный канал для admin/creator
router.post("/bug-report", authMiddleware, supportBugRateGuard, async (req, res) => {
  const message = String(req.body?.message || "").trim();
  if (!message) {
    return res
      .status(400)
      .json({ ok: false, error: "Текст баг-репорта обязателен" });
  }
  if (message.length > 5000) {
    return res.status(400).json({
      ok: false,
      error: "Слишком длинный текст (максимум 5000 символов)",
    });
  }

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");

    const profileQ = await client.query(
      `SELECT id, email, role, name, tenant_id
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (profileQ.rowCount === 0) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ ok: false, error: "Пользователь не найден" });
    }
    const reporter = profileQ.rows[0];

    const { channel, created } = await ensureBugReportsChannel(
      client,
      req.user.id,
      reporter.tenant_id || null,
    );
    await ensureAdminCreatorMembers(client, channel.id, reporter.tenant_id || null);

    const title = reporter.name || reporter.email || reporter.id;
    const text = [
      "🐞 Новый баг-репорт",
      `От: ${title}`,
      `Роль: ${reporter.role}`,
      `Email: ${reporter.email || "—"}`,
      "",
      message,
    ].join("\n");

    const meta = {
      kind: "bug_report",
      reporter_id: reporter.id,
      reporter_email: reporter.email,
      reporter_role: reporter.role,
      reporter_name: reporter.name,
      source: "settings_bug_report",
    };

    const messageInsert = await client.query(
      `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5::jsonb, now())
       RETURNING id, chat_id, sender_id, text, meta, created_at`,
      [
        uuidv4(),
        channel.id,
        reporter.id,
        encryptMessageText(text),
        JSON.stringify(meta),
      ],
    );

    await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
      channel.id,
    ]);

    await client.query("COMMIT");

    const io = req.app.get("io");
    if (io) {
      if (created) {
        emitToTenant(io, reporter.tenant_id || null, "chat:created", {
          chatId: channel.id,
        });
      }
      emitToTenant(io, reporter.tenant_id || null, "chat:updated", {
        chatId: channel.id,
      });
      io.to(`chat:${channel.id}`).emit("chat:message", {
        chatId: channel.id,
        message: {
          ...messageInsert.rows[0],
          text,
        },
      });
    }

    return res.status(201).json({
      ok: true,
      data: {
        chat_id: channel.id,
        message_id: messageInsert.rows[0].id,
      },
    });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error("support.bug_report error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  } finally {
    client.release();
  }
});

module.exports = router;
