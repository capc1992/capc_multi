import { afterEach, describe, expect, it, vi } from 'vitest';

import { buildApp } from '../src/app.js';
import { MemoryIdentityStore } from '../src/memory_identity_store.js';
import { MemorySyncStore } from '../src/memory_store.js';

const business = {
  business_id: '11111111-1111-4111-8111-111111111111',
  business_name: 'Prueba de identidad',
  email: 'owner@example.test',
  password: 'remote-password-2026',
  device_id: '33333333-3333-4333-8333-333333333333',
  device_name: 'Equipo de prueba',
  platform: 'test',
};

describe('identity request errors', () => {
  const apps: ReturnType<typeof buildApp>[] = [];
  afterEach(async () => {
    await Promise.all(apps.splice(0).map((app) => app.close()));
    vi.restoreAllMocks();
  });

  function setup(logs?: string[]) {
    const identityStore = new MemoryIdentityStore();
    const create = vi.spyOn(identityStore, 'createBusiness');
    const app = buildApp({
      store: new MemorySyncStore(), identityStore,
      logger: logs ? { level: 'warn', stream: { write: (line: string) => { logs.push(line); } } } : false,
    });
    apps.push(app);
    return { app, create };
  }

  it.each([
    ['malformed JSON', 'application/json', '{"password":"private-password",', 400, 'FST_ERR_CTP_INVALID_JSON_BODY'],
    ['empty JSON', 'application/json', '', 400, 'FST_ERR_CTP_EMPTY_JSON_BODY'],
    ['unsupported content type', 'application/xml', '<password>private-password</password>', 415, 'FST_ERR_CTP_INVALID_MEDIA_TYPE'],
    ['oversized JSON', 'application/json', JSON.stringify({ password: 'x'.repeat(1024 * 1024) }), 413, 'FST_ERR_CTP_BODY_TOO_LARGE'],
  ])('rejects %s before accessing the identity store', async (_label, contentType, payload, status, code) => {
    const { app, create } = setup();
    const response = await app.inject({
      method: 'POST', url: '/api/v1/identity/businesses',
      headers: { 'content-type': contentType }, payload,
    });
    expect(response.statusCode).toBe(status);
    expect(response.json()).toEqual({ error: 'invalid_request', code });
    expect(create).not.toHaveBeenCalled();
    expect(response.body).not.toContain('private-password');
  });

  it('keeps schema validation errors at 400 without accessing the store', async () => {
    const { app, create } = setup();
    const response = await app.inject({
      method: 'POST', url: '/api/v1/identity/businesses',
      payload: { ...business, business_id: 'invalid-uuid' },
    });
    expect(response.statusCode).toBe(400);
    expect(response.json().error).toBe('invalid_request');
    expect(create).not.toHaveBeenCalled();
  });

  it.each([
    ['42P01', 'PostgreSQL relation does not exist; check applied migrations'],
    ['42501', 'PostgreSQL insufficient privileges'],
    ['22P02', 'PostgreSQL invalid input syntax for data type'],
    ['ECONNREFUSED', 'Database connection refused'],
    ['UNKNOWN', 'Internal request failure; raw message omitted'],
  ])('logs safe diagnostics for %s with request correlation', async (code, message) => {
    const logs: string[] = [];
    const { app, create } = setup(logs);
    create.mockRejectedValueOnce(Object.assign(new Error('password=private-password token=private-token'), {
      code, detail: 'private-detail', query: 'private-query', statusCode: 401,
    }));
    const response = await app.inject({
      method: 'POST', url: '/api/v1/identity/businesses', payload: business,
      headers: { authorization: 'Bearer private-token' },
    });
    expect(response.statusCode).toBe(500);
    expect(response.json()).toEqual({ error: 'internal_error' });
    const entry = logs.map((line) => JSON.parse(line)).find((line) => line.msg === 'request_failed');
    expect(entry).toMatchObject({ error_type: 'Error', error_code: code, status_code: 500, message });
    expect(entry.reqId).toEqual(expect.any(String));
    expect(logs.join('')).not.toMatch(/private-|remote-password-2026/);
  });

  it('logs parser diagnostics without including malformed authentication bodies', async () => {
    const logs: string[] = [];
    const { app, create } = setup(logs);
    const response = await app.inject({
      method: 'POST', url: '/api/v1/identity/businesses',
      headers: { 'content-type': 'application/json' },
      payload: '{"password":"private-password",',
    });
    expect(response.statusCode).toBe(400);
    expect(create).not.toHaveBeenCalled();
    expect(logs.map((line) => JSON.parse(line))).toContainEqual(expect.objectContaining({
      error_type: 'FastifyError', error_code: 'FST_ERR_CTP_INVALID_JSON_BODY',
      status_code: 400, message: 'Invalid JSON body', msg: 'request_rejected',
      reqId: expect.any(String),
    }));
    expect(logs.join('')).not.toContain('private-password');
  });

  it('creates and deletes an account using explicit JSON strings', async () => {
    const { app } = setup();
    const created = await app.inject({
      method: 'POST', url: '/api/v1/identity/businesses',
      headers: { 'content-type': 'application/json' }, payload: JSON.stringify(business),
    });
    expect(created.statusCode).toBe(201);
    const deleted = await app.inject({
      method: 'POST', url: '/api/v1/identity/delete-account',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({
        business_id: business.business_id, email: business.email,
        password: business.password, confirmation: 'ELIMINAR',
      }),
    });
    expect(deleted.statusCode).toBe(204);
    const formerSession = await app.inject({
      method: 'GET', url: '/api/v1/identity/devices',
      headers: {
        authorization: `Bearer ${created.json().access_token}`,
        'x-business-id': business.business_id,
      },
    });
    expect(formerSession.statusCode).toBe(401);
  });
});
