-- Ensure system channel "Архив постов" exists per tenant and enforce unique system channels.

WITH tenant_scope AS (
  SELECT id AS tenant_id FROM tenants
),
created_by_per_tenant AS (
  SELECT
    ts.tenant_id,
    (
      SELECT u.id
      FROM users u
      WHERE (ts.tenant_id IS NULL AND u.tenant_id IS NULL)
         OR (ts.tenant_id IS NOT NULL AND u.tenant_id = ts.tenant_id)
      ORDER BY
        CASE
          WHEN u.role IN ('creator', 'tenant', 'admin') THEN 0
          ELSE 1
        END,
        u.created_at ASC
      LIMIT 1
    ) AS created_by
  FROM tenant_scope ts
)
INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
SELECT
  gen_random_uuid(),
  'Архив постов',
  'channel',
  cpt.created_by,
  cpt.tenant_id,
  jsonb_build_object(
    'kind', 'posts_archive',
    'system_key', 'posts_archive',
    'tenant_id', cpt.tenant_id,
    'visibility', 'private',
    'admin_only', true,
    'worker_can_post', false,
    'is_post_channel', false,
    'hidden_in_chat_list', false,
    'description', 'Системный архив всех постов товаров. Доступен только администраторам и создателю.'
  ),
  now(),
  now()
FROM created_by_per_tenant cpt
WHERE NOT EXISTS (
  SELECT 1
  FROM chats c
  WHERE c.type = 'channel'
    AND (
      (cpt.tenant_id IS NULL AND c.tenant_id IS NULL)
      OR (cpt.tenant_id IS NOT NULL AND c.tenant_id = cpt.tenant_id)
    )
    AND (
      COALESCE(c.settings->>'system_key', '') = 'posts_archive'
      OR COALESCE(c.settings->>'kind', '') = 'posts_archive'
      OR LOWER(TRIM(COALESCE(c.title, ''))) = 'архив постов'
    )
);

-- Normalize posts archive settings for all matching channels.
UPDATE chats c
SET title = COALESCE(NULLIF(c.title, ''), 'Архив постов'),
    settings = COALESCE(c.settings, '{}'::jsonb)
      || jsonb_build_object(
        'kind', 'posts_archive',
        'system_key', 'posts_archive',
        'visibility', 'private',
        'admin_only', true,
        'worker_can_post', false,
        'is_post_channel', false,
        'hidden_in_chat_list', false,
        'description', 'Системный архив всех постов товаров. Доступен только администраторам и создателю.'
      ),
    updated_at = now()
WHERE c.type = 'channel'
  AND (
    COALESCE(c.settings->>'system_key', '') = 'posts_archive'
    OR COALESCE(c.settings->>'kind', '') = 'posts_archive'
    OR LOWER(TRIM(COALESCE(c.title, ''))) = 'архив постов'
  );

-- Keep a single system channel per key/tenant. Move duplicates to archived_* keys.
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
    AND COALESCE(c.settings->>'system_key', '') IN (
      'main_channel',
      'reserved_orders',
      'posts_archive'
    )
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
                 WHEN 'reserved_orders' THEN 'archived_reserved_orders_duplicate'
                 ELSE 'archived_posts_archive_duplicate'
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

-- Archive posts channel should contain only creator/admin/tenant members.
DELETE FROM chat_members cm
USING chats c, users u
WHERE cm.chat_id = c.id
  AND cm.user_id = u.id
  AND c.type = 'channel'
  AND COALESCE(c.settings->>'system_key', '') = 'posts_archive'
  AND (
    (c.tenant_id IS NULL AND u.tenant_id IS NULL)
    OR (c.tenant_id IS NOT NULL AND u.tenant_id = c.tenant_id)
  )
  AND u.role NOT IN ('creator', 'tenant', 'admin');

INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
SELECT
  gen_random_uuid(),
  c.id,
  u.id,
  now(),
  CASE
    WHEN u.role = 'creator' THEN 'owner'
    WHEN u.role IN ('tenant', 'admin') THEN 'moderator'
    ELSE 'member'
  END
FROM chats c
JOIN users u ON (
  (c.tenant_id IS NULL AND u.tenant_id IS NULL)
  OR (c.tenant_id IS NOT NULL AND u.tenant_id = c.tenant_id)
)
WHERE c.type = 'channel'
  AND COALESCE(c.settings->>'system_key', '') = 'posts_archive'
  AND u.role IN ('creator', 'tenant', 'admin')
ON CONFLICT (chat_id, user_id) DO NOTHING;

DROP INDEX IF EXISTS chats_system_channel_per_tenant_unique;
CREATE UNIQUE INDEX IF NOT EXISTS chats_system_channel_per_tenant_unique
ON chats (
  COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
  (settings->>'system_key')
)
WHERE type = 'channel'
  AND COALESCE(settings->>'system_key', '') IN (
    'main_channel',
    'reserved_orders',
    'posts_archive'
  );
