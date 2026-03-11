ALTER TABLE IF EXISTS users
  ADD COLUMN IF NOT EXISTS block_reason TEXT;

ALTER TABLE IF EXISTS cart_items
  ADD COLUMN IF NOT EXISTS custom_price NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS custom_description TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'cart_items_custom_price_non_negative'
      AND conrelid = 'cart_items'::regclass
  ) THEN
    ALTER TABLE cart_items
      ADD CONSTRAINT cart_items_custom_price_non_negative
      CHECK (custom_price IS NULL OR custom_price >= 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_cart_items_user_status_updated
  ON cart_items(user_id, status, updated_at DESC);

ALTER TABLE IF EXISTS customer_claims
  ADD COLUMN IF NOT EXISTS customer_discount_status TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'customer_claims_discount_status_check'
      AND conrelid = 'customer_claims'::regclass
  ) THEN
    ALTER TABLE customer_claims
      ADD CONSTRAINT customer_claims_discount_status_check
      CHECK (
        customer_discount_status IS NULL
        OR customer_discount_status IN ('pending', 'accepted', 'rejected')
      );
  END IF;
END $$;

UPDATE customer_claims
SET customer_discount_status = 'pending',
    updated_at = now()
WHERE status = 'approved_discount'
  AND customer_discount_status IS NULL;
