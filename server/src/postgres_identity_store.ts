import { createHash, randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';

import { Pool, type PoolClient } from 'pg';
import { OfflineGrantIssuer } from './offline_grant.js';

import {
  IdentityError,
  ownerPermissions,
  type AccessUserLoginInput,
  type ActivateAccessUserInput,
  type AccessPermissionRecord,
  type AccessRoleRecord,
  type AccessUserRecord,
  type AuthIdentity,
  type CreateAccessUserInput,
  type CreateBusinessInput,
  type CreatedAccessUser,
  type DeleteBusinessInput,
  type DeviceRecord,
  type IdentityStore,
  type IssuedIdentity,
  type LinkDeviceInput,
  type LoginInput,
  type SaveAccessRoleInput,
  type SecurityAuditRecord,
  type UpdateAccessUserInput,
} from './identity.js';

const codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

export class PostgresIdentityStore implements IdentityStore {
  private readonly pool: Pool;
  private readonly offlineGrants: OfflineGrantIssuer;

  constructor(
    databaseUrl: string,
    private readonly tokenPepper: string,
    private readonly accessTtlMinutes = 15,
    private readonly refreshTtlDays = 30,
  ) {
    this.pool = new Pool({ connectionString: databaseUrl, max: 10 });
    this.offlineGrants = new OfflineGrantIssuer(tokenPepper);
  }

  async createBusiness(input: CreateBusinessInput, requestKey: string): Promise<IssuedIdentity> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'business.create', requestKey, 5, 60);
      const salt = randomBytes(16);
      const passwordHash = await hashPassword(input.password, salt);
      const business = await client.query(
        `INSERT INTO businesses (id,name) VALUES ($1,$2)
         ON CONFLICT (id) DO NOTHING RETURNING id`,
        [input.businessId, input.businessName],
      );
      if (business.rowCount !== 1) throw new IdentityError('business_already_connected', 409);
      const owner = await client.query<{ id: string }>(
        `INSERT INTO remote_owners (business_id,email,password_salt,password_hash,permissions)
         VALUES ($1,lower($2),$3,$4,$5) RETURNING id`,
        [input.businessId, input.email, salt, passwordHash, ownerPermissions],
      );
      const ownerRole = await client.query<{ id: string }>(
        `INSERT INTO access_roles (business_id,name,role_type,is_system)
         VALUES ($1,'Administrador principal','administrator',true) RETURNING id`,
        [input.businessId],
      );
      await client.query(
        `INSERT INTO access_role_permissions (role_id,permission_key)
         SELECT $1,key FROM access_permissions`,
        [ownerRole.rows[0]!.id],
      );
      const ownerUser = await client.query<{ id: string }>(
        `INSERT INTO business_users
           (business_id,remote_owner_id,name,username,email,active,activated_at)
         VALUES ($1,$2,'Administrador principal',$3,lower($4),true,now()) RETURNING id`,
        [input.businessId, owner.rows[0]!.id,
          `owner_${owner.rows[0]!.id.replaceAll('-', '')}`, input.email],
      );
      await client.query(
        `INSERT INTO business_user_roles (user_id,role_id) VALUES ($1,$2)`,
        [ownerUser.rows[0]!.id, ownerRole.rows[0]!.id],
      );
      await client.query(
        `INSERT INTO devices (id,business_id,name,platform,authorized_by)
         VALUES ($1,$2,$3,$4,$5)`,
        [input.deviceId, input.businessId, input.deviceName, input.platform, owner.rows[0]!.id],
      );
      const issued = await this.issue(client, input.businessId, input.deviceId, owner.rows[0]!.id, [...ownerPermissions]);
      await this.audit(client, input.businessId, input.deviceId, owner.rows[0]!.id, 'business.created', { device_id: input.deviceId });
      await client.query('COMMIT');
      return issued;
    } catch (error) {
      await client.query('ROLLBACK');
      if (isUniqueViolation(error)) throw new IdentityError('identity_already_exists', 409);
      throw error;
    } finally {
      client.release();
    }
  }

  async login(input: LoginInput, requestKey: string): Promise<IssuedIdentity> {
    const client = await this.pool.connect();
    const rateKey = `${requestKey}:${input.businessId}:${input.email.toLowerCase()}`;
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'login', rateKey, 5, 15);
      const result = await client.query<{
        id: string; password_salt: Buffer; password_hash: Buffer; permissions: string[];
      }>(
        `SELECT id,password_salt,password_hash,permissions FROM remote_owners
         WHERE business_id=$1 AND email=lower($2) AND disabled_at IS NULL FOR UPDATE`,
        [input.businessId, input.email],
      );
      const owner = result.rows[0];
      const valid = owner !== undefined && await verifyPassword(input.password, owner.password_salt, owner.password_hash);
      const device = valid ? await client.query(
        `SELECT id FROM devices WHERE id=$1 AND business_id=$2 AND revoked_at IS NULL`,
        [input.deviceId, input.businessId],
      ) : null;
      if (!valid || device?.rowCount !== 1) {
        throw new IdentityError('invalid_credentials', 401);
      }
      await this.attempt(client, 'login', rateKey, true);
      const issued = await this.issue(client, input.businessId, input.deviceId, owner.id, owner.permissions);
      await this.audit(client, input.businessId, input.deviceId, owner.id, 'session.login', {});
      await client.query('COMMIT');
      return issued;
    } catch (error) {
      await client.query('ROLLBACK');
      if (error instanceof IdentityError && error.code === 'invalid_credentials') {
        await this.recordAttempt('login', rateKey, false);
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async refresh(refreshToken: string, deviceId: string, requestKey: string): Promise<IssuedIdentity> {
    const client = await this.pool.connect();
    const rateKey = `${requestKey}:${deviceId}`;
    let compromised: { familyId: string; businessId: string; deviceId: string; ownerId: string | null } | null = null;
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'refresh', rateKey, 10, 15);
      const tokenHash = this.tokenHash(refreshToken);
      const result = await client.query<{
        id: string; session_id: string; family_id: string; business_id: string; device_id: string;
        owner_id: string | null; user_id: string | null; permissions: string[];
        expires_at: Date; used_at: Date | null; revoked_at: Date | null;
      }>(
        `SELECT r.id,r.session_id,r.family_id,r.business_id,r.device_id,s.owner_id,s.user_id,s.permissions,
                r.expires_at,r.used_at,r.revoked_at
         FROM refresh_tokens r JOIN sessions s ON s.id=r.session_id
         JOIN devices d ON d.id=r.device_id AND d.business_id=r.business_id
         WHERE r.token_hash=$1
           AND ((s.owner_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM remote_owners o WHERE o.id=s.owner_id
                    AND o.business_id=s.business_id AND o.disabled_at IS NULL))
             OR (s.user_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM business_users u WHERE u.id=s.user_id
                    AND u.business_id=s.business_id AND u.active=true
                    AND u.activated_at IS NOT NULL AND u.deleted_at IS NULL)))
         FOR UPDATE OF r,s`,
        [tokenHash],
      );
      const row = result.rows[0];
      if (!row || row.device_id !== deviceId || row.expires_at <= new Date() || row.revoked_at || row.used_at) {
        if (row) {
          compromised = {
            familyId: row.family_id,
            businessId: row.business_id,
            deviceId: row.device_id,
            ownerId: row.owner_id,
          };
        }
        throw new IdentityError('invalid_refresh_token', 401);
      }
      await client.query('UPDATE refresh_tokens SET used_at=now() WHERE id=$1', [row.id]);
      await client.query('UPDATE sessions SET revoked_at=now() WHERE id=$1', [row.session_id]);
      const issued = await this.issue(
        client, row.business_id, row.device_id, row.owner_id,
        row.permissions, row.family_id, row.user_id,
      );
      await this.attempt(client, 'refresh', rateKey, true);
      await this.audit(client, row.business_id, row.device_id, row.owner_id, 'token.rotated', { family_id: row.family_id });
      await client.query('COMMIT');
      return issued;
    } catch (error) {
      await client.query('ROLLBACK');
      if (compromised) {
        await this.revokeFamily(compromised);
      }
      if (error instanceof IdentityError && error.code === 'invalid_refresh_token') {
        await this.recordAttempt('refresh', rateKey, false);
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async authenticate(accessToken: string): Promise<AuthIdentity | null> {
    if (accessToken.length < 32) return null;
    const result = await this.pool.query<{
      id: string; business_id: string; device_id: string;
      owner_id: string | null; user_id: string | null; permissions: string[];
    }>(
      `UPDATE sessions s SET last_seen_at=now()
       FROM devices d
       WHERE s.access_token_hash=$1 AND s.expires_at>now() AND s.revoked_at IS NULL
         AND d.id=s.device_id AND d.business_id=s.business_id AND d.revoked_at IS NULL
         AND ((s.owner_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM remote_owners o WHERE o.id=s.owner_id
                  AND o.business_id=s.business_id AND o.disabled_at IS NULL))
           OR (s.user_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM business_users u WHERE u.id=s.user_id
                  AND u.business_id=s.business_id AND u.active=true
                  AND u.activated_at IS NOT NULL AND u.deleted_at IS NULL)))
       RETURNING s.id,s.business_id,s.device_id,s.owner_id,s.user_id,s.permissions`,
      [this.tokenHash(accessToken)],
    );
    const row = result.rows[0];
    return row ? {
      sessionId: row.id,
      businessId: row.business_id,
      deviceId: row.device_id,
      ownerId: row.owner_id,
      userId: row.user_id,
      permissions: row.permissions,
    } : null;
  }

  async createLinkCode(identity: AuthIdentity): Promise<{ code: string; expiresAt: string }> {
    const code = randomCode(10);
    const expiresAt = new Date(Date.now() + 10 * 60_000);
    await this.pool.query(
      `INSERT INTO linking_codes (business_id,created_by_owner_id,created_by_device_id,code_hash,expires_at)
       VALUES ($1,$2,$3,$4,$5)`,
      [identity.businessId, identity.ownerId, identity.deviceId, this.tokenHash(code), expiresAt],
    );
    await this.pool.query(
      `INSERT INTO security_audit (business_id,device_id,owner_id,event,details)
       VALUES ($1,$2,$3,'link_code.created','{}'::jsonb)`,
      [identity.businessId, identity.deviceId, identity.ownerId],
    );
    return { code, expiresAt: expiresAt.toISOString() };
  }

  async linkDevice(input: LinkDeviceInput, requestKey: string): Promise<IssuedIdentity> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'link', requestKey, 8, 15);
      const result = await client.query<{
        id: string; business_id: string; created_by_owner_id: string; expires_at: Date; used_at: Date | null;
      }>(
        `SELECT id,business_id,created_by_owner_id,expires_at,used_at FROM linking_codes
         WHERE code_hash=$1 FOR UPDATE`,
        [this.tokenHash(input.code)],
      );
      const link = result.rows[0];
      if (!link || link.used_at || link.expires_at <= new Date()) {
        throw new IdentityError(link?.used_at ? 'link_code_used' : 'link_code_invalid_or_expired', 409);
      }
      if (!['new', 'no_movements'].includes(input.localState)) {
        throw new IdentityError('local_data_requires_migration', 409);
      }
      const occupied = await client.query(
        `SELECT business_id FROM devices WHERE id=$1 AND revoked_at IS NULL`,
        [input.deviceId],
      );
      if (occupied.rowCount && occupied.rows[0]?.business_id !== link.business_id) {
        throw new IdentityError('device_belongs_to_another_business', 409);
      }
      if (input.localBusinessId !== link.business_id) {
        const localIdentity = await client.query(
          'SELECT 1 FROM businesses WHERE id=$1',
          [input.localBusinessId],
        );
        if (localIdentity.rowCount) {
          throw new IdentityError(
            'local_business_belongs_to_another_remote_business',
            409,
          );
        }
      }
      await client.query(
        `INSERT INTO devices (id,business_id,name,platform,authorized_by)
         VALUES ($1,$2,$3,$4,$5)
         ON CONFLICT (id,business_id) DO UPDATE SET name=EXCLUDED.name,platform=EXCLUDED.platform,revoked_at=NULL`,
        [input.deviceId, link.business_id, input.deviceName, input.platform, link.created_by_owner_id],
      );
      await client.query('UPDATE linking_codes SET used_at=now(),used_by_device_id=$2 WHERE id=$1', [link.id, input.deviceId]);
      const owner = await client.query<{ permissions: string[] }>('SELECT permissions FROM remote_owners WHERE id=$1', [link.created_by_owner_id]);
      const issued = await this.issue(client, link.business_id, input.deviceId, link.created_by_owner_id, owner.rows[0]!.permissions);
      await this.attempt(client, 'link', requestKey, true);
      await this.audit(client, link.business_id, input.deviceId, link.created_by_owner_id, 'device.linked', {
        previous_local_business_id: input.localBusinessId === link.business_id ? 'same' : 'replaced_empty_identity',
      });
      await client.query('COMMIT');
      return issued;
    } catch (error) {
      await client.query('ROLLBACK');
      if (error instanceof IdentityError && (error.code === 'link_code_used' || error.code === 'link_code_invalid_or_expired')) {
        await this.recordAttempt('link', requestKey, false);
      }
      if (isUniqueViolation(error)) throw new IdentityError('device_already_linked', 409);
      throw error;
    } finally {
      client.release();
    }
  }

  async listDevices(identity: AuthIdentity): Promise<DeviceRecord[]> {
    const result = await this.pool.query<{
      id: string; name: string; platform: string; created_at: Date; last_seen_at: Date | null; revoked_at: Date | null;
    }>(
      `SELECT d.id,d.name,d.platform,d.created_at,
              GREATEST(
                d.last_seen_at,
                (SELECT max(s.last_seen_at) FROM sessions s
                 WHERE s.device_id=d.id AND s.business_id=d.business_id)
              ) AS last_seen_at,
              d.revoked_at
       FROM devices d WHERE d.business_id=$1 ORDER BY d.created_at`,
      [identity.businessId],
    );
    return result.rows.map((row) => ({
      id: row.id,
      name: row.name,
      platform: row.platform,
      createdAt: row.created_at.toISOString(),
      lastSeenAt: row.last_seen_at?.toISOString() ?? null,
      revokedAt: row.revoked_at?.toISOString() ?? null,
      current: row.id === identity.deviceId,
    }));
  }

  async revokeDevice(identity: AuthIdentity, deviceId: string): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await client.query(
        `UPDATE devices SET revoked_at=COALESCE(revoked_at,now())
         WHERE id=$1 AND business_id=$2 RETURNING id`,
        [deviceId, identity.businessId],
      );
      if (result.rowCount !== 1) throw new IdentityError('device_not_found', 404);
      await client.query(
        `UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE device_id=$1 AND business_id=$2`,
        [deviceId, identity.businessId],
      );
      await client.query(
        `UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE device_id=$1 AND business_id=$2`,
        [deviceId, identity.businessId],
      );
      await client.query(
        `INSERT INTO token_revocations (business_id,device_id,session_id,reason,revoked_by_owner_id)
         SELECT business_id,device_id,id,'device_revoked',$3 FROM sessions
         WHERE device_id=$1 AND business_id=$2 ON CONFLICT DO NOTHING`,
        [deviceId, identity.businessId, identity.ownerId],
      );
      await this.audit(client, identity.businessId, deviceId, identity.ownerId, 'device.revoked', { revoked_by_device_id: identity.deviceId });
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async logout(identity: AuthIdentity): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1', [identity.sessionId]);
      await client.query('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE session_id=$1', [identity.sessionId]);
      await client.query(
        `INSERT INTO token_revocations (business_id,device_id,session_id,reason,revoked_by_owner_id)
         VALUES ($1,$2,$3,'logout',$4) ON CONFLICT DO NOTHING`,
        [identity.businessId, identity.deviceId, identity.sessionId, identity.ownerId],
      );
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async listAccessPermissions(_identity: AuthIdentity): Promise<AccessPermissionRecord[]> {
    const result = await this.pool.query<AccessPermissionRecord>(
      `SELECT key,module,action,description FROM access_permissions ORDER BY module,action`,
    );
    return result.rows;
  }

  async listAccessRoles(identity: AuthIdentity): Promise<AccessRoleRecord[]> {
    const result = await this.pool.query<{
      id: string; name: string; roleType: 'administrator' | 'operational';
      permissions: string[]; system: boolean; version: number;
    }>(
      `SELECT r.id,r.name,r.role_type AS "roleType",r.is_system AS system,r.version,
              COALESCE(array_agg(rp.permission_key ORDER BY rp.permission_key)
                FILTER (WHERE rp.permission_key IS NOT NULL),'{}') AS permissions
       FROM access_roles r
       LEFT JOIN access_role_permissions rp ON rp.role_id=r.id
       WHERE r.business_id=$1 AND r.deleted_at IS NULL
       GROUP BY r.id ORDER BY lower(r.name)`,
      [identity.businessId],
    );
    return result.rows;
  }

  async saveAccessRole(identity: AuthIdentity, input: SaveAccessRoleInput): Promise<AccessRoleRecord> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const known = await client.query<{ key: string }>(
        'SELECT key FROM access_permissions WHERE key=ANY($1::text[])',
        [[...new Set(input.permissions)]],
      );
      if (known.rowCount !== new Set(input.permissions).size) throw new IdentityError('unknown_permission', 400);
      let roleId = input.id;
      if (roleId) {
        const current = await client.query<{ is_system: boolean; version: number }>(
          `SELECT is_system,version FROM access_roles
           WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL FOR UPDATE`,
          [roleId, identity.businessId],
        );
        const role = current.rows[0];
        if (!role) throw new IdentityError('role_not_found', 404);
        if (role.is_system) throw new IdentityError('system_role_immutable', 409);
        if (input.expectedVersion !== undefined && input.expectedVersion !== role.version) {
          throw new IdentityError('role_version_conflict', 409);
        }
        await client.query(
          `UPDATE access_roles SET name=$3,role_type=$4,version=version+1,updated_at=now()
           WHERE id=$1 AND business_id=$2`,
          [roleId, identity.businessId, input.name, input.roleType],
        );
        await client.query('DELETE FROM access_role_permissions WHERE role_id=$1', [roleId]);
      } else {
        const created = await client.query<{ id: string }>(
          `INSERT INTO access_roles (business_id,name,role_type) VALUES ($1,$2,$3) RETURNING id`,
          [identity.businessId, input.name, input.roleType],
        );
        roleId = created.rows[0]!.id;
      }
      await client.query(
        `INSERT INTO access_role_permissions (role_id,permission_key)
         SELECT $1,unnest($2::text[])`,
        [roleId, [...new Set(input.permissions)]],
      );
      await client.query(
        `UPDATE sessions SET revoked_at=COALESCE(revoked_at,now())
         WHERE user_id IN (SELECT user_id FROM business_user_roles WHERE role_id=$1)
           AND revoked_at IS NULL`,
        [roleId],
      );
      await client.query(
        `UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,now())
         WHERE session_id IN (
           SELECT s.id FROM sessions s JOIN business_user_roles ur ON ur.user_id=s.user_id
           WHERE ur.role_id=$1
         )`,
        [roleId],
      );
      await this.audit(client, identity.businessId, identity.deviceId, identity.ownerId,
        input.id ? 'access.role_updated' : 'access.role_created', {
          role_id: roleId,
          name: input.name,
          role_type: input.roleType,
          permissions: [...new Set(input.permissions)].sort(),
        }, identity.userId);
      const saved = await this.loadAccessRole(client, identity.businessId, roleId!);
      await client.query('COMMIT');
      return saved;
    } catch (error) {
      await client.query('ROLLBACK');
      if (isUniqueViolation(error)) throw new IdentityError('role_name_exists', 409);
      throw error;
    } finally {
      client.release();
    }
  }

  async listAccessUsers(identity: AuthIdentity): Promise<AccessUserRecord[]> {
    const result = await this.pool.query<{
      id: string; name: string; username: string; email: string | null; active: boolean;
      activated: boolean; security_version: number; roles: Array<{ id: string; name: string }>;
    }>(
      `SELECT u.id,u.name,u.username,u.email,u.active,
              u.activated_at IS NOT NULL AS activated,u.security_version,
              COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name) ORDER BY lower(r.name))
                FILTER (WHERE r.id IS NOT NULL),'[]'::jsonb) AS roles
       FROM business_users u
       LEFT JOIN business_user_roles ur ON ur.user_id=u.id
       LEFT JOIN access_roles r ON r.id=ur.role_id AND r.deleted_at IS NULL
       WHERE u.business_id=$1 AND u.deleted_at IS NULL
       GROUP BY u.id ORDER BY lower(u.name)`,
      [identity.businessId],
    );
    return result.rows.map((row) => ({
      id: row.id, name: row.name, username: row.username, email: row.email,
      active: row.active, activated: row.activated, roles: row.roles,
      securityVersion: row.security_version,
    }));
  }

  async createAccessUser(identity: AuthIdentity, input: CreateAccessUserInput): Promise<CreatedAccessUser> {
    const client = await this.pool.connect();
    const activationCode = randomBytes(32).toString('base64url');
    const activationExpiresAt = new Date(Date.now() + 72 * 60 * 60_000);
    try {
      await client.query('BEGIN');
      await this.requireAccessRoles(client, identity.businessId, input.roleIds);
      const created = await client.query<{ id: string }>(
        `INSERT INTO business_users
           (business_id,name,username,email,activation_code_hash,activation_expires_at)
         VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [identity.businessId, input.name, input.username.toLowerCase(), input.email ?? null,
          this.tokenHash(activationCode), activationExpiresAt],
      );
      const userId = created.rows[0]!.id;
      await client.query(
        `INSERT INTO business_user_roles (user_id,role_id)
         SELECT $1,unnest($2::uuid[])`,
        [userId, [...new Set(input.roleIds)]],
      );
      await this.audit(client, identity.businessId, identity.deviceId, identity.ownerId,
        'access.user_created', {
          affected_user_id: userId,
          name: input.name,
          username: input.username.toLowerCase(),
          role_ids: [...new Set(input.roleIds)],
        }, identity.userId);
      const user = await this.loadAccessUser(client, identity.businessId, userId);
      await client.query('COMMIT');
      return { user, activationCode, activationExpiresAt: activationExpiresAt.toISOString() };
    } catch (error) {
      await client.query('ROLLBACK');
      if (isUniqueViolation(error)) throw new IdentityError('user_identity_exists', 409);
      throw error;
    } finally {
      client.release();
    }
  }

  async updateAccessUser(identity: AuthIdentity, userId: string, input: UpdateAccessUserInput): Promise<AccessUserRecord> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const current = await client.query<{ remote_owner_id: string | null }>(
        `SELECT remote_owner_id FROM business_users
         WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL FOR UPDATE`,
        [userId, identity.businessId],
      );
      const user = current.rows[0];
      if (!user) throw new IdentityError('user_not_found', 404);
      if (user.remote_owner_id === identity.ownerId && !input.active) {
        throw new IdentityError('cannot_deactivate_current_owner', 409);
      }
      await this.requireAccessRoles(client, identity.businessId, input.roleIds);
      if (user.remote_owner_id) {
        const systemRole = await client.query(
          `SELECT 1 FROM access_roles WHERE id=ANY($1::uuid[]) AND business_id=$2
           AND is_system=true AND deleted_at IS NULL`,
          [input.roleIds, identity.businessId],
        );
        if (!systemRole.rowCount) throw new IdentityError('owner_role_required', 409);
      }
      await client.query(
        `UPDATE business_users SET name=$3,username=$4,email=$5,active=$6,
                security_version=security_version+1,updated_at=now()
         WHERE id=$1 AND business_id=$2`,
        [userId, identity.businessId, input.name, input.username.toLowerCase(), input.email ?? null, input.active],
      );
      await client.query('DELETE FROM business_user_roles WHERE user_id=$1', [userId]);
      await client.query(
        `INSERT INTO business_user_roles (user_id,role_id)
         SELECT $1,unnest($2::uuid[])`,
        [userId, [...new Set(input.roleIds)]],
      );
      await client.query(
        `UPDATE sessions SET revoked_at=COALESCE(revoked_at,now())
         WHERE user_id=$1 AND revoked_at IS NULL`,
        [userId],
      );
      await client.query(
        `UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,now())
         WHERE session_id IN (SELECT id FROM sessions WHERE user_id=$1)`,
        [userId],
      );
      await this.audit(client, identity.businessId, identity.deviceId, identity.ownerId,
        'access.user_updated', {
          affected_user_id: userId,
          name: input.name,
          username: input.username.toLowerCase(),
          active: input.active,
          role_ids: [...new Set(input.roleIds)],
        }, identity.userId);
      const saved = await this.loadAccessUser(client, identity.businessId, userId);
      await client.query('COMMIT');
      return saved;
    } catch (error) {
      await client.query('ROLLBACK');
      if (isUniqueViolation(error)) throw new IdentityError('user_identity_exists', 409);
      throw error;
    } finally {
      client.release();
    }
  }

  async activateAccessUser(input: ActivateAccessUserInput, requestKey: string): Promise<void> {
    const client = await this.pool.connect();
    const rateKey = `${requestKey}:${input.businessId}:${input.username.toLowerCase()}`;
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'access.activate', rateKey, 5, 30);
      const result = await client.query<{
        id: string; activation_code_hash: Buffer; activation_expires_at: Date;
      }>(
        `SELECT id,activation_code_hash,activation_expires_at
         FROM business_users
         WHERE business_id=$1 AND lower(username)=lower($2) AND active=true
           AND activated_at IS NULL AND deleted_at IS NULL FOR UPDATE`,
        [input.businessId, input.username],
      );
      const user = result.rows[0];
      const suppliedHash = this.tokenHash(input.activationCode);
      const valid = user !== undefined &&
        user.activation_expires_at > new Date() &&
        user.activation_code_hash.length === suppliedHash.length &&
        timingSafeEqual(user.activation_code_hash, suppliedHash);
      if (!valid) throw new IdentityError('activation_invalid_or_expired', 409);
      const salt = randomBytes(16);
      const passwordHash = await hashPassword(input.password, salt);
      await client.query(
        `UPDATE business_users SET password_salt=$2,password_hash=$3,activated_at=now(),
                activation_code_hash=NULL,activation_expires_at=NULL,
                security_version=security_version+1,updated_at=now()
         WHERE id=$1`,
        [user.id, salt, passwordHash],
      );
      await this.attempt(client, 'access.activate', rateKey, true);
      await this.audit(client, input.businessId, null, null, 'access.user_activated', {
        affected_user_id: user.id,
      }, user.id);
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      if (error instanceof IdentityError && error.code === 'activation_invalid_or_expired') {
        await this.recordAttempt('access.activate', rateKey, false);
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async loginAccessUser(input: AccessUserLoginInput, requestKey: string): Promise<IssuedIdentity> {
    const client = await this.pool.connect();
    const rateKey = `${requestKey}:${input.businessId}:${input.username.toLowerCase()}`;
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'access.login', rateKey, 5, 15);
      const result = await client.query<{
        id: string; password_salt: Buffer; password_hash: Buffer;
      }>(
        `SELECT id,password_salt,password_hash FROM business_users
         WHERE business_id=$1 AND lower(username)=lower($2) AND active=true
           AND activated_at IS NOT NULL AND deleted_at IS NULL FOR UPDATE`,
        [input.businessId, input.username],
      );
      const user = result.rows[0];
      const valid = user !== undefined &&
        await verifyPassword(input.password, user.password_salt, user.password_hash);
      const device = valid ? await client.query(
        `SELECT id FROM devices WHERE id=$1 AND business_id=$2 AND revoked_at IS NULL`,
        [input.deviceId, input.businessId],
      ) : null;
      if (!valid || device?.rowCount !== 1) throw new IdentityError('invalid_credentials', 401);
      const permissionRows = await client.query<{ permission_key: string }>(
        `SELECT DISTINCT rp.permission_key FROM business_user_roles ur
         JOIN access_roles r ON r.id=ur.role_id AND r.business_id=$2 AND r.deleted_at IS NULL
         JOIN access_role_permissions rp ON rp.role_id=r.id
         WHERE ur.user_id=$1 AND rp.permission_key<>'devices:manage'`,
        [user.id, input.businessId],
      );
      const permissions = [...new Set([
        'sync:read', 'sync:write', ...permissionRows.rows.map((row) => row.permission_key),
      ])];
      const issued = await this.issue(
        client, input.businessId, input.deviceId, null, permissions, undefined, user.id,
      );
      await this.attempt(client, 'access.login', rateKey, true);
      await this.audit(client, input.businessId, input.deviceId, null, 'access.session_login', {
        affected_user_id: user.id,
      }, user.id);
      await client.query('COMMIT');
      return issued;
    } catch (error) {
      await client.query('ROLLBACK');
      if (error instanceof IdentityError && error.code === 'invalid_credentials') {
        await this.recordAttempt('access.login', rateKey, false);
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async deleteBusiness(input: DeleteBusinessInput, requestKey: string): Promise<string> {
    const client = await this.pool.connect();
    const rateKey = `${requestKey}:${input.email.toLowerCase()}:${input.businessId ?? 'unspecified'}`;
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'account.delete', rateKey, 3, 60);
      const result = await client.query<{
        id: string; business_id: string; password_salt: Buffer; password_hash: Buffer;
      }>(
        `SELECT o.id,o.business_id,o.password_salt,o.password_hash
         FROM remote_owners o JOIN businesses b ON b.id=o.business_id
         WHERE o.email=lower($1) AND o.disabled_at IS NULL AND b.disabled_at IS NULL
           AND ($2::uuid IS NULL OR o.business_id=$2::uuid)
         FOR UPDATE OF o,b`,
        [input.email, input.businessId ?? null],
      );
      const valid = [];
      for (const owner of result.rows) {
        if (await verifyPassword(input.password, owner.password_salt, owner.password_hash)) valid.push(owner);
      }
      if (result.rows.length === 0) {
        await verifyPassword(input.password, Buffer.alloc(16), Buffer.alloc(64));
      }
      if (valid.length !== 1) {
        throw new IdentityError(valid.length > 1 ? 'business_id_required' : 'invalid_credentials', valid.length > 1 ? 409 : 401);
      }
      const businessId = valid[0]!.business_id;
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`business:${businessId}`]);
      for (const table of [
        'business_assets',
        'sync_conflicts',
        'sync_inventory_movements',
        'sync_financial_events',
        'sync_entities',
        'sync_operations',
        'token_revocations',
        'refresh_tokens',
        'sessions',
        'linking_codes',
        'devices',
        'security_audit',
        'remote_owners',
      ]) {
        await client.query(`DELETE FROM ${table} WHERE business_id=$1`, [businessId]);
      }
      const deleted = await client.query('DELETE FROM businesses WHERE id=$1', [businessId]);
      if (deleted.rowCount !== 1) throw new IdentityError('invalid_credentials', 401);
      await client.query('DELETE FROM auth_attempts WHERE action=$1 AND key_hash=$2', [
        'account.delete',
        this.tokenHash(rateKey),
      ]);
      await client.query('COMMIT');
      return businessId;
    } catch (error) {
      await client.query('ROLLBACK');
      if (error instanceof IdentityError &&
          (error.code === 'invalid_credentials' || error.code === 'business_id_required')) {
        await this.recordAttempt('account.delete', rateKey, false);
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async close(): Promise<void> { await this.pool.end(); }

  async listSecurityAudit(
    identity: AuthIdentity,
    limit: number,
  ): Promise<SecurityAuditRecord[]> {
    const result = await this.pool.query<{
      id: string; event: string; deviceId: string | null;
      ownerId: string | null; userId: string | null; actorName: string | null;
      deviceName: string | null; details: Record<string, unknown>; createdAt: Date;
    }>(
      `WITH events AS (
         SELECT 'security:'||a.id::text AS id,a.event,a.device_id::text AS device_id,
                a.owner_id::text AS owner_id,a.user_id::text AS user_id,
                COALESCE(u.name,o.email,'Sistema') AS actor_name,
                a.details,a.created_at
         FROM security_audit a
         LEFT JOIN business_users u ON u.id=a.user_id
         LEFT JOIN remote_owners o ON o.id=a.owner_id
         WHERE a.business_id=$1
         UNION ALL
         SELECT 'operation:'||s.operation_id::text,s.type,s.device_id::text,NULL,
                s.content#>>'{_audit,actor_id}',
                COALESCE(s.content#>>'{_audit,actor_name}','Dispositivo'),
                jsonb_build_object(
                  'operation_id',s.operation_id,
                  'server_cursor',s.server_cursor,
                  'content',s.content-'_audit'
                ),s.occurred_at
         FROM sync_operations s WHERE s.business_id=$1
       )
       SELECT e.id,e.event,e.device_id AS "deviceId",e.owner_id AS "ownerId",
              e.user_id AS "userId",e.actor_name AS "actorName",
              d.name AS "deviceName",e.details,e.created_at AS "createdAt"
       FROM events e
       LEFT JOIN devices d ON d.id::text=e.device_id AND d.business_id=$1
       ORDER BY e.created_at DESC,e.id DESC LIMIT $2`,
      [identity.businessId, limit],
    );
    return result.rows.map((row) => ({
      id: row.id,
      event: row.event,
      deviceId: row.deviceId,
      ownerId: row.ownerId,
      userId: row.userId,
      actorName: row.actorName ?? 'Sistema',
      deviceName: row.deviceName,
      details: row.details,
      createdAt: row.createdAt.toISOString(),
    }));
  }

  private async issue(
    client: PoolClient,
    businessId: string,
    deviceId: string,
    ownerId: string | null,
    permissions: string[],
    familyId?: string,
    userId: string | null = null,
  ): Promise<IssuedIdentity> {
    const accessToken = randomBytes(32).toString('base64url');
    const refreshToken = randomBytes(48).toString('base64url');
    const accessExpiresAt = new Date(Date.now() + this.accessTtlMinutes * 60_000);
    const refreshExpiresAt = new Date(Date.now() + this.refreshTtlDays * 86_400_000);
    const session = await client.query<{ id: string }>(
      `INSERT INTO sessions
         (business_id,device_id,owner_id,user_id,access_token_hash,permissions,expires_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
      [businessId, deviceId, ownerId, userId, this.tokenHash(accessToken), permissions, accessExpiresAt],
    );
    const family = familyId ?? randomBytes(16).toString('hex');
    await client.query(
      `INSERT INTO refresh_tokens (session_id,family_id,business_id,device_id,token_hash,expires_at)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [session.rows[0]!.id, family, businessId, deviceId, this.tokenHash(refreshToken), refreshExpiresAt],
    );
    await client.query('UPDATE devices SET last_seen_at=now() WHERE id=$1 AND business_id=$2', [deviceId, businessId]);
    let offlineGrant: ReturnType<OfflineGrantIssuer['issue']> | null = null;
    let principalName: string | null = null;
    let username: string | null = null;
    let roleType: 'administrator' | 'operational' | null = null;
    if (userId) {
      const user = await client.query<{
        security_version: number; name: string; username: string;
        role_type: 'administrator' | 'operational';
      }>(
        `SELECT u.security_version,u.name,u.username,
                CASE WHEN bool_or(r.role_type='administrator')
                  THEN 'administrator' ELSE 'operational' END AS role_type
         FROM business_users u
         LEFT JOIN business_user_roles ur ON ur.user_id=u.id
         LEFT JOIN access_roles r ON r.id=ur.role_id AND r.deleted_at IS NULL
         WHERE u.id=$1 AND u.business_id=$2 AND u.active=true AND u.deleted_at IS NULL
         GROUP BY u.id,u.security_version,u.name,u.username`,
        [userId, businessId],
      );
      if (user.rows[0]) {
        principalName = user.rows[0].name;
        username = user.rows[0].username;
        roleType = user.rows[0].role_type;
        offlineGrant = this.offlineGrants.issue({
          business_id: businessId,
          device_id: deviceId,
          principal_id: userId,
          principal_name: principalName,
          username,
          role_type: roleType,
          permissions,
          security_version: user.rows[0].security_version,
        });
      }
    }
    return {
      businessId,
      deviceId,
      ownerId,
      userId,
      sessionId: session.rows[0]!.id,
      permissions,
      principalName,
      username,
      roleType,
      accessToken,
      refreshToken,
      accessExpiresAt: accessExpiresAt.toISOString(),
      refreshExpiresAt: refreshExpiresAt.toISOString(),
      offlineGrant: offlineGrant?.token ?? null,
      offlineGrantPublicKey: offlineGrant?.publicKey ?? null,
      offlineGrantExpiresAt: offlineGrant?.expiresAt ?? null,
    };
  }

  private async loadAccessRole(
    client: PoolClient,
    businessId: string,
    roleId: string,
  ): Promise<AccessRoleRecord> {
    const result = await client.query<{
      id: string; name: string; roleType: 'administrator' | 'operational';
      permissions: string[]; system: boolean; version: number;
    }>(
      `SELECT r.id,r.name,r.role_type AS "roleType",r.is_system AS system,r.version,
              COALESCE(array_agg(rp.permission_key ORDER BY rp.permission_key)
                FILTER (WHERE rp.permission_key IS NOT NULL),'{}') AS permissions
       FROM access_roles r LEFT JOIN access_role_permissions rp ON rp.role_id=r.id
       WHERE r.id=$1 AND r.business_id=$2 AND r.deleted_at IS NULL
       GROUP BY r.id`,
      [roleId, businessId],
    );
    const role = result.rows[0];
    if (!role) throw new IdentityError('role_not_found', 404);
    return role;
  }

  private async requireAccessRoles(client: PoolClient, businessId: string, roleIds: string[]): Promise<void> {
    const unique = [...new Set(roleIds)];
    const result = await client.query<{ id: string }>(
      `SELECT id FROM access_roles
       WHERE business_id=$1 AND deleted_at IS NULL AND id=ANY($2::uuid[])`,
      [businessId, unique],
    );
    if (result.rowCount !== unique.length) throw new IdentityError('role_not_found', 404);
  }

  private async loadAccessUser(
    client: PoolClient,
    businessId: string,
    userId: string,
  ): Promise<AccessUserRecord> {
    const result = await client.query<{
      id: string; name: string; username: string; email: string | null; active: boolean;
      activated: boolean; security_version: number; roles: Array<{ id: string; name: string }>;
    }>(
      `SELECT u.id,u.name,u.username,u.email,u.active,
              u.activated_at IS NOT NULL AS activated,u.security_version,
              COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name) ORDER BY lower(r.name))
                FILTER (WHERE r.id IS NOT NULL),'[]'::jsonb) AS roles
       FROM business_users u
       LEFT JOIN business_user_roles ur ON ur.user_id=u.id
       LEFT JOIN access_roles r ON r.id=ur.role_id AND r.deleted_at IS NULL
       WHERE u.id=$1 AND u.business_id=$2 AND u.deleted_at IS NULL
       GROUP BY u.id`,
      [userId, businessId],
    );
    const row = result.rows[0];
    if (!row) throw new IdentityError('user_not_found', 404);
    return {
      id: row.id, name: row.name, username: row.username, email: row.email,
      active: row.active, activated: row.activated, roles: row.roles,
      securityVersion: row.security_version,
    };
  }

  private tokenHash(value: string): Buffer {
    return createHash('sha256').update(this.tokenPepper).update('\0').update(value).digest();
  }

  private async rateLimit(client: PoolClient, action: string, rawKey: string, limit: number, minutes: number): Promise<void> {
    const key = this.tokenHash(rawKey);
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`rate:${action}:${key.toString('hex')}`]);
    const result = await client.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM auth_attempts
       WHERE action=$1 AND key_hash=$2 AND success=false AND attempted_at>now()-($3 || ' minutes')::interval`,
      [action, key, minutes],
    );
    if (Number(result.rows[0]!.count) >= limit) throw new IdentityError('rate_limited', 429);
  }

  private async attempt(client: PoolClient, action: string, rawKey: string, success: boolean): Promise<void> {
    await client.query('INSERT INTO auth_attempts (action,key_hash,success) VALUES ($1,$2,$3)', [action, this.tokenHash(rawKey), success]);
  }

  private async recordAttempt(action: string, rawKey: string, success: boolean): Promise<void> {
    await this.pool.query('INSERT INTO auth_attempts (action,key_hash,success) VALUES ($1,$2,$3)', [action, this.tokenHash(rawKey), success]);
  }

  private async revokeFamily(value: { familyId: string; businessId: string; deviceId: string; ownerId: string | null }): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(
        'UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE family_id=$1',
        [value.familyId],
      );
      await client.query(
        `UPDATE sessions SET revoked_at=COALESCE(revoked_at,now())
         WHERE id IN (SELECT session_id FROM refresh_tokens WHERE family_id=$1)`,
        [value.familyId],
      );
      await this.audit(client, value.businessId, value.deviceId, value.ownerId, 'token.reuse_or_invalid', {
        family_id: value.familyId,
      });
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  private async audit(
    client: PoolClient,
    businessId: string,
    deviceId: string | null,
    ownerId: string | null,
    event: string,
    details: Record<string, unknown>,
    userId: string | null = null,
  ): Promise<void> {
    await client.query(
      `INSERT INTO security_audit (business_id,device_id,owner_id,user_id,event,details)
       VALUES ($1,$2,$3,$4,$5,$6::jsonb)`,
      [businessId, deviceId, ownerId, userId, event, JSON.stringify(details)],
    );
  }
}

async function hashPassword(password: string, salt: Buffer): Promise<Buffer> {
  if (password.length < 12 || password.length > 200) throw new IdentityError('weak_password', 400);
  return new Promise((resolve, reject) => {
    scryptCallback(password.normalize('NFKC'), salt, 64, {
      N: 32768,
      r: 8,
      p: 1,
      maxmem: 64 * 1024 * 1024,
    }, (error, value) => {
      if (error) reject(error); else resolve(value);
    });
  });
}

async function verifyPassword(password: string, salt: Buffer, expected: Buffer): Promise<boolean> {
  try {
    const actual = await hashPassword(password, salt);
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

function randomCode(length: number): string {
  const bytes = randomBytes(length);
  return [...bytes].map((value) => codeAlphabet[value % codeAlphabet.length]).join('');
}

function isUniqueViolation(error: unknown): boolean {
  return typeof error === 'object' && error !== null && 'code' in error && error.code === '23505';
}
