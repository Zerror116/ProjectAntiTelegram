UPDATE notification_deliveries
   SET next_attempt_at = now(),
       updated_at = now()
 WHERE next_attempt_at IS NULL;

ALTER TABLE notification_deliveries
  ALTER COLUMN next_attempt_at SET DEFAULT now();

ALTER TABLE notification_deliveries
  ALTER COLUMN next_attempt_at SET NOT NULL;
