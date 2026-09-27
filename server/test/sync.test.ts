import { afterEach, describe, expect, it } from 'vitest';

import { buildApp } from '../src/app.js';
import { MemorySyncStore } from '../src/memory_store.js';
import type { SyncOperation } from '../src/protocol.js';

const secret = 'test-secret-with-more-than-thirty-two-characters';
const businessA = '11111111-1111-4111-8111-111111111111';
const businessB = '22222222-2222-4222-8222-222222222222';
const device = '33333333-3333-4333-8333-333333333333';

function operation(overrides: Partial<SyncOperation> = {}): SyncOperation {
  return {
    business_id: businessA,
    device_id: device,
    operation_id: '44444444-4444-4444-8444-444444444444',
    type: 'customer.saved',
    schema_version: 1,
    occurred_at: '2026-09-27T03:00:00.000Z',
    content: {
      id: '55555555-5555-4555-8555-555555555555',
      name: 'Ana',
      revision: 1,
    },
    ...overrides,
  };
}

describe('sync API', () => {
  const apps: ReturnType<typeof buildApp>[] = [];
  afterEach(async () => Promise.all(apps.splice(0).map((app) => app.close())));

  function setup() {
    const store = new MemorySyncStore();
    const app = buildApp({ store, sharedSecret: secret, logger: false });
    apps.push(app);
    const headers = {
      authorization: `Bearer ${secret}`,
      'x-business-id': businessA,
    };
    return { app, store, headers };
  }

  it('reports health without exposing configuration', async () => {
    const { app } = setup();
    const response = await app.inject({ method: 'GET', url: '/health' });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: 'ok', service: 'capc-sync', version: 1 });
    expect(response.body).not.toContain(secret);
  });

  it('processes the same operation once after a lost response', async () => {
    const { app, headers } = setup();
    const body = { operations: [operation()] };
    const first = await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers, payload: body });
    const retry = await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers, payload: body });
    expect(first.statusCode).toBe(200);
    expect(first.json().accepted[0].duplicate).toBe(false);
    expect(retry.json().accepted[0]).toMatchObject({
      duplicate: true,
      server_cursor: first.json().accepted[0].server_cursor,
    });
    const pull = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${businessA}&device_id=${device}&after=0`,
      headers,
    });
    expect(pull.json().operations).toHaveLength(1);
  });

  it('rejects operation_id reuse with different content', async () => {
    const { app, headers } = setup();
    await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers, payload: { operations: [operation()] } });
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/sync/push',
      headers,
      payload: { operations: [operation({ content: { id: '55555555-5555-4555-8555-555555555555', name: 'Otra' } })] },
    });
    expect(response.statusCode).toBe(409);
  });

  it('isolates pull and push by business scope', async () => {
    const { app, headers } = setup();
    await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers, payload: { operations: [operation()] } });
    const forbidden = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${businessB}&device_id=${device}&after=0`,
      headers,
    });
    expect(forbidden.statusCode).toBe(403);
    const otherHeaders = { ...headers, 'x-business-id': businessB };
    const other = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${businessB}&device_id=${device}&after=0`,
      headers: otherHeaders,
    });
    expect(other.json().operations).toEqual([]);
  });

  it('returns monotonic pages in accepted order', async () => {
    const { app, headers } = setup();
    const operations = [
      operation({ operation_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', type: 'sale.created' }),
      operation({ operation_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', type: 'product.saved' }),
    ];
    await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers, payload: { operations } });
    const first = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${businessA}&device_id=${device}&after=0&limit=1`,
      headers,
    });
    expect(first.json().operations[0].type).toBe('sale.created');
    expect(first.json().has_more).toBe(true);
    const second = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/pull?business_id=${businessA}&device_id=${device}&after=${first.json().next_cursor}&limit=1`,
      headers,
    });
    expect(second.json().operations[0].type).toBe('product.saved');
    expect(second.json().operations[0].server_cursor).toBeGreaterThan(first.json().next_cursor);
  });

  it('rejects secret fields and records negative inventory conflicts', async () => {
    const { app, store, headers } = setup();
    const rejected = await app.inject({
      method: 'POST',
      url: '/api/v1/sync/push',
      headers,
      payload: { operations: [operation({ content: { password_hash: 'never' } })] },
    });
    expect(rejected.statusCode).toBe(400);
    const movement = (id: string, delta: number): SyncOperation =>
      operation({
        operation_id: id,
        type: 'stock.adjusted',
        content: {
          movement: {
            id,
            product_id: '55555555-5555-4555-8555-555555555555',
            delta,
            cost_micros: 0,
          },
        },
      });
    await app.inject({
      method: 'POST', url: '/api/v1/sync/push', headers,
      payload: { operations: [movement('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 1)] },
    });
    await app.inject({
      method: 'POST', url: '/api/v1/sync/push', headers,
      payload: { operations: [movement('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', -1)] },
    });
    const conflict = await app.inject({
      method: 'POST', url: '/api/v1/sync/push', headers,
      payload: { operations: [movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc', -1)] },
    });
    expect(conflict.json().accepted[0].conflicts).toBe(1);
    expect(store.conflicts).toHaveLength(1);
  });
});
