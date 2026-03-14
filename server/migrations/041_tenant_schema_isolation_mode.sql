ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS db_schema TEXT;

DO $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'tenants'::regclass
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%db_mode%'
  LOOP
    EXECUTE format('ALTER TABLE tenants DROP CONSTRAINT IF EXISTS %I', rec.conname);
  END LOOP;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'tenants_db_mode_check'
      AND conrelid = 'tenants'::regclass
  ) THEN
    ALTER TABLE tenants
      ADD CONSTRAINT tenants_db_mode_check
      CHECK (db_mode IN ('shared', 'isolated', 'schema_isolated'));
  END IF;
END$$;

UPDATE tenants
SET db_mode = 'shared'
WHERE db_mode IS NULL
   OR db_mode NOT IN ('shared', 'isolated', 'schema_isolated');

CREATE INDEX IF NOT EXISTS idx_tenants_db_schema
  ON tenants(db_schema)
  WHERE db_schema IS NOT NULL;
