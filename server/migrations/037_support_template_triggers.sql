ALTER TABLE support_reply_templates
  ADD COLUMN IF NOT EXISTS trigger_rule TEXT NOT NULL DEFAULT '';

ALTER TABLE support_reply_templates
  ADD COLUMN IF NOT EXISTS auto_reply_enabled BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE support_reply_templates
  ADD COLUMN IF NOT EXISTS priority INTEGER NOT NULL DEFAULT 100;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'support_reply_templates_priority_range'
  ) THEN
    ALTER TABLE support_reply_templates
      ADD CONSTRAINT support_reply_templates_priority_range
      CHECK (priority >= 0 AND priority <= 1000);
  END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_support_reply_templates_auto_triggers
  ON support_reply_templates(
    tenant_id,
    category,
    is_active,
    auto_reply_enabled,
    priority ASC,
    updated_at DESC
  );

UPDATE support_reply_templates
SET auto_reply_enabled = true,
    trigger_rule = CASE
      WHEN category = 'cart' THEN 'сумма+корзины|сколько+в+корзине|итог+корзины'
      WHEN category = 'delivery' THEN 'время+доставки|когда+доставка|статус+доставки'
      WHEN category = 'product' THEN 'фото+товара|вопрос+по+товару'
      ELSE trigger_rule
    END,
    priority = CASE
      WHEN category = 'delivery' THEN 50
      WHEN category = 'cart' THEN 60
      WHEN category = 'product' THEN 70
      ELSE priority
    END,
    updated_at = now()
WHERE is_system = true
  AND COALESCE(NULLIF(BTRIM(trigger_rule), ''), '') = '';
