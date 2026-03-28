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

function emitToTenant(io, rawTenantId, eventName, payload) {
  if (!io || !eventName) return;
  const room = tenantRoom(rawTenantId);
  if (room) {
    io.to(room).emit(eventName, payload);
    return;
  }
  io.emit(eventName, payload);
}

function emitToUser(io, rawUserId, eventName, payload) {
  if (!io || !eventName) return;
  const room = userRoom(rawUserId);
  if (!room) return;
  io.to(room).emit(eventName, payload);
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
  emitToTenant,
  emitToUser,
  emitToUsers,
};
