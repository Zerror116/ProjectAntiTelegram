ALTER TABLE cart_items
ADD COLUMN IF NOT EXISTS reserved_sent_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_cart_items_reserved_sent_at
ON cart_items(reserved_sent_at);

CREATE TABLE IF NOT EXISTS user_shelves (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  shelf_number INTEGER NOT NULL CHECK (shelf_number > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_shelves_number
ON user_shelves(shelf_number);

