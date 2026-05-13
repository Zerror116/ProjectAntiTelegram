function normalizeTenantId(rawTenantId) {
  const value = String(rawTenantId || "").trim();
  return value.length > 0 ? value : null;
}

function tenantRoom(rawTenantId) {
  const tenantId = normalizeTenantId(rawTenantId);
  return tenantId ? `tenant:${tenantId}` : null;
}

function normalizeUserId(rawUserId) {
  const value = String(rawUserId || "").trim();
  return value.length > 0 ? value : null;
}

function userRoom(rawUserId) {
  const userId = normalizeUserId(rawUserId);
  return userId ? `user:${userId}` : null;
}

let realtimeEventSeq = 0;

function inferEntityFromEventName(eventName) {
  const head = String(eventName || "").split(":")[0].trim();
  return head || "realtime";
}

function normalizeRealtimePayload(eventName, rawTenantId, payload = {}) {
  const tenantId = normalizeTenantId(rawTenantId);
  const source =
    payload && typeof payload === "object" && !Array.isArray(payload)
      ? payload
      : { payload };
  const now = new Date().toISOString();
  const updatedAt = source.updated_at || source.updatedAt || source.at || now;
  const entityId =
    source.entity_id ||
    source.entityId ||
    source.chatId ||
    source.chat_id ||
    source.channel_id ||
    source.channelId ||
    source.queue_id ||
    source.queueId ||
    source.messageId ||
    source.message_id ||
    null;
  realtimeEventSeq = (realtimeEventSeq + 1) % Number.MAX_SAFE_INTEGER;
  return {
    ...source,
    event_id:
      source.event_id ||
      source.eventId ||
      `${Date.now().toString(36)}-${realtimeEventSeq.toString(36)}`,
    type: source.type || eventName,
    tenant_id: source.tenant_id || source.tenantId || tenantId,
    entity: source.entity || inferEntityFromEventName(eventName),
    entity_id: entityId == null ? null : String(entityId),
    action: source.action || "updated",
    updated_at: updatedAt,
  };
}

function emitToTenant(io, rawTenantId, eventName, payload) {
  if (!io || !eventName) return;
  const room = tenantRoom(rawTenantId);
  if (!room) {
    console.warn("[realtime] skipped tenant event without tenant scope", {
      eventName,
    });
    return;
  }
  io.to(room).emit(eventName, normalizeRealtimePayload(eventName, rawTenantId, payload));
}

function emitToUser(io, rawUserId, eventName, payload) {
  if (!io || !eventName) return;
  const room = userRoom(rawUserId);
  if (!room) return;
  io.to(room).emit(eventName, normalizeRealtimePayload(eventName, payload?.tenant_id || payload?.tenantId || null, payload));
}

function emitToUsers(io, rawUserIds, eventName, payloadFactory) {
  if (!io || !eventName || !Array.isArray(rawUserIds)) return;
  const emitted = new Set();
  for (const rawUserId of rawUserIds) {
    const userId = normalizeUserId(rawUserId);
    if (!userId || emitted.has(userId)) continue;
    emitted.add(userId);
    const payload = typeof payloadFactory === "function"
      ? payloadFactory(userId)
      : payloadFactory;
    if (payload === undefined) continue;
    emitToUser(io, userId, eventName, payload);
  }
}

module.exports = {
  normalizeTenantId,
  normalizeUserId,
  tenantRoom,
  userRoom,
  normalizeRealtimePayload,
  emitToTenant,
  emitToUser,
  emitToUsers,
};
