UPDATE notification_deliveries
   SET queue_name = channel,
       state = CASE
         WHEN state IN ('queued', 'failed') THEN 'skipped'
         ELSE state
       END,
       error_message = CASE
         WHEN state IN ('queued', 'failed')
           THEN COALESCE(NULLIF(error_message, ''), 'legacy_in_app_queue_normalized')
         ELSE error_message
       END,
       metadata = COALESCE(metadata, '{}'::jsonb) ||
         jsonb_build_object('legacy_queue_normalized', true),
       processing_started_at = NULL,
       updated_at = now()
 WHERE channel <> 'push'
   AND queue_name = 'push';

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_push_queue_claim
  ON notification_deliveries(queue_name, state, next_attempt_at, processing_started_at, created_at)
  WHERE channel = 'push'
    AND queue_name = 'push';
