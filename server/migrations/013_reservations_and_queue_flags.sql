ALTER TABLE product_publication_queue
ADD COLUMN IF NOT EXISTS is_sent BOOLEAN NOT NULL DEFAULT false;

UPDATE product_publication_queue
SET is_sent = true
WHERE status = 'published';

CREATE TABLE IF NOT EXISTS reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  cart_item_id UUID UNIQUE REFERENCES cart_items(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  is_fulfilled BOOLEAN NOT NULL DEFAULT false,
  is_sent BOOLEAN NOT NULL DEFAULT false,
  reserved_channel_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  fulfilled_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_reservations_status
ON reservations(is_fulfilled, is_sent, created_at);

CREATE INDEX IF NOT EXISTS idx_reservations_user_id
ON reservations(user_id);

CREATE INDEX IF NOT EXISTS idx_reservations_product_id
ON reservations(product_id);

INSERT INTO reservations (
  id,
  user_id,
  product_id,
  cart_item_id,
  quantity,
  is_fulfilled,
  is_sent,
  created_at,
  updated_at,
  fulfilled_at,
  sent_at
)
SELECT
  gen_random_uuid(),
  c.user_id,
  c.product_id,
  c.id,
  c.quantity,
  CASE WHEN c.status IN ('processed', 'in_delivery') THEN true ELSE false END,
  CASE WHEN c.reserved_sent_at IS NOT NULL THEN true ELSE false END,
  c.created_at,
  c.updated_at,
  CASE WHEN c.status IN ('processed', 'in_delivery') THEN c.updated_at ELSE NULL END,
  c.reserved_sent_at
FROM cart_items c
WHERE NOT EXISTS (
  SELECT 1
  FROM reservations r
  WHERE r.cart_item_id = c.id
);
