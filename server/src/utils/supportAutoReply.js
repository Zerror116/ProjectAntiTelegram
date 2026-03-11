function toMoney(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Number(parsed.toFixed(2));
}

function normalizeSupportMatchText(raw) {
  return String(raw || "")
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[^a-z0-9а-я]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeTriggerRule(raw) {
  return String(raw || "").trim().slice(0, 500);
}

function normalizePriority(raw, fallback = 100) {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  const value = Math.trunc(parsed);
  return Math.max(0, Math.min(1000, value));
}

function isFallbackTriggerRule(rawRule) {
  const normalized = String(rawRule || "").toLowerCase().trim();
  return (
    normalized === "*" ||
    normalized === "else" ||
    normalized === "fallback" ||
    normalized === "иначе"
  );
}

function parseTriggerGroups(rawRule) {
  const rule = normalizeTriggerRule(rawRule);
  if (!rule) return [];
  return rule
    .split(/[|\n;]/)
    .map((group) => group.trim())
    .filter(Boolean)
    .map((group) =>
      group
        .split("+")
        .map((term) => normalizeSupportMatchText(term))
        .filter(Boolean),
    )
    .filter((group) => group.length > 0);
}

function normalizeStem(word) {
  const normalized = normalizeSupportMatchText(word).replace(/\s+/g, "");
  if (!normalized) return "";
  return normalized.length <= 4 ? normalized : normalized.slice(0, 4);
}

function messageWordMatches(word, termWord) {
  const left = String(word || "").trim();
  const right = String(termWord || "").trim();
  if (!left || !right) return false;
  if (left === right) return true;
  if (left.includes(right) || right.includes(left)) return true;
  return normalizeStem(left) === normalizeStem(right);
}

function termMatchesMessage(normalizedMessage, term) {
  const normalizedTerm = normalizeSupportMatchText(term);
  if (!normalizedTerm) return false;
  if (normalizedMessage.includes(normalizedTerm)) return true;

  const messageWords = normalizedMessage.split(" ").filter(Boolean);
  const termWords = normalizedTerm.split(" ").filter(Boolean);
  if (!messageWords.length || !termWords.length) return false;

  return termWords.every((termWord) =>
    messageWords.some((word) => messageWordMatches(word, termWord)),
  );
}

function supportTriggerMatches(rawRule, messageText) {
  if (isFallbackTriggerRule(rawRule)) return false;
  const groups = parseTriggerGroups(rawRule);
  if (!groups.length) return false;
  const normalizedMessage = normalizeSupportMatchText(messageText);
  if (!normalizedMessage) return false;
  return groups.some((group) =>
    group.every((term) => termMatchesMessage(normalizedMessage, term)),
  );
}

function renderSupportTemplateBody(templateBody, context = {}) {
  let text = String(templateBody || "");
  const pairs = {
    "{customer_name}": context.customer_name || "",
    "{cart_total}": String(context.cart_total ?? ""),
    "{processed_total}": String(context.processed_total ?? ""),
    "{claims_total}": String(context.claims_total ?? ""),
    "{delivery_status}": context.delivery_status || "",
    "{subject}": context.subject || "",
    "{message_text}": context.message_text || "",
  };
  for (const [token, value] of Object.entries(pairs)) {
    text = text.split(token).join(value);
  }
  return text;
}

async function findMatchingSupportTemplate(
  client,
  { tenantId = null, category = "general", messageText = "" },
) {
  const normalizedCategory = String(category || "general")
    .toLowerCase()
    .trim();
  const categories = Array.from(
    new Set([
      normalizedCategory && normalizedCategory !== "general"
        ? normalizedCategory
        : "general",
      "general",
    ]),
  );

  const templatesQ = await client.query(
    `SELECT id,
            title,
            body,
            category,
            trigger_rule,
            auto_reply_enabled,
            priority,
            is_system
     FROM support_reply_templates
     WHERE is_active = true
       AND auto_reply_enabled = true
       AND NULLIF(BTRIM(trigger_rule), '') IS NOT NULL
       AND (tenant_id = $1::uuid OR tenant_id IS NULL)
       AND category = ANY($2::text[])
     ORDER BY priority ASC, is_system DESC, updated_at DESC, created_at DESC
     LIMIT 200`,
    [tenantId || null, categories],
  );

  const fallbackTemplates = [];
  for (const template of templatesQ.rows || []) {
    if (isFallbackTriggerRule(template.trigger_rule)) {
      fallbackTemplates.push(template);
      continue;
    }
    if (supportTriggerMatches(template.trigger_rule, messageText)) {
      return template;
    }
  }
  if (fallbackTemplates.length > 0) {
    return fallbackTemplates[0];
  }
  return null;
}

async function resolveSupportTemplateContext(
  client,
  { customerId, subject = "", messageText = "" },
) {
  const sumsQ = await client.query(
    `SELECT COALESCE(SUM(c.quantity * COALESCE(c.custom_price, p.price)), 0)::numeric(14,2) AS total,
            COALESCE(SUM(c.quantity * COALESCE(c.custom_price, p.price)) FILTER (
              WHERE c.status IN ('processed', 'preparing_delivery', 'handing_to_courier', 'in_delivery', 'delivered')
            ), 0)::numeric(14,2) AS processed
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     WHERE c.user_id = $1`,
    [customerId],
  );

  const deliveryQ = await client.query(
    `SELECT delivery_status
     FROM delivery_batch_customers
     WHERE user_id = $1
     ORDER BY updated_at DESC NULLS LAST, created_at DESC
     LIMIT 1`,
    [customerId],
  );

  const userQ = await client.query(
    `SELECT COALESCE(NULLIF(BTRIM(name), ''), NULLIF(BTRIM(email), ''), 'Клиент') AS customer_name
     FROM users
     WHERE id = $1
     LIMIT 1`,
    [customerId],
  );

  const claimsQ = await client.query(
    `SELECT COALESCE(SUM(approved_amount), 0)::numeric(14,2) AS claims_total
     FROM customer_claims
     WHERE user_id = $1
       AND status IN ('approved_return', 'approved_discount', 'settled')`,
    [customerId],
  );

  const claimsTotal = toMoney(claimsQ.rows[0]?.claims_total);
  const total = Math.max(0, toMoney(sumsQ.rows[0]?.total) - claimsTotal);
  const processed = Math.max(0, toMoney(sumsQ.rows[0]?.processed) - claimsTotal);

  return {
    customer_name: userQ.rows[0]?.customer_name || "Клиент",
    cart_total: total,
    processed_total: processed,
    claims_total: claimsTotal,
    delivery_status: String(deliveryQ.rows[0]?.delivery_status || "—"),
    subject: String(subject || ""),
    message_text: String(messageText || ""),
  };
}

async function buildSupportTemplateAutoReply(
  client,
  { tenantId = null, category = "general", customerId, subject = "", messageText = "" },
) {
  const template = await findMatchingSupportTemplate(client, {
    tenantId,
    category,
    messageText,
  });
  if (!template) return null;
  const context = await resolveSupportTemplateContext(client, {
    customerId,
    subject,
    messageText,
  });
  const text = renderSupportTemplateBody(template.body, context).trim();
  if (!text) return null;
  return { template, context, text };
}

module.exports = {
  renderSupportTemplateBody,
  normalizeTriggerRule,
  normalizePriority,
  isFallbackTriggerRule,
  supportTriggerMatches,
  buildSupportTemplateAutoReply,
};
