BEGIN;

ALTER TABLE businesses
  ADD COLUMN IF NOT EXISTS phone VARCHAR(80) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS address VARCHAR(500) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS email VARCHAR(320) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS configuration JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_by UUID;

CREATE TABLE IF NOT EXISTS business_assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id),
  kind VARCHAR(40) NOT NULL,
  mime_type VARCHAR(120) NOT NULL,
  content BYTEA NOT NULL CHECK (octet_length(content) <= 2097152),
  content_hash CHAR(64) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ,
  UNIQUE (business_id,kind,content_hash)
);

CREATE INDEX IF NOT EXISTS business_assets_active
  ON business_assets (business_id,kind,created_at DESC)
  WHERE deleted_at IS NULL;

COMMIT;
