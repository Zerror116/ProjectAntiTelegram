const { emitToTenant } = require('./socket');

function emitCatalogQueueUpdated(io, tenantId, payload = {}) {
  if (!io) return;
  emitToTenant(io, tenantId || null, 'catalog:queue:updated', {
    at: new Date().toISOString(),
    ...payload,
  });
}

module.exports = {
  emitCatalogQueueUpdated,
};
