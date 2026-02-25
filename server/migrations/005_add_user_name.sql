-- server/migrations/005_add_user_name.sql
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS name TEXT;
