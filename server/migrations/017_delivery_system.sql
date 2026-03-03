CREATE TABLE IF NOT EXISTS system_settings (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES users(id) ON DELETE SET NULL
);

INSERT INTO system_settings (key, value)
VALUES ('delivery', '{"threshold_amount": 1500}'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS user_delivery_addresses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  label TEXT,
  address_text TEXT,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  entrance TEXT,
  floor TEXT,
  apartment TEXT,
  comment TEXT,
  is_default BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_delivery_addresses_user
ON user_delivery_addresses(user_id, updated_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_delivery_addresses_default
ON user_delivery_addresses(user_id)
WHERE is_default = true;

CREATE TABLE IF NOT EXISTS delivery_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_date DATE NOT NULL,
  delivery_label TEXT NOT NULL,
  threshold_amount NUMERIC(12,2) NOT NULL DEFAULT 1500,
  status TEXT NOT NULL DEFAULT 'calling',
  courier_count INTEGER NOT NULL DEFAULT 0 CHECK (courier_count >= 0),
  courier_names JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  confirmed_at TIMESTAMPTZ,
  handed_off_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_delivery_batches_status_date
ON delivery_batches(status, delivery_date DESC, created_at DESC);

CREATE TABLE IF NOT EXISTS delivery_batch_customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id UUID NOT NULL REFERENCES delivery_batches(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_name TEXT,
  customer_phone TEXT,
  processed_sum NUMERIC(12,2) NOT NULL DEFAULT 0,
  processed_items_count INTEGER NOT NULL DEFAULT 0,
  shelf_number INTEGER,
  call_status TEXT NOT NULL DEFAULT 'pending',
  delivery_status TEXT NOT NULL DEFAULT 'awaiting_call',
  address_id UUID REFERENCES user_delivery_addresses(id) ON DELETE SET NULL,
  address_text TEXT,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  courier_slot INTEGER,
  courier_name TEXT,
  courier_code TEXT,
  route_order INTEGER,
  eta_from TIMESTAMPTZ,
  eta_to TIMESTAMPTZ,
  package_places INTEGER NOT NULL DEFAULT 1 CHECK (package_places > 0),
  bulky_places INTEGER NOT NULL DEFAULT 0 CHECK (bulky_places >= 0),
  bulky_note TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(batch_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_batch
ON delivery_batch_customers(batch_id, route_order, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_user
ON delivery_batch_customers(user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS delivery_batch_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id UUID NOT NULL REFERENCES delivery_batches(id) ON DELETE CASCADE,
  batch_customer_id UUID NOT NULL REFERENCES delivery_batch_customers(id) ON DELETE CASCADE,
  cart_item_id UUID NOT NULL UNIQUE REFERENCES cart_items(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total NUMERIC(12,2) NOT NULL DEFAULT 0,
  product_code INTEGER,
  product_title TEXT,
  product_description TEXT,
  product_image_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_items_batch
ON delivery_batch_items(batch_id, batch_customer_id);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_items_user
ON delivery_batch_items(user_id, created_at DESC);
