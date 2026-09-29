BEGIN;

ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_one_principal;
ALTER TABLE sessions DROP COLUMN IF EXISTS user_id;
ALTER TABLE sessions ALTER COLUMN owner_id SET NOT NULL;
ALTER TABLE security_audit DROP COLUMN IF EXISTS user_id;

DROP TABLE IF EXISTS business_user_roles;
DROP TABLE IF EXISTS business_users;
DROP TABLE IF EXISTS access_role_permissions;
DROP TABLE IF EXISTS access_roles;
DROP TABLE IF EXISTS access_permissions;

UPDATE remote_owners
SET permissions = array_remove(array_remove(permissions,'access:read'),'access:manage');
UPDATE sessions
SET permissions = array_remove(array_remove(permissions,'access:read'),'access:manage');

COMMIT;
