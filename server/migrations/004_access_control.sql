BEGIN;

CREATE TABLE access_permissions (
  key VARCHAR(120) PRIMARY KEY,
  module VARCHAR(60) NOT NULL,
  action VARCHAR(60) NOT NULL,
  description VARCHAR(240) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (module,action)
);

INSERT INTO access_permissions (key,module,action,description) VALUES
  ('productos.ver','productos','ver','Consultar productos'),
  ('productos.crear','productos','crear','Crear productos'),
  ('productos.editar','productos','editar','Editar productos'),
  ('productos.eliminar','productos','eliminar','Eliminar productos'),
  ('ventas.ver','ventas','ver','Consultar ventas'),
  ('ventas.crear','ventas','crear','Crear ventas'),
  ('ventas.editar','ventas','editar','Editar ventas'),
  ('ventas.anular','ventas','anular','Anular ventas'),
  ('inventario.ver','inventario','ver','Consultar inventario'),
  ('inventario.ajustar','inventario','ajustar','Ajustar inventario'),
  ('usuarios.ver','usuarios','ver','Consultar usuarios'),
  ('usuarios.crear','usuarios','crear','Crear usuarios'),
  ('usuarios.editar','usuarios','editar','Editar usuarios'),
  ('usuarios.eliminar','usuarios','eliminar','Desactivar usuarios'),
  ('roles.ver','roles','ver','Consultar roles'),
  ('roles.crear','roles','crear','Crear roles'),
  ('roles.editar','roles','editar','Editar roles'),
  ('roles.eliminar','roles','eliminar','Eliminar roles'),
  ('configuracion.ver','configuracion','ver','Consultar configuración'),
  ('configuracion.editar','configuracion','editar','Editar configuración'),
  ('reportes.ver','reportes','ver','Consultar reportes'),
  ('auditoria.ver','auditoria','ver','Consultar auditoría'),
  ('sync:read','sistema','sync_read','Descargar cambios del negocio'),
  ('sync:write','sistema','sync_write','Enviar cambios del dispositivo'),
  ('devices:read','sistema','devices_read','Consultar dispositivos'),
  ('devices:manage','sistema','devices_manage','Administrar dispositivos'),
  ('access:read','sistema','access_read','Consultar control de acceso'),
  ('access:manage','sistema','access_manage','Administrar control de acceso')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE access_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name VARCHAR(120) NOT NULL,
  role_type VARCHAR(20) NOT NULL DEFAULT 'operational'
    CHECK (role_type IN ('administrator','operational')),
  is_system BOOLEAN NOT NULL DEFAULT false,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX access_roles_name_active
  ON access_roles (business_id,lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE access_role_permissions (
  role_id UUID NOT NULL REFERENCES access_roles(id) ON DELETE CASCADE,
  permission_key VARCHAR(120) NOT NULL REFERENCES access_permissions(key),
  PRIMARY KEY (role_id,permission_key)
);

CREATE TABLE business_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  remote_owner_id UUID REFERENCES remote_owners(id) ON DELETE CASCADE,
  name VARCHAR(160) NOT NULL,
  username VARCHAR(80) NOT NULL,
  email VARCHAR(320),
  active BOOLEAN NOT NULL DEFAULT true,
  security_version INTEGER NOT NULL DEFAULT 1 CHECK (security_version > 0),
  password_salt BYTEA CHECK (password_salt IS NULL OR octet_length(password_salt) >= 16),
  password_hash BYTEA CHECK (password_hash IS NULL OR octet_length(password_hash) >= 32),
  activation_code_hash BYTEA CHECK (activation_code_hash IS NULL OR octet_length(activation_code_hash)=32),
  activation_expires_at TIMESTAMPTZ,
  activated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ,
  UNIQUE (remote_owner_id)
);

ALTER TABLE business_users ADD CONSTRAINT business_users_password_pair
  CHECK ((password_salt IS NULL) = (password_hash IS NULL));

CREATE UNIQUE INDEX business_users_username_active
  ON business_users (business_id,lower(username)) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX business_users_email_active
  ON business_users (business_id,lower(email)) WHERE email IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE business_user_roles (
  user_id UUID NOT NULL REFERENCES business_users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES access_roles(id),
  PRIMARY KEY (user_id,role_id)
);

ALTER TABLE sessions
  ALTER COLUMN owner_id DROP NOT NULL,
  ADD COLUMN user_id UUID REFERENCES business_users(id) ON DELETE CASCADE,
  ADD CONSTRAINT sessions_one_principal CHECK (
    (owner_id IS NOT NULL AND user_id IS NULL) OR
    (owner_id IS NULL AND user_id IS NOT NULL)
  );

ALTER TABLE security_audit
  ADD COLUMN user_id UUID REFERENCES business_users(id) ON DELETE SET NULL;

WITH inserted_roles AS (
  INSERT INTO access_roles (business_id,name,role_type,is_system)
  SELECT id,'Administrador principal','administrator',true FROM businesses
  ON CONFLICT DO NOTHING
  RETURNING id,business_id
)
INSERT INTO access_role_permissions (role_id,permission_key)
SELECT r.id,p.key FROM access_roles r CROSS JOIN access_permissions p
WHERE r.is_system=true AND r.name='Administrador principal'
ON CONFLICT DO NOTHING;

INSERT INTO business_users (
  business_id,remote_owner_id,name,username,email,active,activated_at
)
SELECT o.business_id,o.id,'Administrador principal','owner_' || replace(o.id::text,'-',''),o.email,true,now()
FROM remote_owners o
ON CONFLICT (remote_owner_id) DO NOTHING;

INSERT INTO business_user_roles (user_id,role_id)
SELECT u.id,r.id FROM business_users u
JOIN access_roles r ON r.business_id=u.business_id
WHERE u.remote_owner_id IS NOT NULL AND r.is_system=true
ON CONFLICT DO NOTHING;

UPDATE remote_owners
SET permissions = ARRAY(
  SELECT DISTINCT value
  FROM unnest(permissions || ARRAY['access:read','access:manage']) AS permission(value)
);
UPDATE sessions
SET permissions = ARRAY(
  SELECT DISTINCT value
  FROM unnest(permissions || ARRAY['access:read','access:manage']) AS permission(value)
)
WHERE revoked_at IS NULL;

COMMIT;
