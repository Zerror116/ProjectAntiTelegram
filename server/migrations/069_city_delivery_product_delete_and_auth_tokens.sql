-- City-specific delivery settings, safe product deletion, and legacy auth token cleanup.

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS deletion_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_products_deleted_at
  ON products(deleted_at)
  WHERE deleted_at IS NOT NULL;

ALTER TABLE delivery_batch_customers
  ADD COLUMN IF NOT EXISTS client_city TEXT,
  ADD COLUMN IF NOT EXISTS delivery_threshold_amount NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS delivery_fee_amount NUMERIC(12,2) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_city
  ON delivery_batch_customers(client_city);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.table_constraints
    WHERE table_schema = 'public'
      AND table_name = 'auth_email_tokens'
      AND constraint_name = 'auth_email_tokens_user_id_key'
  ) THEN
    ALTER TABLE auth_email_tokens
      DROP CONSTRAINT auth_email_tokens_user_id_key;
  END IF;
END $$;
