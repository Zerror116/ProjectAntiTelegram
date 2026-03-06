ALTER TABLE products
  ADD COLUMN IF NOT EXISTS shelf_number INTEGER;

UPDATE products
SET shelf_number = COALESCE(shelf_number, 1)
WHERE shelf_number IS NULL;

ALTER TABLE products
  ALTER COLUMN shelf_number SET DEFAULT 1;

ALTER TABLE products
  ALTER COLUMN shelf_number SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'products_shelf_number_positive'
  ) THEN
    ALTER TABLE products
      ADD CONSTRAINT products_shelf_number_positive
      CHECK (shelf_number > 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_products_shelf_number
  ON products(shelf_number);
