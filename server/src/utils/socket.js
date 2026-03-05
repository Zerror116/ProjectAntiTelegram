function normalizeTenantId(rawTenantId) {
  const value = String(rawTenantId || "").trim();
  return value.length > 0 ? value : null;
}

function tenantRoom(rawTenantId) {
  const tenantId = normalizeTenantId(rawTenantId);
  return tenantId ? `tenant:${tenantId}` : null;
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

module.exports = {
  normalizeTenantId,
  tenantRoom,
  emitToTenant,
};
