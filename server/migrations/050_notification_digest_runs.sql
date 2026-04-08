CREATE TABLE IF NOT EXISTS notification_digest_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  local_date DATE NOT NULL,
  timezone TEXT,
  digest_mode TEXT NOT NULL
    CHECK (digest_mode IN ('off', 'daily_non_urgent', 'daily_all_delayed')),
  item_count INTEGER NOT NULL DEFAULT 0,
  inbox_item_id UUID REFERENCES notification_inbox_items(id) ON DELETE SET NULL,
  sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_digest_runs_user_date_mode
  ON notification_digest_runs(user_id, local_date, digest_mode);

CREATE INDEX IF NOT EXISTS idx_notification_digest_runs_user_sent
  ON notification_digest_runs(user_id, sent_at DESC);
