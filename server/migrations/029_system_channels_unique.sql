-- Ensure one main/reserved system channel per tenant and hide historical duplicates.
WITH ranked AS (
  SELECT
    c.id,
    COALESCE(c.settings->>'system_key', '') AS system_key,
    ROW_NUMBER() OVER (
      PARTITION BY
        COALESCE(c.tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(c.settings->>'system_key', '')
      ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC NULLS LAST, c.id DESC
    ) AS rn
  FROM chats c
  WHERE c.type = 'channel'
    AND COALESCE(c.settings->>'system_key', '') IN ('main_channel', 'reserved_orders')
)
UPDATE chats c
SET settings = jsonb_set(
               jsonb_set(COALESCE(c.settings, '{}'::jsonb), '{hidden_in_chat_list}', 'true'::jsonb, true),
               '{kind}',
               '"system_duplicate"'::jsonb,
               true
             ) || jsonb_build_object(
               'system_key',
               CASE ranked.system_key
                 WHEN 'main_channel' THEN 'archived_main_channel_duplicate'
                 ELSE 'archived_reserved_orders_duplicate'
               END
             ),
    title = CASE
      WHEN LOWER(TRIM(COALESCE(c.title, ''))) LIKE '%дубликат%' THEN c.title
      ELSE COALESCE(c.title, '') || ' (дубликат)'
    END,
    updated_at = now()
FROM ranked
WHERE c.id = ranked.id
  AND ranked.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS chats_system_channel_per_tenant_unique
ON chats (
  COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
  (settings->>'system_key')
)
WHERE type = 'channel'
  AND COALESCE(settings->>'system_key', '') IN ('main_channel', 'reserved_orders');
