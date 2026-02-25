-- server/migrations/004_audit_admin_actions.sql
CREATE TABLE admin_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id UUID, -- optional, if admins are users
  action TEXT, -- 'verify_phone', 'delete_phone_and_user'
  target_user_id UUID,
  target_phone TEXT,
  details JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
