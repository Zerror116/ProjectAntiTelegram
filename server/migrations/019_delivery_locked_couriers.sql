ALTER TABLE delivery_batch_customers
ADD COLUMN IF NOT EXISTS locked_courier_slot INTEGER,
ADD COLUMN IF NOT EXISTS locked_courier_name TEXT,
ADD COLUMN IF NOT EXISTS locked_courier_code TEXT;
