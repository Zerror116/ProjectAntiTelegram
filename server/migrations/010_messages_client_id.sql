-- server/migrations/010_messages_client_id.sql
ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS client_msg_id UUID NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_messages_client_msg_id ON messages(client_msg_id) WHERE client_msg_id IS NOT NULL;
