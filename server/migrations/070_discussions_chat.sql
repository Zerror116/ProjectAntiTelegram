-- Закрытый чат "Обсуждения" создаётся runtime-хелпером для каждого tenant.
-- Индекс защищает от дублей системного чата на уровне tenant.
CREATE UNIQUE INDEX IF NOT EXISTS chats_discussions_per_tenant_unique
ON chats (
  COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
  (settings->>'system_key')
)
WHERE type = 'private'
  AND COALESCE(settings->>'system_key', '') = 'discussions';
