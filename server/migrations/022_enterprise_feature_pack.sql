-- server/migrations/022_enterprise_feature_pack.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1) Закрепленные сообщения в чатах
CREATE TABLE IF NOT EXISTS chat_pins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  pinned_by UUID REFERENCES users(id) ON DELETE SET NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_chat_pins_active_per_chat
ON chat_pins(chat_id)
WHERE is_active = true;

CREATE UNIQUE INDEX IF NOT EXISTS ux_chat_pins_chat_message
ON chat_pins(chat_id, message_id);

CREATE INDEX IF NOT EXISTS idx_chat_pins_chat_updated
ON chat_pins(chat_id, updated_at DESC);

-- 2) Гибкие роли (шаблоны ролей + назначение пользователям)
CREATE TABLE IF NOT EXISTS role_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  permissions JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_system BOOLEAN NOT NULL DEFAULT false,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_role_templates_tenant_code
ON role_templates(tenant_id, code)
WHERE tenant_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_role_templates_global_code
ON role_templates(code)
WHERE tenant_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_role_templates_tenant
ON role_templates(tenant_id, is_system, updated_at DESC);

CREATE TABLE IF NOT EXISTS user_role_templates (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  template_id UUID NOT NULL REFERENCES role_templates(id) ON DELETE CASCADE,
  assigned_by UUID REFERENCES users(id) ON DELETE SET NULL,
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO role_templates (tenant_id, code, title, description, permissions, is_system)
VALUES
  (
    NULL,
    'client',
    'Клиент',
    'Покупка, корзина и поддержка',
    '{
      "chat.read": true,
      "chat.write.support": true,
      "chat.write.public": false,
      "cart.buy": true,
      "cart.cancel_pending": true,
      "delivery.respond": true
    }'::jsonb,
    true
  ),
  (
    NULL,
    'worker',
    'Работник',
    'Создание и модерация своих товарных постов',
    '{
      "chat.read": true,
      "chat.write.private": true,
      "product.create": true,
      "product.requeue": true,
      "product.edit.own_pending": true,
      "product.publish": false
    }'::jsonb,
    true
  ),
  (
    NULL,
    'admin',
    'Администратор',
    'Публикация товаров, обработка резервов и доставка',
    '{
      "chat.read": true,
      "chat.write.public": true,
      "chat.pin": true,
      "chat.delete.all": true,
      "product.publish": true,
      "reservation.fulfill": true,
      "delivery.manage": true
    }'::jsonb,
    true
  ),
  (
    NULL,
    'creator',
    'Создатель',
    'Полный доступ к функциям арендатора',
    '{
      "all": true
    }'::jsonb,
    true
  )
ON CONFLICT DO NOTHING;

-- 3) Управление сессиями
CREATE TABLE IF NOT EXISTS user_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_token_hash TEXT NOT NULL,
  device_fingerprint TEXT,
  user_agent TEXT,
  ip_address TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_sessions_token_hash
ON user_sessions(session_token_hash);

CREATE INDEX IF NOT EXISTS idx_user_sessions_user
ON user_sessions(user_id, is_active, last_seen_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_sessions_expires
ON user_sessions(expires_at, is_active);

-- 4) История статусов корзины (таймлайн статусов)
CREATE TABLE IF NOT EXISTS cart_status_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_item_id UUID NOT NULL REFERENCES cart_items(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  source TEXT,
  changed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cart_status_events_item
ON cart_status_events(cart_item_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cart_status_events_user
ON cart_status_events(user_id, created_at DESC);

-- 5) Персональные UI-предпочтения (палитра, плотность, анимации)
CREATE TABLE IF NOT EXISTS user_ui_preferences (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  light_seed_color TEXT,
  dark_seed_color TEXT,
  component_density TEXT NOT NULL DEFAULT 'comfortable'
    CHECK (component_density IN ('compact', 'comfortable', 'spacious')),
  animation_level TEXT NOT NULL DEFAULT 'normal'
    CHECK (animation_level IN ('off', 'reduced', 'normal')),
  skeletons_enabled BOOLEAN NOT NULL DEFAULT true,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 6) Мониторинг и алерты
CREATE TABLE IF NOT EXISTS monitoring_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  scope TEXT NOT NULL DEFAULT 'server',
  level TEXT NOT NULL DEFAULT 'info'
    CHECK (level IN ('info', 'warn', 'error', 'critical')),
  code TEXT,
  message TEXT NOT NULL,
  source TEXT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  resolved BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_monitoring_events_tenant_level
ON monitoring_events(tenant_id, level, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_monitoring_events_source
ON monitoring_events(source, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_monitoring_events_unresolved
ON monitoring_events(resolved, created_at DESC);

-- 7) Слоты доставки кнопками
CREATE TABLE IF NOT EXISTS delivery_slot_presets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  from_time TEXT,
  to_time TEXT,
  sort_order INTEGER NOT NULL DEFAULT 100,
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_system BOOLEAN NOT NULL DEFAULT false,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_delivery_slot_presets_scope
ON delivery_slot_presets(tenant_id, is_active, sort_order, created_at);

INSERT INTO delivery_slot_presets (tenant_id, title, from_time, to_time, sort_order, is_active, is_system)
VALUES
  (NULL, 'Утро', '10:00', '12:00', 10, true, true),
  (NULL, 'День', '12:00', '14:00', 20, true, true),
  (NULL, 'После обеда', '14:00', '16:00', 30, true, true),
  (NULL, 'После 16:00', '16:00', NULL, 40, true, true)
ON CONFLICT DO NOTHING;

-- 8) Шифрование чувствительных адресных данных
ALTER TABLE user_delivery_addresses
  ADD COLUMN IF NOT EXISTS address_ciphertext TEXT,
  ADD COLUMN IF NOT EXISTS address_iv TEXT,
  ADD COLUMN IF NOT EXISTS address_tag TEXT,
  ADD COLUMN IF NOT EXISTS address_encryption_version TEXT,
  ADD COLUMN IF NOT EXISTS address_encrypted_at TIMESTAMPTZ;

ALTER TABLE delivery_batch_customers
  ADD COLUMN IF NOT EXISTS address_ciphertext TEXT,
  ADD COLUMN IF NOT EXISTS address_iv TEXT,
  ADD COLUMN IF NOT EXISTS address_tag TEXT,
  ADD COLUMN IF NOT EXISTS address_encryption_version TEXT,
  ADD COLUMN IF NOT EXISTS address_encrypted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_user_delivery_addresses_cipher
ON user_delivery_addresses(user_id, address_encrypted_at DESC);

CREATE INDEX IF NOT EXISTS idx_delivery_batch_customers_cipher
ON delivery_batch_customers(batch_id, address_encrypted_at DESC);
