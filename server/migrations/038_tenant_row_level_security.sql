DO $$
DECLARE
  target_table record;
BEGIN
  FOR target_table IN
    SELECT DISTINCT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema
     AND t.table_name = c.table_name
    WHERE c.table_schema = 'public'
      AND c.column_name = 'tenant_id'
      AND t.table_type = 'BASE TABLE'
    ORDER BY c.table_name
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', target_table.table_name);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', target_table.table_name);
    EXECUTE format('DROP POLICY IF EXISTS tenant_scope_guard ON %I', target_table.table_name);
    EXECUTE format(
      $policy$
      CREATE POLICY tenant_scope_guard
      ON %I
      USING (
        tenant_id IS NULL
        OR NULLIF(current_setting('app.tenant_id', true), '') IS NULL
        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
      )
      WITH CHECK (
        tenant_id IS NULL
        OR NULLIF(current_setting('app.tenant_id', true), '') IS NULL
        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
      )
      $policy$,
      target_table.table_name
    );
  END LOOP;
END$$;
