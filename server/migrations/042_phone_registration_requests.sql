CREATE TABLE IF NOT EXISTS phone_registration_requests (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone TEXT NOT NULL,
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  requester_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending',
  note TEXT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at TIMESTAMPTZ,
  decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
  CONSTRAINT phone_registration_requests_status_check
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  CONSTRAINT phone_registration_requests_distinct_users_check
    CHECK (owner_user_id <> requester_user_id)
);

CREATE INDEX IF NOT EXISTS idx_phone_registration_requests_owner_pending
  ON phone_registration_requests(owner_user_id, status, requested_at DESC);

CREATE INDEX IF NOT EXISTS idx_phone_registration_requests_requester
  ON phone_registration_requests(requester_user_id, requested_at DESC);

CREATE INDEX IF NOT EXISTS idx_phone_registration_requests_tenant_phone
  ON phone_registration_requests(tenant_id, phone, status, requested_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_phone_registration_requests_pending_unique
  ON phone_registration_requests(tenant_id, owner_user_id, requester_user_id, phone)
  WHERE status = 'pending';
