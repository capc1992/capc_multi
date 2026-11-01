import { randomUUID } from 'node:crypto';

import { Pool } from 'pg';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';

import { buildApp } from '../src/app.js';
import { PostgresIdentityStore } from '../src/postgres_identity_store.js';
import { PostgresSyncStore } from '../src/postgres_store.js';

const databaseUrl = process.env.DATABASE_URL;
const pepper = process.env.AUTH_TOKEN_PEPPER ?? 'integration-test-pepper-at-least-32-characters';
const describePostgres = databaseUrl ? describe : describe.skip;
const pool = databaseUrl ? new Pool({ connectionString: databaseUrl }) : null;

describePostgres('PostgreSQL identity and sync integration', () => {
  const apps: ReturnType<typeof buildApp>[] = [];

  beforeEach(async () => {
    await pool!.query(`TRUNCATE TABLE
      auth_attempts,security_audit,token_revocations,linking_codes,refresh_tokens,sessions,
      devices,remote_owners,businesses,sync_conflicts,sync_inventory_movements,
      sync_financial_events,sync_entities,sync_operations RESTART IDENTITY CASCADE`);
  });

  afterAll(async () => {
    await Promise.all(apps.splice(0).map((app) => app.close()));
    await pool?.end();
  });

  function setup() {
    const app = buildApp({
      store: new PostgresSyncStore(databaseUrl!),
      identityStore: new PostgresIdentityStore(databaseUrl!, pepper, 15, 30),
      logger: false,
    });
    apps.push(app);
    return app;
  }

  async function createBusiness(
    app: ReturnType<typeof buildApp>,
    businessId = '11111111-1111-4111-8111-111111111111',
    deviceId = '33333333-3333-4333-8333-333333333333',
    email = 'owner@example.test',
  ) {
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/identity/businesses',
      payload: {
        business_id: businessId,
        business_name: `Negocio ${businessId.slice(0, 4)}`,
        email,
        password: 'remote-password-2026',
        device_id: deviceId,
        device_name: 'Equipo principal',
        platform: 'Windows',
      },
    });
    expect(response.statusCode).toBe(201);
    return response.json<{
      business_id: string;
      device_id: string;
      access_token: string;
      refresh_token: string;
    }>();
  }

  function headers(identity: { business_id: string; access_token: string }) {
    return {
      authorization: `Bearer ${identity.access_token}`,
      'x-business-id': identity.business_id,
    };
  }

  it('stores only token hashes and rotates refresh tokens with reuse revocation', async () => {
    const app = setup();
    const identity = await createBusiness(app);
    const stored = await pool!.query<{ access: string; refresh: string }>(
      `SELECT encode(s.access_token_hash,'hex') AS access,encode(r.token_hash,'hex') AS refresh
       FROM sessions s JOIN refresh_tokens r ON r.session_id=s.id`,
    );
    expect(stored.rows[0]!.access).not.toContain(identity.access_token);
    expect(stored.rows[0]!.refresh).not.toContain(identity.refresh_token);
    expect(stored.rows[0]!.access).toHaveLength(64);

    const rotated = await app.inject({
      method: 'POST',
      url: '/api/v1/identity/refresh',
      payload: { refresh_token: identity.refresh_token, device_id: identity.device_id },
    });
    expect(rotated.statusCode).toBe(200);
    const replacement = rotated.json<{ access_token: string; refresh_token: string; business_id: string }>();
    expect(replacement.refresh_token).not.toBe(identity.refresh_token);

    const reused = await app.inject({
      method: 'POST',
      url: '/api/v1/identity/refresh',
      payload: { refresh_token: identity.refresh_token, device_id: identity.device_id },
    });
    expect(reused.statusCode).toBe(401);
    const revokedAccess = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${identity.business_id}&device_id=${identity.device_id}&after=0`,
      headers: { authorization: `Bearer ${replacement.access_token}`, 'x-business-id': identity.business_id },
    });
    expect(revokedAccess.statusCode).toBe(401);
  });

  it('deletes identity, sessions, devices and synchronized business data', async () => {
    const app = setup();
    const identity = await createBusiness(app);
    const operationId = randomUUID();
    const entityId = randomUUID();
    const pushed = await app.inject({
      method: 'POST',
      url: '/api/v1/sync/push',
      headers: headers(identity),
      payload: {
        operations: [{
          business_id: identity.business_id,
          device_id: identity.device_id,
          operation_id: operationId,
          type: 'customer.saved',
          schema_version: 1,
          occurred_at: '2026-09-27T03:00:00.000Z',
          content: { id: entityId, name: 'Cliente', revision: 1 },
        }],
      },
    });
    expect(pushed.statusCode).toBe(200);

    const deleted = await app.inject({
      method: 'POST',
      url: '/api/v1/identity/delete-account',
      payload: {
        business_id: identity.business_id,
        email: 'owner@example.test',
        password: 'remote-password-2026',
        confirmation: 'ELIMINAR',
      },
    });
    expect(deleted.statusCode).toBe(204);

    const business = await pool!.query<{ count: string }>(
      'SELECT count(*)::text AS count FROM businesses WHERE id=$1',
      [identity.business_id],
    );
    expect(Number(business.rows[0]!.count), 'businesses').toBe(0);
    for (const table of [
      'remote_owners', 'devices', 'sessions', 'refresh_tokens',
      'linking_codes', 'token_revocations', 'security_audit', 'sync_operations',
      'sync_entities', 'sync_financial_events', 'sync_inventory_movements',
      'sync_conflicts', 'business_assets', 'access_roles', 'business_users',
    ]) {
      const result = await pool!.query<{ count: string }>(
        `SELECT count(*)::text AS count FROM ${table} WHERE business_id=$1`,
        [identity.business_id],
      );
      expect(Number(result.rows[0]!.count), table).toBe(0);
    }
    const rejected = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${identity.business_id}&device_id=${identity.device_id}&after=0`,
      headers: headers(identity),
    });
    expect(rejected.statusCode).toBe(401);
  });

  it('persists tenant-scoped roles and hashes one-time activation codes', async () => {
    const app = setup();
    const identity = await createBusiness(app);
    const roleResponse = await app.inject({
      method: 'POST', url: '/api/v1/access/roles', headers: headers(identity),
      payload: {
        name: 'Auxiliar de caja',
        role_type: 'operational',
        permissions: ['ventas.ver', 'ventas.crear', 'auditoria.ver'],
      },
    });
    expect(roleResponse.statusCode).toBe(201);
    const role = roleResponse.json<{ role: { id: string } }>().role;
    const userResponse = await app.inject({
      method: 'POST', url: '/api/v1/access/users', headers: headers(identity),
      payload: {
        name: 'Carlos', username: 'carlos', email: 'carlos@example.test', role_ids: [role.id],
      },
    });
    expect(userResponse.statusCode).toBe(201);
    const created = userResponse.json<{
      user: { id: string; activated: boolean };
      activation_code: string;
    }>();
    expect(created.user.activated).toBe(false);
    const stored = await pool!.query<{ hash: Buffer; roles: string }>(
      `SELECT u.activation_code_hash AS hash,count(ur.role_id)::text AS roles
       FROM business_users u LEFT JOIN business_user_roles ur ON ur.user_id=u.id
       WHERE u.id=$1 GROUP BY u.id`,
      [created.user.id],
    );
    expect(stored.rows[0]!.hash).toHaveLength(32);
    expect(stored.rows[0]!.hash.toString('utf8')).not.toContain(created.activation_code);
    expect(Number(stored.rows[0]!.roles)).toBe(1);
    const activated = await app.inject({
      method: 'POST', url: '/api/v1/access/activate',
      payload: {
        business_id: identity.business_id, username: 'carlos',
        activation_code: created.activation_code, password: 'central-password-2026',
      },
    });
    expect(activated.statusCode).toBe(204);
    const login = await app.inject({
      method: 'POST', url: '/api/v1/access/login',
      payload: {
        business_id: identity.business_id, username: 'carlos',
        password: 'central-password-2026', device_id: identity.device_id,
      },
    });
    expect(login.statusCode).toBe(200);
    expect(login.json().permissions).toEqual(expect.arrayContaining([
      'sync:read', 'sync:write', 'ventas.ver', 'ventas.crear', 'auditoria.ver',
    ]));
    const userIdentity = login.json<{
      access_token: string;
      business_id: string;
      device_id: string;
    }>();
    const operationId = randomUUID();
    const pushed = await app.inject({
      method: 'POST',
      url: '/api/v1/sync/push',
      headers: headers(userIdentity),
      payload: {
        operations: [{
          business_id: identity.business_id,
          device_id: identity.device_id,
          operation_id: operationId,
          type: 'customer.saved',
          schema_version: 1,
          occurred_at: '2026-09-28T12:00:00.000Z',
          content: {
            id: randomUUID(),
            name: 'Cliente auditado',
            revision: 1,
            _audit: {
              actor_id: created.user.id,
              actor_name: 'Carlos',
              username: 'carlos',
              central: true,
              role_type: 'operational',
            },
          },
        }],
      },
    });
    expect(pushed.statusCode).toBe(200);
    const audit = await app.inject({
      method: 'GET',
      url: '/api/v1/access/audit?limit=50',
      headers: headers(userIdentity),
    });
    expect(audit.statusCode).toBe(200);
    expect(audit.json().audit).toEqual(expect.arrayContaining([
      expect.objectContaining({ event: 'access.session_login', actorName: 'Carlos' }),
      expect.objectContaining({
        event: 'customer.saved',
        actorName: 'Carlos',
        userId: created.user.id,
      }),
    ]));
    const protectedValues = await pool!.query<{
      activation_code_hash: Buffer | null; password_hash: Buffer;
    }>(
      `SELECT activation_code_hash,password_hash FROM business_users WHERE id=$1`,
      [created.user.id],
    );
    expect(protectedValues.rows[0]!.activation_code_hash).toBeNull();
    expect(protectedValues.rows[0]!.password_hash).toHaveLength(64);
  });

  it('links once, rejects expired/reused codes and a device from another business', async () => {
    const app = setup();
    const first = await createBusiness(app);
    const codeResponse = await app.inject({ method: 'POST', url: '/api/v1/identity/link-codes', headers: headers(first) });
    const code = codeResponse.json<{ code: string }>().code;
    const secondDevice = '44444444-4444-4444-8444-444444444444';
    const linked = await app.inject({
      method: 'POST', url: '/api/v1/identity/link',
      payload: { code, device_id: secondDevice, device_name: 'Caja 2', platform: 'Windows', local_business_id: randomUUID(), local_state: 'new' },
    });
    expect(linked.statusCode).toBe(200);
    expect(linked.json().business_id).toBe(first.business_id);
    const reused = await app.inject({
      method: 'POST', url: '/api/v1/identity/link',
      payload: { code, device_id: randomUUID(), device_name: 'Caja 3', platform: 'Windows', local_business_id: randomUUID(), local_state: 'new' },
    });
    expect(reused.statusCode).toBe(409);
    expect(reused.json().error).toBe('link_code_used');

    const expiringResponse = await app.inject({ method: 'POST', url: '/api/v1/identity/link-codes', headers: headers(first) });
    const expiring = expiringResponse.json<{ code: string }>().code;
    await pool!.query('UPDATE linking_codes SET expires_at=now()-interval \'1 second\' WHERE used_at IS NULL');
    const expired = await app.inject({
      method: 'POST', url: '/api/v1/identity/link',
      payload: { code: expiring, device_id: randomUUID(), device_name: 'Tarde', platform: 'Windows', local_business_id: randomUUID(), local_state: 'new' },
    });
    expect(expired.statusCode).toBe(409);
    expect(expired.json().error).toBe('link_code_invalid_or_expired');

    const otherBusiness = await createBusiness(
      app,
      '22222222-2222-4222-8222-222222222222',
      '55555555-5555-4555-8555-555555555555',
      'other@example.test',
    );
    const otherCodeResponse = await app.inject({ method: 'POST', url: '/api/v1/identity/link-codes', headers: headers(otherBusiness) });
    const otherCode = otherCodeResponse.json<{ code: string }>().code;
    const foreign = await app.inject({
      method: 'POST', url: '/api/v1/identity/link',
      payload: { code: otherCode, device_id: secondDevice, device_name: 'Caja ajena', platform: 'Windows', local_business_id: first.business_id, local_state: 'no_movements' },
    });
    expect(foreign.statusCode).toBe(409);
    expect(foreign.json().error).toBe('device_belongs_to_another_business');
  });

  it('revokes lost devices and never trusts X-Business-Id alone', async () => {
    const app = setup();
    const first = await createBusiness(app);
    const linkCode = (await app.inject({ method: 'POST', url: '/api/v1/identity/link-codes', headers: headers(first) })).json<{ code: string }>().code;
    const lostDevice = '44444444-4444-4444-8444-444444444444';
    const lost = (await app.inject({
      method: 'POST', url: '/api/v1/identity/link',
      payload: { code: linkCode, device_id: lostDevice, device_name: 'Portátil', platform: 'Windows', local_business_id: randomUUID(), local_state: 'new' },
    })).json<{ access_token: string; business_id: string }>();
    const devices = await app.inject({ method: 'GET', url: '/api/v1/identity/devices', headers: headers(first) });
    expect(devices.json().devices).toHaveLength(2);
    expect((await app.inject({ method: 'DELETE', url: `/api/v1/identity/devices/${lostDevice}`, headers: headers(first) })).statusCode).toBe(204);
    const rejected = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${first.business_id}&device_id=${lostDevice}&after=0`,
      headers: { authorization: `Bearer ${lost.access_token}`, 'x-business-id': first.business_id },
    });
    expect(rejected.statusCode).toBe(401);
    const headerOnly = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${first.business_id}&device_id=${first.device_id}&after=0`,
      headers: { 'x-business-id': first.business_id },
    });
    expect(headerOnly.statusCode).toBe(401);
  });

  it('enforces idempotency, business isolation and monotonic cursors in PostgreSQL', async () => {
    const app = setup();
    const first = await createBusiness(app);
    const other = await createBusiness(
      app,
      '22222222-2222-4222-8222-222222222222',
      '55555555-5555-4555-8555-555555555555',
      'other@example.test',
    );
    const makeOperation = (operationId: string, type: string) => ({
      business_id: first.business_id,
      device_id: first.device_id,
      operation_id: operationId,
      type,
      schema_version: 1,
      occurred_at: '2026-09-27T03:00:00.000Z',
      content: { id: randomUUID(), name: 'Registro', revision: 1, updated_at: '2026-09-27T03:00:00.000Z' },
    });
    const operations = [
      makeOperation('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'customer.saved'),
      makeOperation('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'supplier.saved'),
    ];
    const firstPush = await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers: headers(first), payload: { operations } });
    const retry = await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers: headers(first), payload: { operations: [operations[0]] } });
    expect(retry.json().accepted[0].duplicate).toBe(true);
    expect(retry.json().accepted[0].server_cursor).toBe(firstPush.json().accepted[0].server_cursor);

    const page1 = await app.inject({ method: 'GET', url: `/api/v1/sync/pull?business_id=${first.business_id}&device_id=${first.device_id}&after=0&limit=1`, headers: headers(first) });
    const cursor1 = page1.json().next_cursor as number;
    const page2 = await app.inject({ method: 'GET', url: `/api/v1/sync/pull?business_id=${first.business_id}&device_id=${first.device_id}&after=${cursor1}&limit=1`, headers: headers(first) });
    expect(page2.json().next_cursor).toBeGreaterThan(cursor1);
    const isolated = await app.inject({ method: 'GET', url: `/api/v1/sync/pull?business_id=${other.business_id}&device_id=${other.device_id}&after=0`, headers: headers(other) });
    expect(isolated.json().operations).toEqual([]);
    const forged = await app.inject({ method: 'GET', url: `/api/v1/sync/pull?business_id=${other.business_id}&device_id=${first.device_id}&after=0`, headers: headers(first) });
    expect(forged.statusCode).toBe(403);
  });

  it('materializes stage 2 domains as immutable finance, revisions and movements', async () => {
    const app = setup();
    const identity = await createBusiness(app);
    const productId = randomUUID();
    const supplierId = randomUUID();
    const quoteId = randomUUID();
    const workId = randomUUID();
    const base = {
      business_id: identity.business_id,
      device_id: identity.device_id,
      schema_version: 1 as const,
      occurred_at: '2026-09-27T03:00:00.000Z',
    };
    const movement = (delta: number) => ({
      id: randomUUID(),
      product_id: productId,
      delta,
      cost_micros: '150000000',
    });
    const operations = [
      { ...base, operation_id: randomUUID(), type: 'supplier.saved', content: { id: supplierId, name: 'Proveedor', revision: 1, updated_at: base.occurred_at } },
      { ...base, operation_id: randomUUID(), type: 'purchase.created', content: { purchaseId: randomUUID(), total: 150 } },
      { ...base, operation_id: randomUUID(), type: 'purchase.received', content: { purchaseId: randomUUID(), stockMovements: [movement(3)] } },
      { ...base, operation_id: randomUUID(), type: 'sale.return', content: { returnId: randomUUID(), amount: 50, stockMovements: [movement(1)] } },
      { ...base, operation_id: randomUUID(), type: 'cash.opened', content: { id: randomUUID(), openingAmount: 1000 } },
      { ...base, operation_id: randomUUID(), type: 'expense', content: { id: randomUUID(), amount: -25 } },
      { ...base, operation_id: randomUUID(), type: 'quote.created', content: { quoteId, revision: 1, quote: { id: quoteId, revision: 1, status: 'draft' } } },
      { ...base, operation_id: randomUUID(), type: 'work.created', content: { workId, revision: 1, work: { id: workId, revision: 1, status: 'received' } } },
      { ...base, operation_id: randomUUID(), type: 'work.advance', content: { advance: { id: randomUUID(), work_id: workId, amount: 50 } } },
    ];
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/sync/push',
      headers: headers(identity),
      payload: { operations },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().accepted).toHaveLength(operations.length);

    const entities = await pool!.query<{ entity_type: string }>(
      'SELECT entity_type FROM sync_entities WHERE business_id=$1 ORDER BY entity_type',
      [identity.business_id],
    );
    expect(entities.rows.map((row) => row.entity_type)).toEqual(['quote', 'supplier', 'work']);
    const finance = await pool!.query<{ count: string }>(
      'SELECT count(*)::text AS count FROM sync_financial_events WHERE business_id=$1',
      [identity.business_id],
    );
    expect(Number(finance.rows[0]!.count)).toBeGreaterThanOrEqual(6);
    const inventory = await pool!.query<{ total: string }>(
      'SELECT sum(delta)::text AS total FROM sync_inventory_movements WHERE business_id=$1 AND product_id=$2',
      [identity.business_id, productId],
    );
    expect(inventory.rows[0]!.total).toBe('4');
  });

  it('limits repeated login attempts', async () => {
    const app = setup();
    const identity = await createBusiness(app);
    for (let attempt = 0; attempt < 5; attempt++) {
      const response = await app.inject({
        method: 'POST', url: '/api/v1/identity/login',
        payload: { business_id: identity.business_id, email: 'owner@example.test', password: 'wrong-password', device_id: identity.device_id },
      });
      expect(response.statusCode).toBe(401);
    }
    const limited = await app.inject({
      method: 'POST', url: '/api/v1/identity/login',
      payload: { business_id: identity.business_id, email: 'owner@example.test', password: 'wrong-password', device_id: identity.device_id },
    });
    expect(limited.statusCode).toBe(429);

    for (let attempt = 0; attempt < 10; attempt++) {
      const response = await app.inject({
        method: 'POST', url: '/api/v1/identity/refresh',
        payload: { refresh_token: `invalid-refresh-token-${'x'.repeat(32)}-${attempt}`, device_id: identity.device_id },
      });
      expect(response.statusCode).toBe(401);
    }
    const refreshLimited = await app.inject({
      method: 'POST', url: '/api/v1/identity/refresh',
      payload: { refresh_token: `invalid-refresh-token-${'x'.repeat(40)}`, device_id: identity.device_id },
    });
    expect(refreshLimited.statusCode).toBe(429);

    for (let attempt = 0; attempt < 8; attempt++) {
      const response = await app.inject({
        method: 'POST', url: '/api/v1/identity/link',
        payload: { code: `BADCODE${attempt}`, device_id: randomUUID(), device_name: 'Intruso', platform: 'test', local_business_id: randomUUID(), local_state: 'new' },
      });
      expect(response.statusCode).toBe(409);
    }
    const linkLimited = await app.inject({
      method: 'POST', url: '/api/v1/identity/link',
      payload: { code: 'BADCODEX', device_id: randomUUID(), device_name: 'Intruso', platform: 'test', local_business_id: randomUUID(), local_state: 'new' },
    });
    expect(linkLimited.statusCode).toBe(429);
  });
});
