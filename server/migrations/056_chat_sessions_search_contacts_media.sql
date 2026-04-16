CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS chat_upload_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_msg_id TEXT NOT NULL,
  attachment_kind TEXT NOT NULL CHECK (attachment_kind IN ('image','video','voice','file')),
  quality_mode TEXT NOT NULL DEFAULT 'standard' CHECK (quality_mode IN ('standard','hd','file')),
  original_file_name TEXT,
  mime_type TEXT,
  total_bytes BIGINT NOT NULL DEFAULT 0,
  uploaded_bytes BIGINT NOT NULL DEFAULT 0,
  sha256 TEXT,
  status TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created','uploading','uploaded','processing','ready','failed_retryable','failed_permanent','committed','aborted','expired')),
  storage_key TEXT,
  storage_url TEXT,
  storage_path TEXT,
  media_meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_error_code TEXT,
  last_error_message TEXT,
  expires_at TIMESTAMPTZ,
  committed_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ux_chat_upload_sessions_client UNIQUE (chat_id, user_id, client_msg_id, attachment_kind)
);

CREATE INDEX IF NOT EXISTS idx_chat_upload_sessions_user_status_created
  ON chat_upload_sessions(user_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_chat_upload_sessions_chat_status_created
  ON chat_upload_sessions(chat_id, status, created_at DESC);

ALTER TABLE message_attachments
  ADD COLUMN IF NOT EXISTS processing_state TEXT NOT NULL DEFAULT 'ready' CHECK (processing_state IN ('processing','ready','failed')),
  ADD COLUMN IF NOT EXISTS checksum_sha256 TEXT,
  ADD COLUMN IF NOT EXISTS preview_image_url TEXT,
  ADD COLUMN IF NOT EXISTS preview_width INTEGER,
  ADD COLUMN IF NOT EXISTS preview_height INTEGER,
  ADD COLUMN IF NOT EXISTS waveform_peaks JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS extra_meta JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_message_attachments_processing_state_created
  ON message_attachments(processing_state, created_at DESC);

CREATE TABLE IF NOT EXISTS message_search_documents (
  message_id UUID PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  sender_id UUID REFERENCES users(id) ON DELETE SET NULL,
  search_text_normalized TEXT NOT NULL DEFAULT '',
  caption_normalized TEXT NOT NULL DEFAULT '',
  attachment_kinds TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_message_search_documents_chat_created
  ON message_search_documents(chat_id, created_at DESC, message_id);

CREATE INDEX IF NOT EXISTS idx_message_search_documents_sender_created
  ON message_search_documents(sender_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_message_search_documents_text_trgm
  ON message_search_documents USING gin (search_text_normalized gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_message_search_documents_caption_trgm
  ON message_search_documents USING gin (caption_normalized gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_message_search_documents_attachments_gin
  ON message_search_documents USING gin (attachment_kinds);

ALTER TABLE user_messenger_preferences
  ADD COLUMN IF NOT EXISTS media_auto_download_images TEXT NOT NULL DEFAULT 'wifi_cellular' CHECK (media_auto_download_images IN ('never','wifi','wifi_cellular')),
  ADD COLUMN IF NOT EXISTS media_auto_download_audio TEXT NOT NULL DEFAULT 'wifi_cellular' CHECK (media_auto_download_audio IN ('never','wifi','wifi_cellular')),
  ADD COLUMN IF NOT EXISTS media_auto_download_video TEXT NOT NULL DEFAULT 'wifi' CHECK (media_auto_download_video IN ('never','wifi','wifi_cellular')),
  ADD COLUMN IF NOT EXISTS media_auto_download_documents TEXT NOT NULL DEFAULT 'wifi' CHECK (media_auto_download_documents IN ('never','wifi','wifi_cellular')),
  ADD COLUMN IF NOT EXISTS media_send_quality_wifi TEXT NOT NULL DEFAULT 'hd' CHECK (media_send_quality_wifi IN ('standard','hd','file')),
  ADD COLUMN IF NOT EXISTS media_send_quality_cellular TEXT NOT NULL DEFAULT 'standard' CHECK (media_send_quality_cellular IN ('standard','hd','file'));

CREATE TABLE IF NOT EXISTS user_phonebook_match_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  hash_count INTEGER NOT NULL DEFAULT 0,
  matched_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_phonebook_match_snapshots_user_created
  ON user_phonebook_match_snapshots(user_id, created_at DESC);
