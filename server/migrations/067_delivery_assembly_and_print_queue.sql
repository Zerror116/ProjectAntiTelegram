-- Delivery assembly workflow and account-scoped sticker print queue.

ALTER TABLE delivery_batch_customers
  ADD COLUMN IF NOT EXISTS assembly_status TEXT NOT NULL DEFAULT 'not_started',
  ADD COLUMN IF NOT EXISTS assembly_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS assembly_started_by UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS assembly_completed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS assembly_completed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS assembly_note TEXT,
  ADD COLUMN IF NOT EXISTS normal_stickers_requested INTEGER NOT NULL DEFAULT 0 CHECK (normal_stickers_requested >= 0),
  ADD COLUMN IF NOT EXISTS bulky_stickers_requested INTEGER NOT NULL DEFAULT 0 CHECK (bulky_stickers_requested >= 0);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'delivery_batch_customers_assembly_status_check'
      AND conrelid = 'delivery_batch_customers'::regclass
  ) THEN
    ALTER TABLE delivery_batch_customers
      DROP CONSTRAINT delivery_batch_customers_assembly_status_check;
  END IF;

  ALTER TABLE delivery_batch_customers
    ADD CONSTRAINT delivery_batch_customers_assembly_status_check
    CHECK (assembly_status IN ('not_started', 'assembling', 'assembled', 'issue'));
END $$;

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_assembly
  ON delivery_batch_customers(batch_id, assembly_status, updated_at DESC);

ALTER TABLE delivery_batch_items
  ADD COLUMN IF NOT EXISTS assembly_status TEXT NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS is_bulky BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS bulky_note TEXT,
  ADD COLUMN IF NOT EXISTS bulky_price NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS removed_reason TEXT,
  ADD COLUMN IF NOT EXISTS removed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS removed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS bulky_stickers_requested INTEGER NOT NULL DEFAULT 0 CHECK (bulky_stickers_requested >= 0);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'delivery_batch_items_assembly_status_check'
      AND conrelid = 'delivery_batch_items'::regclass
  ) THEN
    ALTER TABLE delivery_batch_items
      DROP CONSTRAINT delivery_batch_items_assembly_status_check;
  END IF;

  ALTER TABLE delivery_batch_items
    ADD CONSTRAINT delivery_batch_items_assembly_status_check
    CHECK (assembly_status IN ('pending', 'collected', 'removed'));
END $$;

CREATE INDEX IF NOT EXISTS idx_delivery_batch_items_assembly
  ON delivery_batch_items(batch_customer_id, assembly_status, is_bulky);

CREATE TABLE IF NOT EXISTS sticker_print_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  source_type TEXT NOT NULL DEFAULT 'delivery',
  source_id UUID,
  sticker_type TEXT NOT NULL CHECK (sticker_type IN ('delivery_normal', 'delivery_bulky')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'printing', 'printed', 'failed', 'cancelled')),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  error_text TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  printed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sticker_print_jobs_user_status
  ON sticker_print_jobs(user_id, status, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_sticker_print_jobs_tenant_status
  ON sticker_print_jobs(tenant_id, status, created_at DESC);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'sticker_print_jobs_status_check'
      AND conrelid = 'sticker_print_jobs'::regclass
  ) THEN
    ALTER TABLE sticker_print_jobs
      DROP CONSTRAINT sticker_print_jobs_status_check;
  END IF;

  ALTER TABLE sticker_print_jobs
    ADD CONSTRAINT sticker_print_jobs_status_check
    CHECK (status IN ('pending', 'printing', 'printed', 'failed', 'cancelled'));
END $$;

ALTER TABLE sticker_print_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE sticker_print_jobs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope_guard ON sticker_print_jobs;
CREATE POLICY tenant_scope_guard
ON sticker_print_jobs
USING (
  tenant_id IS NULL
  OR NULLIF(current_setting('app.tenant_id', true), '') IS NULL
  OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
)
WITH CHECK (
  tenant_id IS NULL
  OR NULLIF(current_setting('app.tenant_id', true), '') IS NULL
  OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
);
