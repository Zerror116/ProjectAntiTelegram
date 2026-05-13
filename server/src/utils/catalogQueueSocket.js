const { emitToTenant } = require('./socket');

function emitCatalogQueueUpdated(io, tenantId, payload = {}) {
  if (!io) return;
  emitToTenant(io, tenantId || null, 'catalog:queue:updated', {
    at: new Date().toISOString(),
    entity: 'catalog_queue',
    action: payload.action || 'updated',
    entity_id:
      payload.queue_id ||
      payload.queueId ||
      payload.product_id ||
      payload.productId ||
      payload.channel_id ||
      payload.channelId ||
      null,
    ...payload,
  });
}

module.exports = {
  emitCatalogQueueUpdated,
};
