BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE businesses (
  id UUID PRIMARY KEY,
  name VARCHAR(160) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  disabled_at TIMESTAMPTZ
);

CREATE TABLE remote_owners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id),
  email VARCHAR(320) NOT NULL,
  password_salt BYTEA NOT NULL CHECK (octet_length(password_salt) >= 16),
  password_hash BYTEA NOT NULL CHECK (octet_length(password_hash) >= 32),
  permissions TEXT[] NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  disabled_at TIMESTAMPTZ,
  UNIQUE (business_id,email)
);

CREATE TABLE devices (
  id UUID NOT NULL,
  business_id UUID NOT NULL REFERENCES businesses(id),
  name VARCHAR(160) NOT NULL,
  platform VARCHAR(40) NOT NULL,
  authorized_by UUID NOT NULL REFERENCES remote_owners(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  PRIMARY KEY (id,business_id),
  UNIQUE (id)
);

CREATE INDEX devices_business_active ON devices (business_id,created_at) WHERE revoked_at IS NULL;

CREATE TABLE sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id),
  device_id UUID NOT NULL,
  owner_id UUID NOT NULL REFERENCES remote_owners(id),
  access_token_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(access_token_hash)=32),
  permissions TEXT[] NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  FOREIGN KEY (device_id,business_id) REFERENCES devices(id,business_id)
);

CREATE INDEX sessions_active ON sessions (business_id,device_id,expires_at) WHERE revoked_at IS NULL;

CREATE TABLE refresh_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES sessions(id),
  family_id VARCHAR(64) NOT NULL,
  business_id UUID NOT NULL REFERENCES businesses(id),
  device_id UUID NOT NULL,
  token_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(token_hash)=32),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  FOREIGN KEY (device_id,business_id) REFERENCES devices(id,business_id)
);

CREATE INDEX refresh_family ON refresh_tokens (family_id,created_at);
CREATE INDEX refresh_active ON refresh_tokens (business_id,device_id,expires_at) WHERE revoked_at IS NULL;

CREATE TABLE linking_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id),
  created_by_owner_id UUID NOT NULL REFERENCES remote_owners(id),
  created_by_device_id UUID NOT NULL,
  code_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(code_hash)=32),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  used_by_device_id UUID,
  FOREIGN KEY (created_by_device_id,business_id) REFERENCES devices(id,business_id)
);

CREATE INDEX linking_codes_active ON linking_codes (business_id,expires_at) WHERE used_at IS NULL;

CREATE TABLE token_revocations (
  id BIGSERIAL PRIMARY KEY,
  business_id UUID NOT NULL REFERENCES businesses(id),
  device_id UUID NOT NULL,
  session_id UUID NOT NULL REFERENCES sessions(id),
  reason VARCHAR(80) NOT NULL,
  revoked_by_owner_id UUID REFERENCES remote_owners(id),
  revoked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (session_id,reason),
  FOREIGN KEY (device_id,business_id) REFERENCES devices(id,business_id)
);

CREATE TABLE security_audit (
  id BIGSERIAL PRIMARY KEY,
  business_id UUID NOT NULL REFERENCES businesses(id),
  device_id UUID,
  owner_id UUID,
  event VARCHAR(80) NOT NULL,
  details JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details)='object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX security_audit_business ON security_audit (business_id,created_at DESC);

CREATE TABLE auth_attempts (
  id BIGSERIAL PRIMARY KEY,
  action VARCHAR(40) NOT NULL,
  key_hash BYTEA NOT NULL CHECK (octet_length(key_hash)=32),
  success BOOLEAN NOT NULL,
  attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX auth_attempts_limit ON auth_attempts (action,key_hash,attempted_at DESC) WHERE success=false;

COMMIT;
