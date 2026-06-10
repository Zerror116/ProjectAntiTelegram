CREATE TABLE IF NOT EXISTS android_update_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT,
  tenant_id TEXT,
  event_type TEXT NOT NULL DEFAULT 'android_update_event',
  status TEXT,
  stage TEXT,
  error_code TEXT,
  error_message TEXT,
  app_version TEXT,
  app_build INTEGER,
  platform TEXT NOT NULL DEFAULT 'android',
  package_name TEXT,
  update_version TEXT,
  update_build INTEGER,
  required_update BOOLEAN,
  install_permission BOOLEAN,
  notification_permission BOOLEAN,
  device_model TEXT,
  manufacturer TEXT,
  android_sdk INTEGER,
  manifest_url TEXT,
  download_url TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_android_update_reports_created_at
  ON android_update_reports(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_android_update_reports_user_created_at
  ON android_update_reports(user_id, created_at DESC)
  WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_android_update_reports_error_created_at
  ON android_update_reports(error_code, created_at DESC)
  WHERE error_code IS NOT NULL AND btrim(error_code) <> '';
