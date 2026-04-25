ALTER TABLE product_publication_queue
  ADD COLUMN IF NOT EXISTS publish_batch_id UUID,
  ADD COLUMN IF NOT EXISTS publish_order INTEGER,
  ADD COLUMN IF NOT EXISTS publish_status TEXT,
  ADD COLUMN IF NOT EXISTS publish_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS publish_finished_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS publish_error_code TEXT,
  ADD COLUMN IF NOT EXISTS publish_error_message TEXT;

ALTER TABLE product_publication_queue
  DROP CONSTRAINT IF EXISTS product_publication_queue_publish_status_check;

ALTER TABLE product_publication_queue
  ADD CONSTRAINT product_publication_queue_publish_status_check
  CHECK (publish_status IN ('pending', 'queued', 'publishing', 'published', 'failed'));

UPDATE product_publication_queue
SET publish_status = CASE
  WHEN status = 'published' OR COALESCE(is_sent, false) = true THEN 'published'
  ELSE 'pending'
END
WHERE publish_status IS NULL;

ALTER TABLE product_publication_queue
  ALTER COLUMN publish_status SET DEFAULT 'pending';

CREATE TABLE IF NOT EXISTS channel_publication_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  tenant_id UUID REFERENCES tenants(id) ON DELETE SET NULL,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'completed', 'completed_with_errors', 'failed')),
  interval_ms INTEGER NOT NULL DEFAULT 2000,
  total_count INTEGER NOT NULL DEFAULT 0,
  published_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  current_queue_item_id UUID REFERENCES product_publication_queue(id) ON DELETE SET NULL,
  current_product_id UUID REFERENCES products(id) ON DELETE SET NULL,
  current_product_title TEXT,
  next_publish_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  worker_id TEXT,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.table_constraints
    WHERE constraint_name = 'product_publication_queue_publish_batch_id_fkey'
      AND table_name = 'product_publication_queue'
  ) THEN
    ALTER TABLE product_publication_queue
      ADD CONSTRAINT product_publication_queue_publish_batch_id_fkey
      FOREIGN KEY (publish_batch_id)
      REFERENCES channel_publication_batches(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_channel_publication_batches_active_channel
  ON channel_publication_batches(channel_id)
  WHERE status IN ('queued', 'running');

CREATE INDEX IF NOT EXISTS idx_channel_publication_batches_claim
  ON channel_publication_batches(status, next_publish_at, created_at, channel_id);

CREATE INDEX IF NOT EXISTS idx_channel_publication_batches_tenant_status
  ON channel_publication_batches(tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_product_publication_queue_batch_order
  ON product_publication_queue(publish_batch_id, publish_status, publish_order, created_at);

CREATE INDEX IF NOT EXISTS idx_product_publication_queue_channel_publish_status
  ON product_publication_queue(channel_id, publish_status, created_at);
