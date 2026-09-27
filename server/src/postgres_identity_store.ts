import { createHash, randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';

import { Pool, type PoolClient } from 'pg';

import {
  IdentityError,
  ownerPermissions,
  type AuthIdentity,
  type CreateBusinessInput,
  type DeviceRecord,
  type IdentityStore,
  type IssuedIdentity,
  type LinkDeviceInput,
  type LoginInput,
} from './identity.js';

const codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

export class PostgresIdentityStore implements IdentityStore {
  private readonly pool: Pool;

  constructor(
    databaseUrl: string,
    private readonly tokenPepper: string,
    private readonly accessTtlMinutes = 15,
    private readonly refreshTtlDays = 30,
  ) {
    this.pool = new Pool({ connectionString: databaseUrl, max: 10 });
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
    let compromised: { familyId: string; businessId: string; deviceId: string; ownerId: string } | null = null;
    try {
      await client.query('BEGIN');
      await this.rateLimit(client, 'refresh', rateKey, 10, 15);
      const tokenHash = this.tokenHash(refreshToken);
      const result = await client.query<{
        id: string; session_id: string; family_id: string; business_id: string; device_id: string;
        owner_id: string; permissions: string[]; expires_at: Date; used_at: Date | null; revoked_at: Date | null;
      }>(
        `SELECT r.id,r.session_id,r.family_id,r.business_id,r.device_id,s.owner_id,s.permissions,
                r.expires_at,r.used_at,r.revoked_at
         FROM refresh_tokens r JOIN sessions s ON s.id=r.session_id
         JOIN devices d ON d.id=r.device_id AND d.business_id=r.business_id
         WHERE r.token_hash=$1 FOR UPDATE OF r,s`,
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
      const issued = await this.issue(client, row.business_id, row.device_id, row.owner_id, row.permissions, row.family_id);
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
      id: string; business_id: string; device_id: string; owner_id: string; permissions: string[];
    }>(
      `UPDATE sessions s SET last_seen_at=now()
       FROM devices d,remote_owners o
       WHERE s.access_token_hash=$1 AND s.expires_at>now() AND s.revoked_at IS NULL
         AND d.id=s.device_id AND d.business_id=s.business_id AND d.revoked_at IS NULL
         AND o.id=s.owner_id AND o.business_id=s.business_id AND o.disabled_at IS NULL
       RETURNING s.id,s.business_id,s.device_id,s.owner_id,s.permissions`,
      [this.tokenHash(accessToken)],
    );
    const row = result.rows[0];
    return row ? {
      sessionId: row.id,
      businessId: row.business_id,
      deviceId: row.device_id,
      ownerId: row.owner_id,
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
      const occupied = await client.query(
        `SELECT business_id FROM devices WHERE id=$1 AND revoked_at IS NULL`,
        [input.deviceId],
      );
      if (occupied.rowCount && occupied.rows[0]?.business_id !== link.business_id) {
        throw new IdentityError('device_belongs_to_another_business', 409);
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
              GREATEST(d.last_seen_at,max(s.last_seen_at)) AS last_seen_at,d.revoked_at
       FROM devices d LEFT JOIN sessions s ON s.device_id=d.id AND s.business_id=d.business_id
       WHERE d.business_id=$1 GROUP BY d.id ORDER BY d.created_at`,
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

  async close(): Promise<void> { await this.pool.end(); }

  private async issue(
    client: PoolClient,
    businessId: string,
    deviceId: string,
    ownerId: string,
    permissions: string[],
    familyId?: string,
  ): Promise<IssuedIdentity> {
    const accessToken = randomBytes(32).toString('base64url');
    const refreshToken = randomBytes(48).toString('base64url');
    const accessExpiresAt = new Date(Date.now() + this.accessTtlMinutes * 60_000);
    const refreshExpiresAt = new Date(Date.now() + this.refreshTtlDays * 86_400_000);
    const session = await client.query<{ id: string }>(
      `INSERT INTO sessions (business_id,device_id,owner_id,access_token_hash,permissions,expires_at)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [businessId, deviceId, ownerId, this.tokenHash(accessToken), permissions, accessExpiresAt],
    );
    const family = familyId ?? randomBytes(16).toString('hex');
    await client.query(
      `INSERT INTO refresh_tokens (session_id,family_id,business_id,device_id,token_hash,expires_at)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [session.rows[0]!.id, family, businessId, deviceId, this.tokenHash(refreshToken), refreshExpiresAt],
    );
    await client.query('UPDATE devices SET last_seen_at=now() WHERE id=$1 AND business_id=$2', [deviceId, businessId]);
    return {
      businessId,
      deviceId,
      ownerId,
      sessionId: session.rows[0]!.id,
      permissions,
      accessToken,
      refreshToken,
      accessExpiresAt: accessExpiresAt.toISOString(),
      refreshExpiresAt: refreshExpiresAt.toISOString(),
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

  private async revokeFamily(value: { familyId: string; businessId: string; deviceId: string; ownerId: string }): Promise<void> {
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

  private async audit(client: PoolClient, businessId: string, deviceId: string | null, ownerId: string | null, event: string, details: Record<string, unknown>): Promise<void> {
    await client.query(
      `INSERT INTO security_audit (business_id,device_id,owner_id,event,details)
       VALUES ($1,$2,$3,$4,$5::jsonb)`,
      [businessId, deviceId, ownerId, event, JSON.stringify(details)],
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
