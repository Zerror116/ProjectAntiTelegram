ALTER TABLE notification_endpoints
  ADD COLUMN IF NOT EXISTS app_runtime_policy JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS device_profile TEXT NOT NULL DEFAULT 'standard'
    CHECK (device_profile IN ('standard', 'constrained', 'aggressive_low_memory')),
  ADD COLUMN IF NOT EXISTS consecutive_failures INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS failure_backoff_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_delivery_state TEXT,
  ADD COLUMN IF NOT EXISTS last_delivery_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_opened_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_notification_endpoints_active_backoff
  ON notification_endpoints(is_active, failure_backoff_until NULLS FIRST, updated_at DESC);

ALTER TABLE notification_deliveries
  ADD COLUMN IF NOT EXISTS transport TEXT,
  ADD COLUMN IF NOT EXISTS delivery_key TEXT,
  ADD COLUMN IF NOT EXISTS queue_name TEXT NOT NULL DEFAULT 'push',
  ADD COLUMN IF NOT EXISTS attempt_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS last_attempt_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS worker_id TEXT;

DELETE FROM notification_deliveries d
USING notification_deliveries newer
WHERE d.id <> newer.id
  AND d.endpoint_id IS NOT NULL
  AND newer.endpoint_id IS NOT NULL
  AND d.inbox_item_id = newer.inbox_item_id
  AND d.endpoint_id = newer.endpoint_id
  AND d.channel = newer.channel
  AND (
    COALESCE(d.updated_at, d.created_at) < COALESCE(newer.updated_at, newer.created_at)
    OR (
      COALESCE(d.updated_at, d.created_at) = COALESCE(newer.updated_at, newer.created_at)
      AND d.id::text < newer.id::text
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_deliveries_inbox_endpoint_channel
  ON notification_deliveries(inbox_item_id, endpoint_id, channel)
  WHERE endpoint_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_queue_claim
  ON notification_deliveries(queue_name, state, next_attempt_at, processing_started_at, created_at)
  WHERE channel = 'push';

CREATE TABLE IF NOT EXISTS notification_delivery_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES notification_deliveries(id) ON DELETE CASCADE,
  inbox_item_id UUID NOT NULL REFERENCES notification_inbox_items(id) ON DELETE CASCADE,
  endpoint_id UUID REFERENCES notification_endpoints(id) ON DELETE SET NULL,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT,
  worker_id TEXT,
  attempt_no INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL
    CHECK (state IN ('started', 'provider_accepted', 'sent', 'delivered', 'opened', 'failed', 'skipped', 'disabled', 'expired')),
  error_message TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_notification_delivery_attempts_delivery_created
  ON notification_delivery_attempts(delivery_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_delivery_attempts_user_created
  ON notification_delivery_attempts(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS notification_delivery_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES notification_deliveries(id) ON DELETE CASCADE,
  inbox_item_id UUID NOT NULL REFERENCES notification_inbox_items(id) ON DELETE CASCADE,
  endpoint_id UUID REFERENCES notification_endpoints(id) ON DELETE SET NULL,
  receipt_type TEXT NOT NULL
    CHECK (receipt_type IN ('provider_accepted', 'delivered', 'opened', 'dismissed')),
  receipt_key TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notification_delivery_receipts_delivery_created
  ON notification_delivery_receipts(delivery_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_delivery_receipts_inbox_type_created
  ON notification_delivery_receipts(inbox_item_id, receipt_type, created_at DESC);
