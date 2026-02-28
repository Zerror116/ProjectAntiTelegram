ALTER TABLE users
  ADD COLUMN IF NOT EXISTS avatar_url TEXT,
  ADD COLUMN IF NOT EXISTS avatar_focus_x DOUBLE PRECISION DEFAULT 0,
  ADD COLUMN IF NOT EXISTS avatar_focus_y DOUBLE PRECISION DEFAULT 0,
  ADD COLUMN IF NOT EXISTS avatar_zoom DOUBLE PRECISION DEFAULT 1;

UPDATE users
SET avatar_focus_x = COALESCE(avatar_focus_x, 0),
    avatar_focus_y = COALESCE(avatar_focus_y, 0),
    avatar_zoom = COALESCE(avatar_zoom, 1)
WHERE avatar_focus_x IS NULL
   OR avatar_focus_y IS NULL
   OR avatar_zoom IS NULL;

ALTER TABLE users
  ALTER COLUMN avatar_focus_x SET DEFAULT 0,
  ALTER COLUMN avatar_focus_y SET DEFAULT 0,
  ALTER COLUMN avatar_zoom SET DEFAULT 1;
