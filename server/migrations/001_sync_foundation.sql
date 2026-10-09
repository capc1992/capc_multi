BEGIN;

CREATE TABLE IF NOT EXISTS sync_operations (
  server_cursor BIGSERIAL PRIMARY KEY,
  business_id UUID NOT NULL,
  device_id UUID NOT NULL,
  operation_id UUID NOT NULL,
  type VARCHAR(80) NOT NULL,
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  occurred_at TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  content JSONB NOT NULL CHECK (jsonb_typeof(content) = 'object'),
  content_hash CHAR(64) NOT NULL,
  UNIQUE (business_id, operation_id)
);

CREATE INDEX IF NOT EXISTS sync_operations_pull
  ON sync_operations (business_id, server_cursor);

CREATE TABLE IF NOT EXISTS sync_entities (
  business_id UUID NOT NULL,
  entity_type VARCHAR(40) NOT NULL,
  entity_id UUID NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (business_id, entity_type, entity_id)
);

CREATE TABLE IF NOT EXISTS sync_financial_events (
  business_id UUID NOT NULL,
  operation_id UUID NOT NULL,
  type VARCHAR(80) NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  PRIMARY KEY (business_id, operation_id)
);

CREATE TABLE IF NOT EXISTS sync_inventory_movements (
  business_id UUID NOT NULL,
  movement_id UUID NOT NULL,
  operation_id UUID NOT NULL,
  product_id UUID NOT NULL,
  delta BIGINT NOT NULL CHECK (delta <> 0),
  cost_micros BIGINT NOT NULL CHECK (cost_micros >= 0),
  occurred_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  PRIMARY KEY (business_id, movement_id)
);

CREATE INDEX IF NOT EXISTS sync_inventory_balance
  ON sync_inventory_movements (business_id, product_id, occurred_at);

CREATE TABLE IF NOT EXISTS sync_conflicts (
  id BIGSERIAL PRIMARY KEY,
  business_id UUID NOT NULL,
  operation_id UUID NOT NULL,
  type VARCHAR(80) NOT NULL,
  entity_id UUID NOT NULL,
  details JSONB NOT NULL CHECK (jsonb_typeof(details) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  UNIQUE (business_id, operation_id, type, entity_id)
);

CREATE INDEX IF NOT EXISTS sync_conflicts_open
  ON sync_conflicts (business_id, created_at)
  WHERE resolved_at IS NULL;

COMMIT;
