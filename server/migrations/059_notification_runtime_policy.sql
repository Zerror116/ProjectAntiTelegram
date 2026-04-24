ALTER TABLE smart_notification_profiles
  ADD COLUMN IF NOT EXISTS message_preview_enabled BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_when_active BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS sound_enabled BOOLEAN NOT NULL DEFAULT true;
