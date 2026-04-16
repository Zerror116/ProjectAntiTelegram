const db = require('../db');
const { decryptMessageText } = require('./messageCrypto');

function normalizeText(raw) {
  return String(raw || '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function attachmentKindsFromMessage(meta = {}, attachments = []) {
  const set = new Set();
  const attachmentType = String(meta.attachment_type || '').trim().toLowerCase();
  if (attachmentType) set.add(attachmentType);
  for (const attachment of Array.isArray(attachments) ? attachments : []) {
    const type = String(attachment?.attachment_type || '').trim().toLowerCase();
    if (type) set.add(type);
  }
  return Array.from(set);
}

function captionFromMeta(meta = {}) {
  const direct = String(meta.caption || '').trim();
  if (direct) return direct;
  const title = String(meta.title || '').trim();
  const description = String(meta.description || '').trim();
  return [title, description].filter(Boolean).join(' ').trim();
}

async function upsertMessageSearchDocument({
  messageId,
  chatId,
  tenantId = null,
  senderId = null,
  text = '',
  meta = {},
  attachments = [],
  createdAt = null,
}) {
  const normalizedMessageId = String(messageId || '').trim();
  const normalizedChatId = String(chatId || '').trim();
  if (!normalizedMessageId || !normalizedChatId) return;

  const searchText = normalizeText(text);
  const captionText = normalizeText(captionFromMeta(meta));
  const attachmentKinds = attachmentKindsFromMessage(meta, attachments);

  await db.query(
    `INSERT INTO message_search_documents (
       message_id,
       chat_id,
       tenant_id,
       sender_id,
       search_text_normalized,
       caption_normalized,
       attachment_kinds,
       created_at,
       updated_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7::text[], COALESCE($8::timestamptz, now()), now())
     ON CONFLICT (message_id)
     DO UPDATE
       SET chat_id = EXCLUDED.chat_id,
           tenant_id = EXCLUDED.tenant_id,
           sender_id = EXCLUDED.sender_id,
           search_text_normalized = EXCLUDED.search_text_normalized,
           caption_normalized = EXCLUDED.caption_normalized,
           attachment_kinds = EXCLUDED.attachment_kinds,
           created_at = EXCLUDED.created_at,
           updated_at = now()`,
    [
      normalizedMessageId,
      normalizedChatId,
      tenantId || null,
      senderId || null,
      searchText,
      captionText,
      attachmentKinds,
      createdAt || null,
    ],
  );
}

async function deleteMessageSearchDocument(messageId) {
  const normalized = String(messageId || '').trim();
  if (!normalized) return;
  await db.query('DELETE FROM message_search_documents WHERE message_id = $1', [
    normalized,
  ]);
}

async function syncMessageSearchDocumentFromMessageId(messageId) {
  const normalized = String(messageId || '').trim();
  if (!normalized) return;
  const result = await db.query(
    `SELECT m.id,
            m.chat_id,
            m.sender_id,
            c.tenant_id,
            m.text,
            m.meta,
            m.created_at
     FROM messages m
     JOIN chats c ON c.id = m.chat_id
     WHERE m.id = $1
     LIMIT 1`,
    [normalized],
  );
  if (result.rowCount === 0) {
    await deleteMessageSearchDocument(normalized);
    return;
  }
  const row = result.rows[0];
  const attachmentsResult = await db.query(
    `SELECT attachment_type
     FROM message_attachments
     WHERE message_id = $1
     ORDER BY sort_order ASC, created_at ASC, id ASC`,
    [normalized],
  );
  await upsertMessageSearchDocument({
    messageId: row.id,
    chatId: row.chat_id,
    tenantId: row.tenant_id || null,
    senderId: row.sender_id || null,
    text: decryptMessageText(row.text),
    meta: row.meta && typeof row.meta === 'object' ? row.meta : {},
    attachments: attachmentsResult.rows,
    createdAt: row.created_at || null,
  });
}

module.exports = {
  normalizeSearchDocumentText: normalizeText,
  upsertMessageSearchDocument,
  deleteMessageSearchDocument,
  syncMessageSearchDocumentFromMessageId,
};
