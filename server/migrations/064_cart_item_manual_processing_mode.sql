ALTER TABLE cart_items
DROP CONSTRAINT IF EXISTS cart_items_processing_mode_check;

ALTER TABLE cart_items
ADD CONSTRAINT cart_items_processing_mode_check
CHECK (processing_mode IN ('standard', 'oversize', 'manual'));
