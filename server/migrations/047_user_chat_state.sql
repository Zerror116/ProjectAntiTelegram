CREATE TABLE IF NOT EXISTS user_chat_state (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  last_read_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  last_seen_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  draft_text TEXT NOT NULL DEFAULT '',
  draft_updated_at TIMESTAMPTZ,
  scroll_anchor_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  scroll_anchor_offset DOUBLE PRECISION,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, chat_id)
);

CREATE INDEX IF NOT EXISTS idx_user_chat_state_chat
  ON user_chat_state(chat_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_chat_state_user_updated
  ON user_chat_state(user_id, updated_at DESC);
