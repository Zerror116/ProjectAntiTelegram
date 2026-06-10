CREATE INDEX IF NOT EXISTS idx_messages_chat_created_id_unread_eligible
  ON messages(chat_id, created_at, id)
  WHERE sender_id IS NOT NULL
     OR COALESCE(meta->>'kind', '') = 'reserved_order_item';

CREATE INDEX IF NOT EXISTS idx_user_chat_state_user_chat_last_read
  ON user_chat_state(user_id, chat_id, last_read_message_id);

CREATE INDEX IF NOT EXISTS idx_products_created_by_created_at
  ON products(created_by, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_product_publication_queue_queued_by_created_at
  ON product_publication_queue(queued_by, created_at DESC);
