CREATE TABLE IF NOT EXISTS message_reactions (
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_message_reactions_message
  ON message_reactions(message_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_message_reactions_user
  ON message_reactions(user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS message_edits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  edited_by UUID REFERENCES users(id) ON DELETE SET NULL,
  editor_role TEXT,
  previous_text TEXT NOT NULL,
  edited_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_message_edits_message
  ON message_edits(message_id, edited_at DESC);
