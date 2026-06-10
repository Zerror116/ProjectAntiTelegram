-- Tenant workflow extensions: cart retention, self-pickup assembly, bulky products.

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS is_bulky BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_products_is_bulky
  ON products(is_bulky)
  WHERE is_bulky = true;

ALTER TABLE product_publication_queue
  ADD COLUMN IF NOT EXISTS is_bulky BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_product_publication_queue_is_bulky
  ON product_publication_queue(is_bulky)
  WHERE is_bulky = true;

ALTER TABLE delivery_batch_customers
  ADD COLUMN IF NOT EXISTS self_pickup BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS route_excluded BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pickup_label TEXT;

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_self_pickup
  ON delivery_batch_customers(batch_id, self_pickup, route_excluded);
