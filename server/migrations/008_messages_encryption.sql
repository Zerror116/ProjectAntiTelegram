-- server/migrations/008_messages_encryption.sql
ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS text_enc BYTEA,
  ADD COLUMN IF NOT EXISTS iv BYTEA,
  ADD COLUMN IF NOT EXISTS tag BYTEA;

CREATE INDEX IF NOT EXISTS idx_messages_chat_id_created_at ON messages(chat_id, created_at DESC);
