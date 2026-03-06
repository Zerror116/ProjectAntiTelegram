-- server/migrations/028_customer_claims.sql

CREATE TABLE IF NOT EXISTS customer_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  cart_item_id UUID NOT NULL REFERENCES cart_items(id) ON DELETE CASCADE,
  product_id UUID REFERENCES products(id) ON DELETE SET NULL,
  delivery_batch_id UUID REFERENCES delivery_batches(id) ON DELETE SET NULL,
  claim_type TEXT NOT NULL
    CHECK (claim_type IN ('return', 'discount')),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN (
      'pending',
      'approved_return',
      'approved_discount',
      'rejected',
      'settled'
    )),
  description TEXT NOT NULL DEFAULT '',
  image_url TEXT,
  requested_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  approved_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  resolution_note TEXT,
  handled_by UUID REFERENCES users(id) ON DELETE SET NULL,
  handled_at TIMESTAMPTZ,
  settled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_customer_claims_user
  ON customer_claims(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_customer_claims_status
  ON customer_claims(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_customer_claims_tenant_status
  ON customer_claims(tenant_id, status, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_customer_claims_open_per_cart_item
  ON customer_claims(cart_item_id)
  WHERE status IN ('pending', 'approved_return', 'approved_discount');

ALTER TABLE delivery_batch_customers
  ADD COLUMN IF NOT EXISTS claim_return_sum NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS claim_discount_sum NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS claims_total NUMERIC(12,2) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_claims
  ON delivery_batch_customers(batch_id, claims_total, claim_return_sum, claim_discount_sum);
