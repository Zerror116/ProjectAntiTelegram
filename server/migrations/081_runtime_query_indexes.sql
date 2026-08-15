CREATE INDEX IF NOT EXISTS idx_chat_members_user_chat_joined
  ON chat_members(user_id, chat_id)
  INCLUDE (joined_at, role);

CREATE INDEX IF NOT EXISTS idx_notification_inbox_user_category_created
  ON notification_inbox_items(user_id, category, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_inbox_default_user_created
  ON notification_inbox_items(user_id, created_at DESC)
  WHERE COALESCE(inbox_visibility, 'default') = 'default';

CREATE INDEX IF NOT EXISTS idx_notification_inbox_default_unread_user_category
  ON notification_inbox_items(user_id, category, created_at DESC)
  WHERE status = 'unread'
    AND COALESCE(inbox_visibility, 'default') = 'default';

CREATE INDEX IF NOT EXISTS idx_cart_items_delivery_status_user_updated
  ON cart_items(status, user_id, updated_at DESC)
  INCLUDE (product_id, quantity, processing_mode, custom_price)
  WHERE status IN (
    'pending_processing',
    'pending',
    'processed',
    'preparing_delivery',
    'handing_to_courier',
    'in_delivery'
  );
