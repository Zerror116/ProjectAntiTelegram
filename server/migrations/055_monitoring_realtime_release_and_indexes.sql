CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER TABLE monitoring_events
  ADD COLUMN IF NOT EXISTS subsystem TEXT,
  ADD COLUMN IF NOT EXISTS platform TEXT,
  ADD COLUMN IF NOT EXISTS app_version TEXT,
  ADD COLUMN IF NOT EXISTS app_build INTEGER,
  ADD COLUMN IF NOT EXISTS user_role TEXT,
  ADD COLUMN IF NOT EXISTS tenant_code TEXT,
  ADD COLUMN IF NOT EXISTS device_label TEXT,
  ADD COLUMN IF NOT EXISTS release_channel TEXT,
  ADD COLUMN IF NOT EXISTS session_state TEXT;

CREATE INDEX IF NOT EXISTS idx_monitoring_events_subsystem_created
  ON monitoring_events(subsystem, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_monitoring_events_platform_created
  ON monitoring_events(platform, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_monitoring_events_code_created
  ON monitoring_events(code, created_at DESC);

CREATE TABLE IF NOT EXISTS ops_release_checks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  scope TEXT NOT NULL
    CHECK (scope IN ('deploy', 'android_release', 'after_deploy_smoke', 'nightly_audit', 'manual')),
  status TEXT NOT NULL
    CHECK (status IN ('pass', 'warn', 'fail')),
  title TEXT NOT NULL,
  target TEXT,
  version_name TEXT,
  build_number INTEGER,
  summary TEXT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ops_release_checks_scope_created
  ON ops_release_checks(scope, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ops_release_checks_status_created
  ON ops_release_checks(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ops_release_checks_tenant_created
  ON ops_release_checks(tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_messages_chat_created_id_v2
  ON messages(chat_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_messages_text_trgm
  ON messages USING gin (LOWER(COALESCE(text, '')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_messages_text_fts
  ON messages USING gin (to_tsvector('simple', COALESCE(text, '')));

CREATE INDEX IF NOT EXISTS idx_products_title_trgm
  ON products USING gin (LOWER(COALESCE(title, '')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_products_description_trgm
  ON products USING gin (LOWER(COALESCE(description, '')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_products_code_trgm
  ON products USING gin (LOWER(COALESCE(product_code::text, '')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_users_name_trgm
  ON users USING gin (LOWER(COALESCE(name, '')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_users_email_trgm
  ON users USING gin (LOWER(COALESCE(email, '')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_phones_digits_trgm
  ON phones USING gin (regexp_replace(COALESCE(phone, ''), '\\D', '', 'g') gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_product_publication_queue_status_created_by
  ON product_publication_queue(status, created_at DESC, queued_by);

CREATE INDEX IF NOT EXISTS idx_message_reads_user_chat_message
  ON message_reads(user_id, chat_id, message_id, read_at DESC);
