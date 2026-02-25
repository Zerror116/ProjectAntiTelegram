-- server/migrations/006_add_phones_index_and_phone_table.sql
ALTER TABLE IF EXISTS phones
  ADD COLUMN IF NOT EXISTS phone TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_phones_user_id ON phones(user_id);
CREATE INDEX IF NOT EXISTS idx_phones_status ON phones(status);
