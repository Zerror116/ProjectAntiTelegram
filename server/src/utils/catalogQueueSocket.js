const { emitToTenant } = require('./socket');

function emitCatalogQueueUpdated(io, tenantId, payload = {}) {
  if (!io) return;
  if (process.env.PHX_PUBLICATION_DEBUG_LOGS === '1') {
    console.log('[PHX:PUBLISH] catalog:queue:updated emit', {
      tenant_id: tenantId || null,
      action: payload.action || 'updated',
      channel_id: payload.channel_id || payload.channelId || null,
      queue_ids: payload.queue_ids || null,
      batch_ids: payload.batch_ids || null,
    });
  }
  emitToTenant(io, tenantId || null, 'catalog:queue:updated', {
    at: new Date().toISOString(),
    tenant_id: tenantId || null,
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
