-- server/migrations/035_role_templates_support_permission.sql

UPDATE role_templates
SET permissions = COALESCE(permissions, '{}'::jsonb) || '{"chat.write.support": true}'::jsonb,
    updated_at = now()
WHERE tenant_id IS NULL
  AND code IN ('worker', 'admin', 'tenant');
