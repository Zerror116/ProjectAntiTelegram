CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS media_assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_kind TEXT NOT NULL CHECK (
    owner_kind IN (
      'product_image',
      'user_avatar',
      'channel_avatar',
      'claim_image',
      'message_attachment',
      'message_attachment_preview'
    )
  ),
  owner_id UUID,
  owner_text_id TEXT,
  slot TEXT NOT NULL DEFAULT 'default',
  storage_kind TEXT NOT NULL DEFAULT 'public' CHECK (storage_kind IN ('public','private')),
  original_path TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  mime_type TEXT,
  byte_size BIGINT,
  width INTEGER,
  height INTEGER,
  duration_ms INTEGER,
  checksum_sha256 TEXT,
  asset_version INTEGER NOT NULL DEFAULT 1 CHECK (asset_version > 0),
  variants JSONB NOT NULL DEFAULT '{}'::jsonb,
  placeholder_applied_at TIMESTAMPTZ,
  last_verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_media_assets_original_path
  ON media_assets(original_path);

CREATE UNIQUE INDEX IF NOT EXISTS ux_media_assets_owner_uuid_slot
  ON media_assets(owner_kind, owner_id, slot)
  WHERE owner_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_media_assets_owner_text_slot
  ON media_assets(owner_kind, owner_text_id, slot)
  WHERE owner_text_id IS NOT NULL AND owner_text_id <> '';

CREATE INDEX IF NOT EXISTS idx_media_assets_owner_kind_verified
  ON media_assets(owner_kind, updated_at DESC, asset_version DESC);

CREATE INDEX IF NOT EXISTS idx_media_assets_storage_kind_verified
  ON media_assets(storage_kind, last_verified_at DESC NULLS LAST);

CREATE TABLE IF NOT EXISTS product_card_snapshots (
  product_id UUID PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
  media_version INTEGER NOT NULL DEFAULT 1,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_card_snapshots_tenant_updated
  ON product_card_snapshots(tenant_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS performance_budget_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  scope TEXT NOT NULL,
  target_id TEXT,
  metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
  budget JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'pass' CHECK (status IN ('pass','warn','fail')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_performance_budget_reports_scope_created
  ON performance_budget_reports(scope, created_at DESC);
