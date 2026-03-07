-- server/migrations/033_business_ops_modules.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Финансы: себестоимость для расчета маржи/прибыли
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS cost_price NUMERIC(12,2) NOT NULL DEFAULT 0
  CHECK (cost_price >= 0);

CREATE INDEX IF NOT EXISTS idx_products_cost_price ON products(cost_price);

-- Умные уведомления (профиль пользователя)
CREATE TABLE IF NOT EXISTS smart_notification_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  enabled_types JSONB NOT NULL DEFAULT '{"order": true, "support": true, "delivery": true}'::jsonb,
  priorities JSONB NOT NULL DEFAULT '{"order": "high", "support": "normal", "delivery": "high"}'::jsonb,
  quiet_hours_enabled BOOLEAN NOT NULL DEFAULT false,
  quiet_from TEXT,
  quiet_to TEXT,
  test_mode BOOLEAN NOT NULL DEFAULT false,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_smart_notification_profiles_tenant
  ON smart_notification_profiles(tenant_id, updated_at DESC);

-- Антифрод: события и блокировки
CREATE TABLE IF NOT EXISTS antifraud_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  action_key TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'info'
    CHECK (severity IN ('info', 'warn', 'critical')),
  status TEXT NOT NULL DEFAULT 'logged'
    CHECK (status IN ('logged', 'blocked')),
  counter_window_seconds INTEGER NOT NULL DEFAULT 60,
  counter_value INTEGER,
  reason TEXT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_antifraud_events_tenant_action
  ON antifraud_events(tenant_id, action_key, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_antifraud_events_user_action
  ON antifraud_events(user_id, action_key, created_at DESC);

CREATE TABLE IF NOT EXISTS antifraud_blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  action_key TEXT,
  reason TEXT NOT NULL,
  blocked_until TIMESTAMPTZ NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_antifraud_blocks_active
  ON antifraud_blocks(user_id, is_active, blocked_until DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_antifraud_blocks_user_action_active
  ON antifraud_blocks(user_id, COALESCE(action_key, 'global'))
  WHERE is_active = true;

-- Полный журнал действий (audit log)
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  actor_role TEXT,
  action TEXT NOT NULL,
  entity_type TEXT,
  entity_id TEXT,
  before_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  after_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant_created
  ON audit_logs(tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_action_created
  ON audit_logs(action, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_actor_created
  ON audit_logs(actor_user_id, created_at DESC);

-- Шаблоны автоответов поддержки
CREATE TABLE IF NOT EXISTS support_reply_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'general'
    CHECK (category IN ('general', 'product', 'delivery', 'cart')),
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_system BOOLEAN NOT NULL DEFAULT false,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_support_reply_templates_tenant
  ON support_reply_templates(tenant_id, category, is_active, updated_at DESC);

INSERT INTO support_reply_templates (
  tenant_id,
  title,
  body,
  category,
  is_system
)
VALUES
  (
    NULL,
    'Сумма корзины',
    'Проверили: общая сумма вашей корзины {cart_total} RUB, обработано {processed_total} RUB.',
    'cart',
    true
  ),
  (
    NULL,
    'Статус доставки',
    'Доставка сейчас в статусе: {delivery_status}. Если нужно, уточните адрес и пожелание по времени.',
    'delivery',
    true
  ),
  (
    NULL,
    'Уточнение по товару',
    'Пришлите, пожалуйста, фото товара и короткое описание. Мы передадим вопрос ответственному работнику.',
    'product',
    true
  )
ON CONFLICT DO NOTHING;

-- Ручные правки маршрута
CREATE TABLE IF NOT EXISTS delivery_route_overrides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  batch_id UUID NOT NULL REFERENCES delivery_batches(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES delivery_batch_customers(id) ON DELETE CASCADE,
  courier_name TEXT,
  route_order INTEGER NOT NULL CHECK (route_order > 0),
  updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (batch_id, customer_id)
);

CREATE INDEX IF NOT EXISTS idx_delivery_route_overrides_batch
  ON delivery_route_overrides(batch_id, route_order ASC);

-- Регистр выгруженных документов (Excel/PDF)
CREATE TABLE IF NOT EXISTS generated_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  generated_by UUID REFERENCES users(id) ON DELETE SET NULL,
  kind TEXT NOT NULL CHECK (kind IN ('invoice', 'route_sheet', 'packing_checklist', 'finance_summary')),
  batch_id UUID REFERENCES delivery_batches(id) ON DELETE SET NULL,
  file_name TEXT,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_generated_documents_tenant_kind
  ON generated_documents(tenant_id, kind, created_at DESC);
