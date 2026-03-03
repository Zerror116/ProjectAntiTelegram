ALTER TABLE reservations
ADD COLUMN IF NOT EXISTS fulfilled_by_id UUID REFERENCES users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_reservations_fulfilled_by_id
ON reservations(fulfilled_by_id, fulfilled_at DESC);

UPDATE reservations r
SET fulfilled_by_id = NULLIF(m.meta->>'processed_by_id', '')::uuid
FROM messages m
WHERE r.fulfilled_by_id IS NULL
  AND r.reserved_channel_message_id = m.id
  AND COALESCE(m.meta->>'processed_by_id', '') <> '';

ALTER TABLE delivery_batches
ADD COLUMN IF NOT EXISTS assembled_by_id UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE delivery_batches
ADD COLUMN IF NOT EXISTS assembled_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_delivery_batches_assembled_by
ON delivery_batches(assembled_by_id, assembled_at DESC);

