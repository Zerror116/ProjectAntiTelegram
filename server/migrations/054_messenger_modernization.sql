CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS direct_message_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  requester_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'declined')),
  first_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  cooldown_until TIMESTAMPTZ,
  responded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT direct_message_requests_not_self
    CHECK (requester_id <> target_user_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_direct_message_requests_chat
  ON direct_message_requests(chat_id);

CREATE INDEX IF NOT EXISTS idx_direct_message_requests_target
  ON direct_message_requests(target_user_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_direct_message_requests_requester
  ON direct_message_requests(requester_id, status, updated_at DESC);

CREATE TABLE IF NOT EXISTS user_messenger_preferences (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  allow_unknown_dm_requests BOOLEAN NOT NULL DEFAULT true,
  allow_tenant_first_contact BOOLEAN NOT NULL DEFAULT true,
  send_read_receipts BOOLEAN NOT NULL DEFAULT true,
  default_disappearing_timer TEXT NOT NULL DEFAULT 'off'
    CHECK (default_disappearing_timer IN ('off', '24h', '7d', '30d')),
  allow_listen_once_voice BOOLEAN NOT NULL DEFAULT true,
  playback_speed TEXT NOT NULL DEFAULT '1.0'
    CHECK (playback_speed IN ('1.0', '1.5', '2.0')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS message_attachments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  attachment_type TEXT NOT NULL
    CHECK (attachment_type IN ('image', 'video', 'voice', 'file')),
  sort_order INTEGER NOT NULL DEFAULT 0,
  media_group_id TEXT,
  storage_url TEXT NOT NULL,
  file_name TEXT,
  mime_type TEXT,
  file_size BIGINT,
  width INTEGER,
  height INTEGER,
  aspect_ratio NUMERIC(12, 4),
  duration_ms INTEGER,
  preprocess_tag TEXT,
  quality_mode TEXT NOT NULL DEFAULT 'standard'
    CHECK (quality_mode IN ('standard', 'hd', 'file')),
  is_video_note BOOLEAN NOT NULL DEFAULT false,
  is_listen_once BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_message_attachments_message
  ON message_attachments(message_id, sort_order, created_at);

CREATE INDEX IF NOT EXISTS idx_message_attachments_group
  ON message_attachments(media_group_id, sort_order, created_at);

CREATE TABLE IF NOT EXISTS message_attachment_receipts (
  attachment_id UUID NOT NULL REFERENCES message_attachments(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL
    CHECK (status IN ('listen_once_consumed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (attachment_id, user_id, status)
);

CREATE INDEX IF NOT EXISTS idx_message_attachment_receipts_user
  ON message_attachment_receipts(user_id, created_at DESC);
