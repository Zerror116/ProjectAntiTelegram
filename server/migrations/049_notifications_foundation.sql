ALTER TABLE smart_notification_profiles
  ADD COLUMN IF NOT EXISTS categories JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS channels JSONB NOT NULL DEFAULT '{"push": true, "in_app": true, "email": false}'::jsonb,
  ADD COLUMN IF NOT EXISTS promo_opt_in BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updates_opt_in BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS digest_mode TEXT NOT NULL DEFAULT 'daily_non_urgent'
    CHECK (digest_mode IN ('off', 'daily_non_urgent', 'daily_all_delayed')),
  ADD COLUMN IF NOT EXISTS frequency_caps JSONB NOT NULL DEFAULT '{"promo_per_day": 2, "updates_per_day": 3, "low_priority_per_day": 5}'::jsonb,
  ADD COLUMN IF NOT EXISTS badge_preferences JSONB NOT NULL DEFAULT '{"count_chat": true, "count_support": true, "count_reserved": true, "count_delivery": true, "count_security": true, "count_promo": false, "count_updates": false}'::jsonb;

CREATE TABLE IF NOT EXISTS notification_endpoints (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform TEXT NOT NULL DEFAULT 'unknown'
    CHECK (platform IN ('web', 'android', 'ios', 'macos', 'windows', 'linux', 'unknown')),
  transport TEXT NOT NULL DEFAULT 'device_heartbeat'
    CHECK (transport IN ('webpush', 'fcm', 'apns', 'device_heartbeat')),
  device_key TEXT,
  push_token TEXT,
  endpoint TEXT,
  subscription JSONB NOT NULL DEFAULT '{}'::jsonb,
  permission_state TEXT NOT NULL DEFAULT 'unknown'
    CHECK (permission_state IN ('unknown', 'unsupported', 'default', 'granted', 'denied', 'provisional')),
  capabilities JSONB NOT NULL DEFAULT '{}'::jsonb,
  app_version TEXT,
  locale TEXT,
  timezone TEXT,
  user_agent TEXT,
  test_only BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_success_at TIMESTAMPTZ,
  last_failure_at TIMESTAMPTZ,
  last_failure_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notification_endpoints_user_active
  ON notification_endpoints(user_id, is_active, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_endpoints_tenant_platform
  ON notification_endpoints(tenant_id, platform, updated_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_endpoints_endpoint
  ON notification_endpoints(endpoint)
  WHERE endpoint IS NOT NULL AND btrim(endpoint) <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_endpoints_push_token
  ON notification_endpoints(push_token)
  WHERE push_token IS NOT NULL AND btrim(push_token) <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_endpoints_user_device_transport
  ON notification_endpoints(user_id, platform, transport, device_key)
  WHERE device_key IS NOT NULL AND btrim(device_key) <> '';

CREATE TABLE IF NOT EXISTS notification_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_by_role TEXT,
  kind TEXT NOT NULL DEFAULT 'promo'
    CHECK (kind IN ('promo', 'test')),
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'queued', 'sent', 'error')),
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  deep_link TEXT,
  media JSONB NOT NULL DEFAULT '{}'::jsonb,
  audience_filter JSONB NOT NULL DEFAULT '{}'::jsonb,
  sent_count INTEGER NOT NULL DEFAULT 0,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  scheduled_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_notification_campaigns_tenant_created
  ON notification_campaigns(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_campaigns_creator_created
  ON notification_campaigns(created_by, created_at DESC);

CREATE TABLE IF NOT EXISTS notification_inbox_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category TEXT NOT NULL
    CHECK (category IN ('chat', 'support', 'reserved', 'delivery', 'promo', 'updates', 'security')),
  priority TEXT NOT NULL DEFAULT 'normal'
    CHECK (priority IN ('low', 'normal', 'high', 'critical')),
  channel TEXT NOT NULL DEFAULT 'in_app'
    CHECK (channel IN ('push', 'in_app', 'email', 'mixed')),
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  deep_link TEXT,
  media JSONB NOT NULL DEFAULT '{}'::jsonb,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  dedupe_key TEXT,
  collapse_key TEXT,
  ttl_seconds INTEGER NOT NULL DEFAULT 3600,
  source_type TEXT NOT NULL DEFAULT 'generic',
  source_id TEXT,
  campaign_id UUID REFERENCES notification_campaigns(id) ON DELETE SET NULL,
  inbox_visibility TEXT NOT NULL DEFAULT 'default',
  status TEXT NOT NULL DEFAULT 'unread'
    CHECK (status IN ('unread', 'read', 'dismissed')),
  force_show BOOLEAN NOT NULL DEFAULT false,
  is_actionable BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  read_at TIMESTAMPTZ,
  dismissed_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_notification_inbox_user_created
  ON notification_inbox_items(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_inbox_user_status
  ON notification_inbox_items(user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_inbox_campaign
  ON notification_inbox_items(campaign_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_inbox_user_dedupe
  ON notification_inbox_items(user_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL AND btrim(dedupe_key) <> '';

CREATE TABLE IF NOT EXISTS notification_deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  inbox_item_id UUID NOT NULL REFERENCES notification_inbox_items(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  endpoint_id UUID REFERENCES notification_endpoints(id) ON DELETE SET NULL,
  channel TEXT NOT NULL
    CHECK (channel IN ('push', 'in_app', 'email')),
  provider TEXT,
  provider_message_id TEXT,
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'sent', 'provider_accepted', 'delivered', 'opened', 'dismissed', 'failed', 'expired', 'skipped')),
  error_message TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  opened_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  expired_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_inbox
  ON notification_deliveries(inbox_item_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_deliveries_user_state
  ON notification_deliveries(user_id, state, created_at DESC);
