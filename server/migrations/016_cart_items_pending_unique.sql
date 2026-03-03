DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'cart_items_user_id_product_id_key'
      AND conrelid = 'cart_items'::regclass
  ) THEN
    ALTER TABLE cart_items
      DROP CONSTRAINT cart_items_user_id_product_id_key;
  END IF;
END $$;

DROP INDEX IF EXISTS cart_items_user_id_product_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS idx_cart_items_pending_unique
  ON cart_items (user_id, product_id)
  WHERE status = 'pending_processing';
