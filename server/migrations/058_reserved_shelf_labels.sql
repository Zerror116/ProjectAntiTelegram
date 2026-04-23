ALTER TABLE user_shelves
ADD COLUMN IF NOT EXISTS shelf_label TEXT;

UPDATE user_shelves
SET shelf_label = COALESCE(NULLIF(BTRIM(shelf_label), ''), shelf_number::text)
WHERE shelf_number IS NOT NULL;

ALTER TABLE delivery_batch_customers
ADD COLUMN IF NOT EXISTS shelf_label TEXT;

UPDATE delivery_batch_customers
SET shelf_label = COALESCE(NULLIF(BTRIM(shelf_label), ''), shelf_number::text)
WHERE shelf_number IS NOT NULL;

ALTER TABLE user_shelves
ALTER COLUMN shelf_number DROP NOT NULL;

ALTER TABLE user_shelves
DROP CONSTRAINT IF EXISTS user_shelves_shelf_number_check;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_shelves_shelf_number_positive_or_null'
  ) THEN
    ALTER TABLE user_shelves
      ADD CONSTRAINT user_shelves_shelf_number_positive_or_null
      CHECK (shelf_number IS NULL OR shelf_number > 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_user_shelves_label
ON user_shelves(shelf_label);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_shelf_label
ON delivery_batch_customers(shelf_label);
