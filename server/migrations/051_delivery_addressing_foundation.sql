ALTER TABLE user_delivery_addresses
  ADD COLUMN IF NOT EXISTS address_structured JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS provider TEXT,
  ADD COLUMN IF NOT EXISTS provider_address_id TEXT,
  ADD COLUMN IF NOT EXISTS validation_status TEXT NOT NULL DEFAULT 'unverified',
  ADD COLUMN IF NOT EXISTS validation_confidence TEXT,
  ADD COLUMN IF NOT EXISTS point_source TEXT NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS mismatch_distance_meters INTEGER,
  ADD COLUMN IF NOT EXISTS delivery_zone_id TEXT,
  ADD COLUMN IF NOT EXISTS delivery_zone_label TEXT,
  ADD COLUMN IF NOT EXISTS delivery_zone_status TEXT NOT NULL DEFAULT 'unchecked';

ALTER TABLE delivery_batch_customers
  ADD COLUMN IF NOT EXISTS address_structured JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS provider TEXT,
  ADD COLUMN IF NOT EXISTS provider_address_id TEXT,
  ADD COLUMN IF NOT EXISTS validation_status TEXT NOT NULL DEFAULT 'unverified',
  ADD COLUMN IF NOT EXISTS validation_confidence TEXT,
  ADD COLUMN IF NOT EXISTS point_source TEXT NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS mismatch_distance_meters INTEGER,
  ADD COLUMN IF NOT EXISTS delivery_zone_id TEXT,
  ADD COLUMN IF NOT EXISTS delivery_zone_label TEXT,
  ADD COLUMN IF NOT EXISTS delivery_zone_status TEXT NOT NULL DEFAULT 'unchecked',
  ADD COLUMN IF NOT EXISTS entrance TEXT,
  ADD COLUMN IF NOT EXISTS comment TEXT;

UPDATE user_delivery_addresses
SET address_structured = jsonb_build_object(
      'full_text', COALESCE(address_text, ''),
      'entrance_or_hint', COALESCE(entrance, ''),
      'comment', COALESCE(comment, '')
    )
WHERE address_structured = '{}'::jsonb
  AND (
    COALESCE(address_text, '') <> ''
    OR COALESCE(entrance, '') <> ''
    OR COALESCE(comment, '') <> ''
  );

UPDATE delivery_batch_customers
SET address_structured = jsonb_build_object(
      'full_text', COALESCE(address_text, ''),
      'entrance_or_hint', COALESCE(entrance, ''),
      'comment', COALESCE(comment, ''),
      'notes', COALESCE(notes, '')
    )
WHERE address_structured = '{}'::jsonb
  AND (
    COALESCE(address_text, '') <> ''
    OR COALESCE(entrance, '') <> ''
    OR COALESCE(comment, '') <> ''
    OR COALESCE(notes, '') <> ''
  );

CREATE INDEX IF NOT EXISTS idx_user_delivery_addresses_provider_id
ON user_delivery_addresses(user_id, provider, provider_address_id);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_zone_status
ON delivery_batch_customers(batch_id, delivery_zone_status, updated_at DESC);
