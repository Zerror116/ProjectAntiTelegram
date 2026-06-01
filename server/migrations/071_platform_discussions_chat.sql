-- Общий чат "Обсуждения" живёт в platform-базе и не привязан к tenant.
-- Индекс защищает от появления нескольких platform-глобальных обсуждений.
CREATE UNIQUE INDEX IF NOT EXISTS chats_platform_discussions_unique
ON chats ((settings->>'system_key'))
WHERE type = 'private'
  AND tenant_id IS NULL
  AND COALESCE(settings->>'system_key', '') = 'platform_discussions';
