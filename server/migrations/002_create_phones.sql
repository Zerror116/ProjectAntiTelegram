-- server/migrations/002_create_phones.sql
CREATE TABLE IF NOT EXISTS phones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  phone TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending_verification',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  verified_at TIMESTAMP WITH TIME ZONE,
  CONSTRAINT fk_phones_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Уникальный индекс по user_id чтобы ON CONFLICT работал корректно
CREATE UNIQUE INDEX IF NOT EXISTS idx_phones_user_id ON phones(user_id);

CREATE INDEX IF NOT EXISTS idx_phones_status ON phones(status);
