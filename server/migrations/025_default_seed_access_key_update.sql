-- server/migrations/025_default_seed_access_key_update.sql
-- Обновляем дефолтный ключ арендатора для уже существующих БД.

UPDATE tenants
SET access_key_hash = encode(digest('PHOENIX-ZERROR-KEY', 'sha256'), 'hex'),
    access_key_mask = 'PHOENIX-****-****-KEY',
    updated_at = now()
WHERE code = 'default'
  AND access_key_hash = encode(digest('PHOENIX-DEFAULT-KEY', 'sha256'), 'hex');
