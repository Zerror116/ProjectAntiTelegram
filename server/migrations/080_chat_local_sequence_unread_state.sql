ALTER TABLE chats
  ADD COLUMN IF NOT EXISTS last_seq BIGINT NOT NULL DEFAULT 0;

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS chat_seq BIGINT;

ALTER TABLE user_chat_state
  ADD COLUMN IF NOT EXISTS last_read_chat_seq BIGINT NOT NULL DEFAULT 0;

WITH per_chat AS (
  SELECT chat_id, COALESCE(MAX(chat_seq), 0) AS max_seq
  FROM messages
  GROUP BY chat_id
),
ranked AS (
  SELECT m.id,
         COALESCE(pc.max_seq, 0)
           + row_number() OVER (PARTITION BY m.chat_id ORDER BY m.created_at ASC, m.id ASC) AS next_seq
  FROM messages m
  LEFT JOIN per_chat pc ON pc.chat_id = m.chat_id
  WHERE m.chat_seq IS NULL
)
UPDATE messages m
   SET chat_seq = ranked.next_seq
  FROM ranked
 WHERE m.id = ranked.id
   AND m.chat_seq IS NULL;

UPDATE chats c
   SET last_seq = COALESCE(message_seq.max_seq, 0)
  FROM (
    SELECT chat_id, MAX(chat_seq) AS max_seq
    FROM messages
    GROUP BY chat_id
  ) AS message_seq
 WHERE c.id = message_seq.chat_id
   AND c.last_seq < COALESCE(message_seq.max_seq, 0);

UPDATE user_chat_state ucs
   SET last_read_chat_seq = COALESCE(m.chat_seq, 0)
  FROM messages m
 WHERE ucs.last_read_message_id = m.id
   AND ucs.chat_id = m.chat_id
   AND ucs.last_read_chat_seq = 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_chat_chat_seq
  ON messages(chat_id, chat_seq)
  WHERE chat_seq IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messages_chat_seq_unread_eligible
  ON messages(chat_id, chat_seq)
  WHERE chat_seq IS NOT NULL
    AND (
      sender_id IS NOT NULL
      OR COALESCE(meta->>'kind', '') = 'reserved_order_item'
    )
    AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false;

CREATE INDEX IF NOT EXISTS idx_messages_chat_seq_unread_eligible_cover
  ON messages(chat_id, chat_seq, sender_id)
  INCLUDE (id, created_at)
  WHERE chat_seq IS NOT NULL
    AND (
      sender_id IS NOT NULL
      OR COALESCE(meta->>'kind', '') = 'reserved_order_item'
    )
    AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false;

CREATE INDEX IF NOT EXISTS idx_messages_chat_visible_created_desc
  ON messages(chat_id, created_at DESC, id DESC)
  WHERE COALESCE((meta->>'hidden_for_all')::boolean, false) = false;

CREATE INDEX IF NOT EXISTS idx_user_chat_state_user_chat_read_seq
  ON user_chat_state(user_id, chat_id, last_read_chat_seq);

CREATE OR REPLACE FUNCTION assign_message_chat_seq()
RETURNS TRIGGER AS $$
DECLARE
  next_seq BIGINT;
BEGIN
  IF NEW.chat_seq IS NOT NULL THEN
    UPDATE chats
       SET last_seq = GREATEST(last_seq, NEW.chat_seq)
     WHERE id = NEW.chat_id;
    RETURN NEW;
  END IF;

  UPDATE chats
     SET last_seq = last_seq + 1
   WHERE id = NEW.chat_id
   RETURNING last_seq INTO next_seq;

  NEW.chat_seq = next_seq;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_messages_assign_chat_seq ON messages;

CREATE TRIGGER trg_messages_assign_chat_seq
  BEFORE INSERT ON messages
  FOR EACH ROW
  EXECUTE FUNCTION assign_message_chat_seq();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM messages WHERE chat_seq IS NULL LIMIT 1) THEN
    ALTER TABLE messages ALTER COLUMN chat_seq SET NOT NULL;
  END IF;
END $$;
