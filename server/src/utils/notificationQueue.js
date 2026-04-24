const db = require("../db");

const MAX_DELIVERY_ATTEMPTS = 6;
const STALE_PROCESSING_TIMEOUT_MS = 5 * 60 * 1000;

function cleanString(rawValue) {
  return String(rawValue || "").trim();
}

function normalizeJsonMap(raw, fallback = {}) {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    return { ...raw };
  }
  return { ...fallback };
}

function computeRetryDelayMs(attemptCount) {
  const bounded = Math.max(1, Math.min(Number(attemptCount || 1), MAX_DELIVERY_ATTEMPTS));
  const baseMinutes = [1, 3, 10, 30, 120, 360][bounded - 1] || 360;
  return baseMinutes * 60 * 1000;
}

function nextAttemptAtIso(attemptCount) {
  return new Date(Date.now() + computeRetryDelayMs(attemptCount)).toISOString();
}

async function listQueueableEndpointsForUser(userId) {
  const result = await db.query(
    `SELECT *
       FROM notification_endpoints
      WHERE user_id = $1
        AND is_active = true
        AND (
          (
            transport = 'webpush'
            AND endpoint IS NOT NULL
            AND btrim(endpoint) <> ''
            AND permission_state = 'granted'
          )
          OR
          (
            transport = 'fcm'
            AND push_token IS NOT NULL
            AND btrim(push_token) <> ''
            AND permission_state IN ('granted', 'provisional')
          )
        )
        AND (
          failure_backoff_until IS NULL
          OR failure_backoff_until <= now()
        )
        AND COALESCE((app_runtime_policy->>'enabled')::boolean, true) = true
      ORDER BY updated_at DESC NULLS LAST, created_at DESC`,
    [userId],
  );
  return result.rows || [];
}

async function upsertQueuedPushDelivery({
  inboxItemId,
  userId,
  endpoint,
  metadata = {},
}) {
  const endpointId = endpoint?.id || null;
  const provider = cleanString(endpoint?.transport).toLowerCase() === "webpush"
    ? "webpush"
    : "fcm";
  const transport = cleanString(endpoint?.transport).toLowerCase() || provider;
  const deliveryKey = endpointId
    ? `push:${inboxItemId}:${endpointId}`
    : `push:${inboxItemId}:${provider}:${cleanString(endpoint?.device_key || endpoint?.push_token || endpoint?.endpoint)}`;
  const result = await db.query(
    `INSERT INTO notification_deliveries (
       inbox_item_id,
       user_id,
       endpoint_id,
       channel,
       provider,
       transport,
       delivery_key,
       queue_name,
       state,
       error_message,
       metadata,
       attempt_count,
       next_attempt_at,
       updated_at
     )
     VALUES (
       $1, $2, $3, 'push', $4, $5, $6, 'push', 'queued', NULL, $7::jsonb, 0, now(), now()
     )
     ON CONFLICT (inbox_item_id, endpoint_id, channel)
     DO UPDATE
       SET provider = EXCLUDED.provider,
           transport = EXCLUDED.transport,
           delivery_key = EXCLUDED.delivery_key,
           queue_name = 'push',
           state = CASE
             WHEN notification_deliveries.state IN ('delivered', 'opened', 'dismissed')
               THEN notification_deliveries.state
             ELSE 'queued'
           END,
           error_message = CASE
             WHEN notification_deliveries.state IN ('delivered', 'opened', 'dismissed')
               THEN notification_deliveries.error_message
             ELSE NULL
           END,
           metadata = COALESCE(notification_deliveries.metadata, '{}'::jsonb) || EXCLUDED.metadata,
           next_attempt_at = CASE
             WHEN notification_deliveries.state IN ('delivered', 'opened', 'dismissed')
               THEN notification_deliveries.next_attempt_at
             ELSE now()
           END,
           processing_started_at = CASE
             WHEN notification_deliveries.state IN ('delivered', 'opened', 'dismissed')
               THEN notification_deliveries.processing_started_at
             ELSE NULL
           END,
           worker_id = CASE
             WHEN notification_deliveries.state IN ('delivered', 'opened', 'dismissed')
               THEN notification_deliveries.worker_id
             ELSE NULL
           END,
           updated_at = now()
     RETURNING *`,
    [
      inboxItemId,
      userId,
      endpointId,
      provider,
      transport,
      deliveryKey,
      JSON.stringify(normalizeJsonMap(metadata)),
    ],
  );
  return result.rows[0] || null;
}

async function queuePushDeliveriesForItem({ item, user, preferences }) {
  const notifications = require("./notifications");
  const pushPolicy = notifications.evaluatePushEligibility(item, preferences);
  if (!pushPolicy.allowed) {
    await notifications.createNotificationDelivery({
      inboxItemId: item.id,
      userId: user.id,
      channel: "push",
      provider: null,
      state: pushPolicy.state,
      errorMessage: "",
      metadata: pushPolicy,
    });
    return { queued: 0, skipped: pushPolicy.reason || "push_disabled" };
  }

  const endpoints = await listQueueableEndpointsForUser(user.id);
  if (!endpoints.length) {
    await notifications.createNotificationDelivery({
      inboxItemId: item.id,
      userId: user.id,
      channel: "push",
      provider: null,
      state: "skipped",
      errorMessage: "",
      metadata: { reason: "no_push_endpoints" },
    });
    return { queued: 0, skipped: "no_push_endpoints" };
  }

  let queued = 0;
  for (const endpoint of endpoints) {
    await upsertQueuedPushDelivery({
      inboxItemId: item.id,
      userId: user.id,
      endpoint,
      metadata: {
        category: cleanString(item.category).toLowerCase(),
        priority: cleanString(item.priority).toLowerCase(),
        endpoint_transport: cleanString(endpoint.transport).toLowerCase(),
        endpoint_platform: cleanString(endpoint.platform).toLowerCase(),
      },
    });
    queued += 1;
  }
  return { queued, skipped: null };
}

async function appendDeliveryAttempt({
  delivery,
  provider = null,
  workerId = "",
  state = "started",
  errorMessage = "",
  metadata = {},
}) {
  const result = await db.query(
    `INSERT INTO notification_delivery_attempts (
       delivery_id,
       inbox_item_id,
       endpoint_id,
       user_id,
       provider,
       worker_id,
       attempt_no,
       state,
       error_message,
       metadata,
       created_at,
       completed_at
     )
     VALUES (
       $1, $2, $3, $4, $5, NULLIF($6, ''), GREATEST(COALESCE($7, 0), 0) + 1, $8,
       NULLIF($9, ''), $10::jsonb, now(),
       CASE WHEN $8 IN ('provider_accepted', 'sent', 'delivered', 'opened', 'failed', 'skipped', 'disabled', 'expired')
         THEN now()
         ELSE NULL
       END
     )
     RETURNING *`,
    [
      delivery.id,
      delivery.inbox_item_id,
      delivery.endpoint_id || null,
      delivery.user_id,
      provider,
      workerId,
      Number(delivery.attempt_count || 0),
      cleanString(state).toLowerCase() || "started",
      errorMessage,
      JSON.stringify(normalizeJsonMap(metadata)),
    ],
  );
  return result.rows[0] || null;
}

async function appendDeliveryReceipt({
  deliveryId,
  inboxItemId,
  endpointId = null,
  receiptType,
  receiptKey = "",
  metadata = {},
}) {
  const normalizedType = cleanString(receiptType).toLowerCase();
  if (!deliveryId || !inboxItemId || !normalizedType) return null;
  const result = await db.query(
    `INSERT INTO notification_delivery_receipts (
       delivery_id,
       inbox_item_id,
       endpoint_id,
       receipt_type,
       receipt_key,
       metadata
     )
     VALUES ($1, $2, $3, $4, NULLIF($5, ''), $6::jsonb)
     RETURNING *`,
    [
      deliveryId,
      inboxItemId,
      endpointId,
      normalizedType,
      receiptKey,
      JSON.stringify(normalizeJsonMap(metadata)),
    ],
  );
  return result.rows[0] || null;
}

async function claimQueuedNotificationDeliveries({ limit = 25, workerId = "" } = {}) {
  const safeLimit = Math.max(1, Math.min(Number(limit || 25), 100));
  const staleBefore = new Date(Date.now() - STALE_PROCESSING_TIMEOUT_MS).toISOString();
  const result = await db.query(
    `WITH candidate AS (
       SELECT id
         FROM notification_deliveries
        WHERE channel = 'push'
          AND queue_name = 'push'
          AND state IN ('queued', 'failed')
          AND COALESCE(next_attempt_at, now()) <= now()
          AND (
            processing_started_at IS NULL
            OR processing_started_at < $2::timestamptz
          )
        ORDER BY next_attempt_at ASC NULLS FIRST, created_at ASC
        LIMIT $1
        FOR UPDATE SKIP LOCKED
     )
     UPDATE notification_deliveries d
        SET processing_started_at = now(),
            worker_id = NULLIF($3, ''),
            updated_at = now()
       FROM candidate
      WHERE d.id = candidate.id
      RETURNING d.*`,
    [safeLimit, staleBefore, cleanString(workerId)],
  );
  return result.rows || [];
}

function isPermanentDeliveryError(result = {}) {
  if (result.deactivateEndpoint === true) return true;
  const state = cleanString(result.state).toLowerCase();
  if (state === "disabled" || state === "expired" || state === "skipped") {
    return true;
  }
  return false;
}

async function updateDeliveryTerminalState(deliveryId, patch = {}) {
  const state = cleanString(patch.state).toLowerCase() || "failed";
  const sentAtStates = new Set(["sent", "provider_accepted"]);
  const deliveredAtStates = new Set(["delivered", "opened"]);
  const nowIso = new Date().toISOString();
  const result = await db.query(
    `UPDATE notification_deliveries
        SET state = $2,
            provider = COALESCE(NULLIF($3, ''), provider),
            provider_message_id = COALESCE(NULLIF($4, ''), provider_message_id),
            error_message = NULLIF($5, ''),
            metadata = COALESCE(metadata, '{}'::jsonb) || $6::jsonb,
            attempt_count = GREATEST(COALESCE(attempt_count, 0), 0) + 1,
            last_attempt_at = now(),
            next_attempt_at = CASE
              WHEN $2 IN ('failed', 'queued') AND $7::timestamptz IS NOT NULL THEN $7::timestamptz
              ELSE next_attempt_at
            END,
            sent_at = CASE
              WHEN $8::boolean THEN COALESCE(sent_at, now())
              ELSE sent_at
            END,
            delivered_at = CASE
              WHEN $9::boolean THEN COALESCE(delivered_at, now())
              ELSE delivered_at
            END,
            failed_at = CASE
              WHEN $2 = 'failed' THEN now()
              ELSE failed_at
            END,
            processing_started_at = NULL,
            updated_at = now()
      WHERE id = $1
      RETURNING *`,
    [
      deliveryId,
      state,
      cleanString(patch.provider),
      cleanString(patch.providerMessageId),
      cleanString(patch.errorMessage),
      JSON.stringify(normalizeJsonMap(patch.metadata)),
      patch.nextAttemptAt || null,
      sentAtStates.has(state),
      deliveredAtStates.has(state),
    ],
  );
  return result.rows[0] || null;
}

async function markEndpointFailure(endpointId, errorMessage, { deactivate = false } = {}) {
  if (!endpointId) return;
  if (deactivate) {
    await db.query(
      `UPDATE notification_endpoints
          SET is_active = false,
              consecutive_failures = consecutive_failures + 1,
              failure_backoff_until = now() + interval '7 days',
              last_failure_at = now(),
              last_failure_reason = NULLIF($2, ''),
              last_delivery_state = 'disabled',
              last_delivery_at = now(),
              updated_at = now()
        WHERE id = $1`,
      [endpointId, cleanString(errorMessage)],
    );
    return;
  }
  await db.query(
    `UPDATE notification_endpoints
        SET consecutive_failures = consecutive_failures + 1,
            failure_backoff_until = CASE
              WHEN consecutive_failures >= 5 THEN now() + interval '1 day'
              WHEN consecutive_failures >= 3 THEN now() + interval '2 hours'
              ELSE now() + interval '10 minutes'
            END,
            last_failure_at = now(),
            last_failure_reason = NULLIF($2, ''),
            last_delivery_state = 'failed',
            last_delivery_at = now(),
            updated_at = now()
      WHERE id = $1`,
    [endpointId, cleanString(errorMessage)],
  );
}

async function markEndpointSuccess(endpointId, state) {
  if (!endpointId) return;
  await db.query(
    `UPDATE notification_endpoints
        SET consecutive_failures = 0,
            failure_backoff_until = NULL,
            last_success_at = now(),
            last_delivery_state = $2,
            last_delivery_at = now(),
            updated_at = now()
      WHERE id = $1`,
    [endpointId, cleanString(state).toLowerCase()],
  );
}

async function loadDeliveryContext(deliveryId) {
  const result = await db.query(
    `SELECT d.*,
            i.category,
            i.priority,
            i.title,
            i.body,
            i.deep_link,
            i.media,
            i.payload,
            i.collapse_key,
            i.ttl_seconds,
            i.source_type,
            i.campaign_id,
            i.force_show,
            i.created_at AS item_created_at,
            i.expires_at,
            u.id AS user_id,
            u.email AS user_email,
            u.name AS user_name,
            u.role AS user_role,
            u.tenant_id AS user_tenant_id,
            e.platform,
            e.transport AS endpoint_transport,
            e.device_key,
            e.push_token,
            e.endpoint,
            e.subscription,
            e.permission_state,
            e.capabilities,
            e.app_runtime_policy,
            e.device_profile,
            e.is_active AS endpoint_is_active
       FROM notification_deliveries d
       JOIN notification_inbox_items i
         ON i.id = d.inbox_item_id
       JOIN users u
         ON u.id = d.user_id
       LEFT JOIN notification_endpoints e
         ON e.id = d.endpoint_id
      WHERE d.id = $1
      LIMIT 1`,
    [deliveryId],
  );
  return result.rows[0] || null;
}

async function processQueuedNotificationDelivery(delivery, { workerId = "" } = {}) {
  const context = await loadDeliveryContext(delivery.id);
  if (!context) return null;

  const notifications = require("./notifications");
  const provider = cleanString(context.provider || context.endpoint_transport).toLowerCase();

  if (context.expires_at && new Date(context.expires_at).getTime() <= Date.now()) {
    await appendDeliveryAttempt({
      delivery: context,
      provider,
      workerId,
      state: "expired",
      metadata: { reason: "ttl_expired" },
    });
    return updateDeliveryTerminalState(context.id, {
      state: "expired",
      provider,
      metadata: { reason: "ttl_expired" },
    });
  }

  if (!context.endpoint_id || context.endpoint_is_active !== true) {
    await appendDeliveryAttempt({
      delivery: context,
      provider,
      workerId,
      state: "disabled",
      metadata: { reason: "endpoint_missing_or_inactive" },
    });
    return updateDeliveryTerminalState(context.id, {
      state: "skipped",
      provider,
      metadata: { reason: "endpoint_missing_or_inactive" },
    });
  }

  const user = {
    id: context.user_id,
    email: context.user_email,
    name: context.user_name,
    role: context.user_role,
    tenant_id: context.user_tenant_id,
  };
  const preferences = await notifications.getNotificationPreferencesForUser(user);
  const pushPolicy = notifications.evaluatePushEligibility(context, preferences);
  if (!pushPolicy.allowed) {
    await appendDeliveryAttempt({
      delivery: context,
      provider,
      workerId,
      state: pushPolicy.state === "skipped" ? "skipped" : "disabled",
      metadata: pushPolicy,
    });
    return updateDeliveryTerminalState(context.id, {
      state: pushPolicy.state,
      provider,
      metadata: pushPolicy,
    });
  }

  const badgeCount = await notifications.computeNotificationBadgeCount(user.id);
  const inboxUnreadCount = await notifications.computeNotificationInboxBadgeCount(user.id, {
    user,
    preferences,
  });
  const payload = notifications.buildSocketPayload(
    {
      id: context.inbox_item_id,
      category: context.category,
      priority: context.priority,
      title: context.title,
      body: context.body,
      deep_link: context.deep_link,
      media: normalizeJsonMap(context.media),
      payload: normalizeJsonMap(context.payload),
      campaign_id: context.campaign_id,
      collapse_key: context.collapse_key,
      ttl_seconds: context.ttl_seconds,
      force_show: context.force_show,
      created_at: context.item_created_at,
      source_type: context.source_type,
    },
    badgeCount,
    inboxUnreadCount,
    preferences,
  );

  await appendDeliveryAttempt({
    delivery: context,
    provider,
    workerId,
    state: "started",
    metadata: {
      platform: cleanString(context.platform).toLowerCase(),
      transport: cleanString(context.endpoint_transport).toLowerCase(),
    },
  });

  let result = null;
  if (cleanString(context.endpoint_transport).toLowerCase() === "webpush") {
    const { sendWebPushPayloadToEndpoint } = require("./webPush");
    result = await sendWebPushPayloadToEndpoint({
      endpoint: context,
      payload,
    });
  } else {
    const { sendFcmPayloadToEndpoints } = require("./nativePush");
    const nativeResult = await sendFcmPayloadToEndpoints({
      endpoints: [context],
      payload,
    });
    result = Array.isArray(nativeResult.results) && nativeResult.results.length
      ? nativeResult.results[0]
      : {
          endpointId: context.endpoint_id,
          state: nativeResult.configured === false ? "failed" : "skipped",
          errorMessage: nativeResult.configured === false
            ? "native_push_not_configured"
            : "no_result",
          providerMessageId: null,
        };
  }

  const normalizedResult = result && typeof result === "object" ? result : {};
  const nextAttemptCount = Number(context.attempt_count || 0) + 1;
  const transientFailure = cleanString(normalizedResult.state).toLowerCase() === "failed" &&
    !isPermanentDeliveryError(normalizedResult) &&
    nextAttemptCount < MAX_DELIVERY_ATTEMPTS;

  if (cleanString(normalizedResult.state).toLowerCase() === "provider_accepted") {
    await appendDeliveryReceipt({
      deliveryId: context.id,
      inboxItemId: context.inbox_item_id,
      endpointId: context.endpoint_id,
      receiptType: "provider_accepted",
      receiptKey: cleanString(normalizedResult.providerMessageId),
      metadata: normalizedResult,
    });
  }

  await appendDeliveryAttempt({
    delivery: context,
    provider,
    workerId,
    state: cleanString(normalizedResult.state).toLowerCase() || "failed",
    errorMessage: cleanString(normalizedResult.errorMessage),
    metadata: normalizedResult,
  });

  if (cleanString(normalizedResult.state).toLowerCase() === "provider_accepted") {
    await markEndpointSuccess(context.endpoint_id, "provider_accepted");
    return updateDeliveryTerminalState(context.id, {
      state: "provider_accepted",
      provider,
      providerMessageId: cleanString(normalizedResult.providerMessageId),
      metadata: normalizedResult,
    });
  }

  if (cleanString(normalizedResult.state).toLowerCase() === "sent") {
    await markEndpointSuccess(context.endpoint_id, "sent");
    return updateDeliveryTerminalState(context.id, {
      state: "sent",
      provider,
      providerMessageId: cleanString(normalizedResult.providerMessageId),
      metadata: normalizedResult,
    });
  }

  if (transientFailure) {
    await markEndpointFailure(context.endpoint_id, normalizedResult.errorMessage, {
      deactivate: false,
    });
    return updateDeliveryTerminalState(context.id, {
      state: "failed",
      provider,
      errorMessage: cleanString(normalizedResult.errorMessage || "delivery_failed"),
      metadata: normalizedResult,
      nextAttemptAt: nextAttemptAtIso(nextAttemptCount),
    });
  }

  if (cleanString(normalizedResult.state).toLowerCase() === "failed") {
    await markEndpointFailure(context.endpoint_id, normalizedResult.errorMessage, {
      deactivate: normalizedResult.deactivateEndpoint === true,
    });
    return updateDeliveryTerminalState(context.id, {
      state: normalizedResult.deactivateEndpoint === true ? "failed" : "failed",
      provider,
      errorMessage: cleanString(normalizedResult.errorMessage || "delivery_failed"),
      metadata: normalizedResult,
    });
  }

  await markEndpointSuccess(context.endpoint_id, cleanString(normalizedResult.state).toLowerCase() || "skipped");
  return updateDeliveryTerminalState(context.id, {
    state: cleanString(normalizedResult.state).toLowerCase() || "skipped",
    provider,
    errorMessage: cleanString(normalizedResult.errorMessage),
    metadata: normalizedResult,
  });
}

async function processNotificationQueueBatch({ limit = 25, workerId = "" } = {}) {
  const deliveries = await claimQueuedNotificationDeliveries({ limit, workerId });
  const processed = [];
  for (const delivery of deliveries) {
    try {
      const result = await processQueuedNotificationDelivery(delivery, { workerId });
      processed.push(result);
    } catch (error) {
      const safeMessage = cleanString(error?.message || error || "delivery_worker_error");
      await appendDeliveryAttempt({
        delivery,
        provider: cleanString(delivery.provider),
        workerId,
        state: "failed",
        errorMessage: safeMessage,
        metadata: { fatal: true },
      });
      const nextAttemptCount = Number(delivery.attempt_count || 0) + 1;
      await updateDeliveryTerminalState(delivery.id, {
        state: "failed",
        provider: cleanString(delivery.provider),
        errorMessage: safeMessage,
        metadata: { fatal: true },
        nextAttemptAt: nextAttemptCount < MAX_DELIVERY_ATTEMPTS
          ? nextAttemptAtIso(nextAttemptCount)
          : null,
      });
      await markEndpointFailure(delivery.endpoint_id, safeMessage, {
        deactivate: nextAttemptCount >= MAX_DELIVERY_ATTEMPTS,
      });
    }
  }
  return processed;
}

async function sweepDisabledEndpoints() {
  const result = await db.query(
    `UPDATE notification_endpoints
        SET is_active = false,
            updated_at = now(),
            last_delivery_state = 'disabled'
      WHERE is_active = true
        AND consecutive_failures >= 8
        AND last_failure_at < now() - interval '7 days'
      RETURNING id`,
  );
  return Number(result.rowCount || 0);
}

async function recordDeliveryOpened({ deliveryId, inboxItemId, endpointId = null, metadata = {} }) {
  if (!deliveryId || !inboxItemId) return null;
  await appendDeliveryReceipt({
    deliveryId,
    inboxItemId,
    endpointId,
    receiptType: "opened",
    metadata,
  });
  if (endpointId) {
    await db.query(
      `UPDATE notification_endpoints
          SET last_opened_at = now(),
              last_delivery_state = 'opened',
              last_delivery_at = now(),
              updated_at = now()
        WHERE id = $1`,
      [endpointId],
    );
  }
  return true;
}

module.exports = {
  MAX_DELIVERY_ATTEMPTS,
  computeRetryDelayMs,
  queuePushDeliveriesForItem,
  claimQueuedNotificationDeliveries,
  processQueuedNotificationDelivery,
  processNotificationQueueBatch,
  sweepDisabledEndpoints,
  appendDeliveryAttempt,
  appendDeliveryReceipt,
  recordDeliveryOpened,
};
