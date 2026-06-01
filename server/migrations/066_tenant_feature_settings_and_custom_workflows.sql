-- Tenant-scoped feature settings and additive tenant-specific workflows.
-- All feature flags are opt-in and default to disabled.

CREATE TABLE IF NOT EXISTS tenant_feature_settings (
  tenant_id UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  settings JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tenant_feature_settings_updated_at
  ON tenant_feature_settings(updated_at DESC);

ALTER TABLE tenant_invites
  ADD COLUMN IF NOT EXISTS settings JSONB NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS manual_shelf_label TEXT,
  ADD COLUMN IF NOT EXISTS shelf_floor TEXT,
  ADD COLUMN IF NOT EXISTS pickup_only BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE product_publication_queue
  ADD COLUMN IF NOT EXISTS pickup_only BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_products_pickup_only
  ON products(pickup_only);

CREATE TABLE IF NOT EXISTS cart_delivery_ready_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  address TEXT NOT NULL,
  total_sum NUMERIC(12,2) NOT NULL DEFAULT 0,
  has_bulky BOOLEAN NOT NULL DEFAULT false,
  has_pickup_only BOOLEAN NOT NULL DEFAULT false,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'acknowledged', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cart_delivery_ready_requests_tenant_status
  ON cart_delivery_ready_requests(tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cart_delivery_ready_requests_user
  ON cart_delivery_ready_requests(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS revision_delete_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  worker_id UUID REFERENCES users(id) ON DELETE SET NULL,
  product_id UUID REFERENCES products(id) ON DELETE CASCADE,
  queue_id UUID REFERENCES product_publication_queue(id) ON DELETE SET NULL,
  channel_id UUID REFERENCES chats(id) ON DELETE SET NULL,
  reason TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
  decided_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_revision_delete_requests_tenant_status
  ON revision_delete_requests(tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_revision_delete_requests_product
  ON revision_delete_requests(product_id, created_at DESC);

CREATE TABLE IF NOT EXISTS product_defect_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  product_id UUID REFERENCES products(id) ON DELETE SET NULL,
  reported_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  title TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  image_url TEXT,
  amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'archived')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_defect_reports_tenant_created
  ON product_defect_reports(tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_product_defect_reports_product
  ON product_defect_reports(product_id, created_at DESC);
