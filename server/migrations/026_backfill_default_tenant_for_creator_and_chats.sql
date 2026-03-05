-- server/migrations/026_backfill_default_tenant_for_creator_and_chats.sql
-- Исправляет старые данные, где tenant_id оставался NULL у создателя и чатов.

WITH default_tenant AS (
  SELECT id
  FROM tenants
  WHERE code = 'default'
  LIMIT 1
)
UPDATE users u
SET tenant_id = dt.id
FROM default_tenant dt
WHERE u.tenant_id IS NULL
  AND LOWER(COALESCE(u.role, '')) = 'creator';

WITH default_tenant AS (
  SELECT id
  FROM tenants
  WHERE code = 'default'
  LIMIT 1
)
UPDATE chats c
SET tenant_id = dt.id
FROM default_tenant dt
WHERE c.tenant_id IS NULL
  AND c.type IN ('channel', 'private', 'public');
