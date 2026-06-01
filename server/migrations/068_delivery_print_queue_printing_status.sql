-- Add an in-flight state so only one open web client prints a sticker job.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'sticker_print_jobs'
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'sticker_print_jobs_status_check'
        AND conrelid = 'sticker_print_jobs'::regclass
    ) THEN
      ALTER TABLE sticker_print_jobs
        DROP CONSTRAINT sticker_print_jobs_status_check;
    END IF;

    ALTER TABLE sticker_print_jobs
      ADD CONSTRAINT sticker_print_jobs_status_check
      CHECK (status IN ('pending', 'printing', 'printed', 'failed', 'cancelled'));
  END IF;
END $$;
