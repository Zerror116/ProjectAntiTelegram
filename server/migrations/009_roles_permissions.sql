-- server/migrations/009_roles_permissions.sql

-- 1) users.role (если ещё нет)
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'client';

-- 2) chats: created_by и settings (если нужно)
ALTER TABLE chats
  ADD COLUMN IF NOT EXISTS created_by UUID NULL,
  ADD COLUMN IF NOT EXISTS settings JSONB DEFAULT '{}'::jsonb;

-- 3) chat_members: роль участника (owner/moderator/member)
ALTER TABLE chat_members
  ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'member';

-- 4) индекс для быстрого поиска участников
CREATE INDEX IF NOT EXISTS idx_chat_members_user_id ON chat_members(user_id);
CREATE INDEX IF NOT EXISTS idx_chats_created_by ON chats(created_by);

-- 5) (опционально) таблица permissions (если нужна централизованная модель)
CREATE TABLE IF NOT EXISTS permissions (
  id SERIAL PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  description TEXT
);

-- 6) seed common permissions (опционально)
INSERT INTO permissions (name, description) VALUES
  ('chat.create', 'Create chats'),
  ('chat.manage_members', 'Invite/remove members'),
  ('chat.edit_settings', 'Edit chat settings'),
  ('chat.delete_message', 'Delete messages'),
  ('chat.pin_message', 'Pin messages')
ON CONFLICT (name) DO NOTHING;
