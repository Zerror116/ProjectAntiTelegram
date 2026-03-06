-- server/migrations/027_support_tickets.sql

CREATE TABLE IF NOT EXISTS support_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL UNIQUE REFERENCES chats(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  assignee_id UUID REFERENCES users(id) ON DELETE SET NULL,
  assigned_role TEXT NOT NULL DEFAULT 'admin'
    CHECK (assigned_role IN ('worker', 'admin', 'tenant', 'creator')),
  category TEXT NOT NULL DEFAULT 'general'
    CHECK (category IN ('general', 'product', 'delivery', 'cart')),
  subject TEXT,
  product_id UUID REFERENCES products(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'waiting_customer', 'resolved', 'archived')),
  last_customer_message_at TIMESTAMPTZ,
  last_staff_message_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  resolved_at TIMESTAMPTZ,
  archived_at TIMESTAMPTZ,
  archive_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_support_tickets_tenant_status
  ON support_tickets(tenant_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_support_tickets_customer
  ON support_tickets(customer_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_support_tickets_assignee
  ON support_tickets(assignee_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_support_tickets_category
  ON support_tickets(category, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_support_tickets_created
  ON support_tickets(created_at DESC);
