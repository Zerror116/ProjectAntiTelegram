ALTER TABLE IF EXISTS cart_items
  ADD COLUMN IF NOT EXISTS processing_mode TEXT NOT NULL DEFAULT 'standard';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'cart_items_processing_mode_check'
      AND conrelid = 'cart_items'::regclass
  ) THEN
    ALTER TABLE cart_items
      ADD CONSTRAINT cart_items_processing_mode_check
      CHECK (processing_mode IN ('standard', 'oversize'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_cart_items_processing_mode
  ON cart_items(processing_mode);
