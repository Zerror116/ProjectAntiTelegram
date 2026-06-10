-- Existing members created before user_chat_state rollout should not receive
-- historical unread badges months later. Future messages remain unread normally.
WITH latest_visible_message AS (
  SELECT cm.user_id,
         cm.chat_id,
         latest.id AS message_id
    FROM chat_members cm
    LEFT JOIN user_chat_state ucs
      ON ucs.user_id = cm.user_id
     AND ucs.chat_id = cm.chat_id
    LEFT JOIN LATERAL (
      SELECT m.id
        FROM messages m
       WHERE m.chat_id = cm.chat_id
         AND NOT (COALESCE(m.meta->'hidden_for', '[]'::jsonb) ? cm.user_id::text)
         AND COALESCE((m.meta->>'hidden_for_all')::boolean, false) = false
       ORDER BY m.created_at DESC, m.id DESC
       LIMIT 1
    ) latest ON true
   WHERE ucs.user_id IS NULL
)
INSERT INTO user_chat_state (
  user_id,
  chat_id,
  last_read_message_id,
  last_seen_message_id,
  created_at,
  updated_at
)
SELECT user_id,
       chat_id,
       message_id,
       message_id,
       now(),
       now()
  FROM latest_visible_message
ON CONFLICT (user_id, chat_id) DO NOTHING;

-- Old chat inbox rows duplicated chat unread state. Once historical read state
-- is normalized, keep only future chat events as unread.
UPDATE notification_inbox_items
   SET status = 'read',
       read_at = COALESCE(read_at, now()),
       updated_at = now()
 WHERE category = 'chat'
   AND status = 'unread'
   AND created_at < now() - interval '1 minute';
