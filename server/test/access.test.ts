import { afterEach, describe, expect, it } from 'vitest';

import { buildApp } from '../src/app.js';
import { MemoryIdentityStore } from '../src/memory_identity_store.js';
import { MemorySyncStore } from '../src/memory_store.js';

const businessId = '11111111-1111-4111-8111-111111111111';
const deviceId = '33333333-3333-4333-8333-333333333333';

describe('central access control', () => {
  const apps: ReturnType<typeof buildApp>[] = [];
  afterEach(async () => Promise.all(apps.splice(0).map((app) => app.close())));

  async function setup() {
    const identityStore = new MemoryIdentityStore();
    const identity = await identityStore.createBusiness({
      businessId,
      businessName: 'Negocio A',
      email: 'owner@example.test',
      password: 'remote-password-2026',
      deviceId,
      deviceName: 'Principal',
      platform: 'test',
    }, 'test');
    const app = buildApp({ store: new MemorySyncStore(), identityStore, logger: false });
    apps.push(app);
    return {
      app,
      identityStore,
      headers: {
        authorization: `Bearer ${identity.accessToken}`,
        'x-business-id': businessId,
      },
    };
  }

  it('seeds the main administrator and exposes the stable permission catalog', async () => {
    const { app, headers } = await setup();
    const permissions = await app.inject({ method: 'GET', url: '/api/v1/access/permissions', headers });
    expect(permissions.statusCode).toBe(200);
    expect(permissions.json().permissions).toEqual(expect.arrayContaining([
      expect.objectContaining({ key: 'productos.ver', module: 'productos' }),
      expect.objectContaining({ key: 'usuarios.editar', module: 'usuarios' }),
      expect.objectContaining({ key: 'access:manage', module: 'sistema' }),
    ]));

    const roles = await app.inject({ method: 'GET', url: '/api/v1/access/roles', headers });
    expect(roles.json().roles).toHaveLength(1);
    expect(roles.json().roles[0]).toMatchObject({
      name: 'Administrador principal', roleType: 'administrator', system: true, version: 1,
    });
    const users = await app.inject({ method: 'GET', url: '/api/v1/access/users', headers });
    expect(users.json().users).toEqual([
      expect.objectContaining({ active: true, activated: true, email: 'owner@example.test' }),
    ]);
  });

  it('creates a custom role and a pending user without returning stored secrets later', async () => {
    const { app, headers } = await setup();
    const roleResponse = await app.inject({
      method: 'POST', url: '/api/v1/access/roles', headers,
      payload: { name: 'Auxiliar de caja', role_type: 'operational', permissions: ['ventas.ver', 'ventas.crear'] },
    });
    expect(roleResponse.statusCode).toBe(201);
    const role = roleResponse.json().role;
    expect(role).toMatchObject({ name: 'Auxiliar de caja', roleType: 'operational', system: false, version: 1 });

    const created = await app.inject({
      method: 'POST', url: '/api/v1/access/users', headers,
      payload: {
        name: 'Carlos Pérez', username: 'carlos', email: 'carlos@example.test',
        role_ids: [role.id],
      },
    });
    expect(created.statusCode).toBe(201);
    expect(created.json().activation_code).toMatch(/^[A-Za-z0-9_-]{40,}$/);
    expect(Date.parse(created.json().activation_expires_at)).toBeGreaterThan(Date.now());
    expect(created.json().user).toMatchObject({
      username: 'carlos', active: true, activated: false,
      roles: [{ id: role.id, name: 'Auxiliar de caja' }],
    });

    const listed = await app.inject({ method: 'GET', url: '/api/v1/access/users', headers });
    expect(listed.body).not.toContain('activation_code');
    expect(listed.body).not.toContain(created.json().activation_code);
  });

  it('uses optimistic role versions and protects the system owner', async () => {
    const { app, headers } = await setup();
    const roles = (await app.inject({ method: 'GET', url: '/api/v1/access/roles', headers })).json().roles;
    const ownerRole = roles[0];
    const immutable = await app.inject({
      method: 'PATCH', url: `/api/v1/access/roles/${ownerRole.id}`, headers,
      payload: { name: 'Otro', role_type: 'administrator', permissions: ['access:manage'], expected_version: 1 },
    });
    expect(immutable.statusCode).toBe(409);
    expect(immutable.json()).toEqual({ error: 'system_role_immutable' });

    const created = await app.inject({
      method: 'POST', url: '/api/v1/access/roles', headers,
      payload: { name: 'Bodega', role_type: 'operational', permissions: ['inventario.ver'] },
    });
    const role = created.json().role;
    const updated = await app.inject({
      method: 'PATCH', url: `/api/v1/access/roles/${role.id}`, headers,
      payload: {
        name: 'Bodega y ajustes', role_type: 'administrator', permissions: ['inventario.ver', 'inventario.ajustar'],
        expected_version: 1,
      },
    });
    expect(updated.json().role).toMatchObject({ name: 'Bodega y ajustes', roleType: 'administrator', version: 2 });
    const stale = await app.inject({
      method: 'PATCH', url: `/api/v1/access/roles/${role.id}`, headers,
      payload: { name: 'Desactualizado', role_type: 'operational', permissions: ['inventario.ver'], expected_version: 1 },
    });
    expect(stale.statusCode).toBe(409);
    expect(stale.json()).toEqual({ error: 'role_version_conflict' });
  });

  it('isolates role assignments by business', async () => {
    const { app, identityStore, headers } = await setup();
    const otherDevice = '66666666-6666-4666-8666-666666666666';
    const otherIdentity = await identityStore.createBusiness({
      businessId: '22222222-2222-4222-8222-222222222222',
      businessName: 'Negocio B', email: 'other@example.test', password: 'other-password-2026',
      deviceId: otherDevice, deviceName: 'Otro', platform: 'test',
    }, 'other');
    const otherHeaders = {
      authorization: `Bearer ${otherIdentity.accessToken}`,
      'x-business-id': otherIdentity.businessId,
    };
    const otherRoles = (await app.inject({
      method: 'GET', url: '/api/v1/access/roles', headers: otherHeaders,
    })).json().roles;
    const response = await app.inject({
      method: 'POST', url: '/api/v1/access/users', headers,
      payload: { name: 'Intruso', username: 'intruso', role_ids: [otherRoles[0].id] },
    });
    expect(response.statusCode).toBe(404);
    expect(response.json()).toEqual({ error: 'role_not_found' });
  });

  it('activates a custom administrator and revokes its session after access changes', async () => {
    const { app, headers } = await setup();
    const roleResponse = await app.inject({
      method: 'POST', url: '/api/v1/access/roles', headers,
      payload: {
        name: 'Supervisor administrativo', role_type: 'administrator',
        permissions: [
          'roles.ver', 'roles.crear', 'roles.editar',
          'usuarios.ver', 'usuarios.crear', 'auditoria.ver', 'devices:manage',
        ],
      },
    });
    const role = roleResponse.json().role;
    expect(role.roleType).toBe('administrator');
    const createdResponse = await app.inject({
      method: 'POST', url: '/api/v1/access/users', headers,
      payload: { name: 'Luisa', username: 'luisa', role_ids: [role.id] },
    });
    const created = createdResponse.json();
    const activated = await app.inject({
      method: 'POST', url: '/api/v1/access/activate',
      payload: {
        business_id: businessId, username: 'luisa',
        activation_code: created.activation_code, password: 'central-password-2026',
      },
    });
    expect(activated.statusCode).toBe(204);
    const login = await app.inject({
      method: 'POST', url: '/api/v1/access/login',
      payload: {
        business_id: businessId, username: 'luisa',
        password: 'central-password-2026', device_id: deviceId,
      },
    });
    expect(login.statusCode).toBe(200);
    expect(login.json().permissions).toEqual(expect.arrayContaining([
      'sync:read', 'sync:write', 'roles.ver', 'roles.crear', 'roles.editar',
    ]));
    expect(login.json()).toMatchObject({
      principal_name: 'Luisa', username: 'luisa', role_type: 'administrator',
    });
    expect(login.json().permissions).not.toContain('devices:manage');
    expect(login.json().offline_grant).toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    expect(login.json().offline_grant_public_key).toMatch(/^[A-Za-z0-9_-]+$/);
    const grantLifetime = Date.parse(login.json().offline_grant_expires_at) - Date.now();
    expect(grantLifetime).toBeGreaterThan(71 * 60 * 60_000);
    expect(grantLifetime).toBeLessThanOrEqual(72 * 60 * 60_000);
    const userHeaders = {
      authorization: `Bearer ${login.json().access_token}`,
      'x-business-id': businessId,
    };
    expect((await app.inject({
      method: 'GET', url: '/api/v1/access/roles', headers: userHeaders,
    })).statusCode).toBe(200);
    expect((await app.inject({
      method: 'POST', url: '/api/v1/access/roles', headers: userHeaders,
      payload: {
        name: 'Consulta', role_type: 'operational', permissions: ['productos.ver'],
      },
    })).statusCode).toBe(201);
    const audit = await app.inject({
      method: 'GET', url: '/api/v1/access/audit?limit=20', headers: userHeaders,
    });
    expect(audit.statusCode).toBe(200);
    expect(audit.json().audit).toEqual(expect.arrayContaining([
      expect.objectContaining({ event: 'access.session_login', actorName: 'Luisa' }),
      expect.objectContaining({ event: 'access.role_created', actorName: 'Luisa' }),
    ]));
    const forbiddenLink = await app.inject({
      method: 'POST', url: '/api/v1/identity/link-codes', headers: userHeaders,
    });
    expect(forbiddenLink.statusCode).toBe(403);

    const updatedRole = await app.inject({
      method: 'PATCH', url: `/api/v1/access/roles/${role.id}`, headers,
      payload: {
        name: role.name, role_type: 'administrator',
        permissions: ['access:read'], expected_version: role.version,
      },
    });
    expect(updatedRole.statusCode).toBe(200);
    expect((await app.inject({
      method: 'GET', url: '/api/v1/access/roles', headers: userHeaders,
    })).statusCode).toBe(401);
  });
});
