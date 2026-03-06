-- Basic contacts table for direct user-to-user messaging inside the same tenant.

CREATE TABLE IF NOT EXISTS user_contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  contact_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  alias_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT user_contacts_not_self CHECK (user_id <> contact_user_id),
  CONSTRAINT user_contacts_unique_pair UNIQUE (user_id, contact_user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_contacts_user
  ON user_contacts(user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_contacts_tenant
  ON user_contacts(tenant_id, user_id, updated_at DESC);
