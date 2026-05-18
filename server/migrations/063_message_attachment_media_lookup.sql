-- Speed up private chat media authorization.
-- Older checks scanned messages JSON with LIKE; this keeps a direct lookup key.

ALTER TABLE message_attachments
  ADD COLUMN IF NOT EXISTS storage_filename TEXT,
  ADD COLUMN IF NOT EXISTS preview_filename TEXT;

UPDATE message_attachments
SET storage_filename = NULLIF(
  regexp_replace(split_part(storage_url, '?', 1), '^.*/', ''),
  ''
)
WHERE storage_filename IS NULL
  AND COALESCE(BTRIM(storage_url), '') <> '';

UPDATE message_attachments
SET preview_filename = NULLIF(
  regexp_replace(split_part(preview_image_url, '?', 1), '^.*/', ''),
  ''
)
WHERE preview_filename IS NULL
  AND COALESCE(BTRIM(preview_image_url), '') <> '';

CREATE INDEX IF NOT EXISTS idx_message_attachments_type_storage_filename
  ON message_attachments(attachment_type, storage_filename)
  WHERE storage_filename IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_message_attachments_preview_filename
  ON message_attachments(preview_filename)
  WHERE preview_filename IS NOT NULL;
