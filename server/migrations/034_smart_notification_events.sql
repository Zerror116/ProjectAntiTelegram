-- server/migrations/034_smart_notification_events.sql

CREATE TABLE IF NOT EXISTS smart_notification_events (
  id UUID PRIMARY KEY,
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  profile_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL
    CHECK (event_type IN ('order', 'support', 'delivery')),
  priority TEXT NOT NULL
    CHECK (priority IN ('low', 'normal', 'high', 'critical')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_quiet BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_smart_notification_events_user_time
  ON smart_notification_events(profile_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_smart_notification_events_tenant_time
  ON smart_notification_events(tenant_id, created_at DESC);
