import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import { z, ZodError } from 'zod';

import { IdentityError, requirePermission, type AuthIdentity, type IdentityStore, type IssuedIdentity } from './identity.js';
import { accountDeletionPage, privacyPage } from './public_pages.js';
import { PullQuerySchema, PushSchema } from './protocol.js';
import { BusinessUnavailableError, IdempotencyConflictError, type SyncStore } from './store.js';

interface BuildAppOptions {
  store: SyncStore;
  identityStore: IdentityStore;
  logger?: boolean | { level: string; redact: string[] };
}

const DeviceSchema = z.object({
  device_id: z.string().uuid(),
  device_name: z.string().trim().min(1).max(160),
  platform: z.string().trim().min(1).max(40),
});
const CreateBusinessSchema = DeviceSchema.extend({
  business_id: z.string().uuid(),
  business_name: z.string().trim().min(1).max(160),
  email: z.email().max(320),
  password: z.string().min(12).max(200),
}).strict();
const LoginSchema = z.object({
  business_id: z.string().uuid(),
  email: z.email().max(320),
  password: z.string().min(1).max(200),
  device_id: z.string().uuid(),
}).strict();
const RefreshSchema = z.object({ refresh_token: z.string().min(32).max(512), device_id: z.string().uuid() }).strict();
const DeleteAccountSchema = z.object({
  business_id: z.string().uuid().optional(),
  email: z.email().max(320),
  password: z.string().min(1).max(200),
  confirmation: z.literal('ELIMINAR'),
}).strict();
const LinkSchema = DeviceSchema.extend({
  code: z.string().trim().min(6).max(32).transform((value) => value.toUpperCase()),
  local_business_id: z.string().uuid(),
  local_state: z.enum(['new', 'no_movements']),
}).strict();
const DeviceParamsSchema = z.object({ deviceId: z.string().uuid() });
const publicIdentityRoutes = new Set([
  '/api/v1/identity/businesses',
  '/api/v1/identity/login',
  '/api/v1/identity/refresh',
  '/api/v1/identity/link',
  '/api/v1/identity/delete-account',
]);

export function buildApp(options: BuildAppOptions): FastifyInstance {
  const identities = new WeakMap<FastifyRequest, AuthIdentity>();
  const app = Fastify({
    logger: options.logger ?? {
      level: 'info',
      redact: [
        'req.headers.authorization',
        'req.headers.cookie',
        'req.headers.x-business-id',
        'res.headers.set-cookie',
      ],
    },
    bodyLimit: 1024 * 1024,
  });

  app.get('/health', async () => ({ status: 'ok', service: 'capc-sync', version: 2 }));

  app.get('/privacidad', async (_request, reply) => publicPage(reply, privacyPage));
  app.get('/eliminar-cuenta', async (_request, reply) => publicPage(reply, accountDeletionPage));

  app.addHook('preHandler', async (request, reply) => {
    const path = request.url.split('?')[0]!;
    if (!path.startsWith('/api/') || publicIdentityRoutes.has(path)) return;
    const authorization = request.headers.authorization;
    const token = authorization?.startsWith('Bearer ') ? authorization.slice(7) : '';
    const identity = token ? await options.identityStore.authenticate(token) : null;
    if (!identity) return reply.code(401).send({ error: 'unauthorized' });
    identities.set(request, identity);
  });

  app.post('/api/v1/identity/businesses', async (request, reply) => {
    const body = CreateBusinessSchema.parse(request.body);
    const issued = await options.identityStore.createBusiness({
      businessId: body.business_id,
      businessName: body.business_name,
      email: body.email,
      password: body.password,
      deviceId: body.device_id,
      deviceName: body.device_name,
      platform: body.platform,
    }, requestKey(request));
    return reply.code(201).send(tokenResponse(issued));
  });

  app.post('/api/v1/identity/login', async (request) => {
    const body = LoginSchema.parse(request.body);
    return tokenResponse(await options.identityStore.login({
      businessId: body.business_id,
      email: body.email,
      password: body.password,
      deviceId: body.device_id,
    }, requestKey(request)));
  });

  app.post('/api/v1/identity/refresh', async (request) => {
    const body = RefreshSchema.parse(request.body);
    return tokenResponse(await options.identityStore.refresh(body.refresh_token, body.device_id, requestKey(request)));
  });

  app.post('/api/v1/identity/link', async (request) => {
    const body = LinkSchema.parse(request.body);
    return tokenResponse(await options.identityStore.linkDevice({
      code: body.code,
      deviceId: body.device_id,
      deviceName: body.device_name,
      platform: body.platform,
      localBusinessId: body.local_business_id,
      localState: body.local_state,
    }, requestKey(request)));
  });

  app.post('/api/v1/identity/delete-account', async (request, reply) => {
    const body = DeleteAccountSchema.parse(request.body);
    const deletedBusinessId = await options.identityStore.deleteBusiness({
      ...(body.business_id === undefined ? {} : { businessId: body.business_id }),
      email: body.email,
      password: body.password,
    }, requestKey(request));
    await options.store.deleteBusiness(deletedBusinessId);
    return reply.code(204).send();
  });

  app.post('/api/v1/identity/link-codes', async (request, reply) => {
    const identity = authenticated(identities, request);
    requirePermission(identity, 'devices:manage');
    enforceScope(request, identity);
    return reply.code(201).send(await options.identityStore.createLinkCode(identity));
  });

  app.get('/api/v1/identity/devices', async (request) => {
    const identity = authenticated(identities, request);
    requirePermission(identity, 'devices:read');
    enforceScope(request, identity);
    return { devices: await options.identityStore.listDevices(identity) };
  });

  app.delete('/api/v1/identity/devices/:deviceId', async (request, reply) => {
    const identity = authenticated(identities, request);
    requirePermission(identity, 'devices:manage');
    enforceScope(request, identity);
    const { deviceId } = DeviceParamsSchema.parse(request.params);
    await options.identityStore.revokeDevice(identity, deviceId);
    return reply.code(204).send();
  });

  app.post('/api/v1/identity/logout', async (request, reply) => {
    const identity = authenticated(identities, request);
    enforceScope(request, identity);
    await options.identityStore.logout(identity);
    return reply.code(204).send();
  });

  app.post('/api/v1/sync/push', async (request, reply) => {
    const identity = authenticated(identities, request);
    requirePermission(identity, 'sync:write');
    enforceScope(request, identity);
    const payload = PushSchema.parse(request.body);
    if (payload.operations.some((item) => item.business_id !== identity.businessId || item.device_id !== identity.deviceId)) {
      return reply.code(403).send({ error: 'identity_scope_mismatch' });
    }
    const accepted = [];
    for (const operation of payload.operations) accepted.push(await options.store.push(operation));
    return { accepted };
  });

  app.get('/api/v1/sync/pull', async (request, reply) => {
    const identity = authenticated(identities, request);
    requirePermission(identity, 'sync:read');
    enforceScope(request, identity);
    const query = PullQuerySchema.parse(request.query);
    if (query.business_id !== identity.businessId || query.device_id !== identity.deviceId) {
      return reply.code(403).send({ error: 'identity_scope_mismatch' });
    }
    return options.store.pull(identity.businessId, query.after, query.limit);
  });

  app.setErrorHandler(async (error, _request, reply) => {
    if (error instanceof ZodError) return reply.code(400).send({ error: 'invalid_request', issues: error.issues });
    if (error instanceof IdentityError) return reply.code(error.statusCode).send({ error: error.code });
    if (error instanceof IdempotencyConflictError) return reply.code(409).send({ error: 'operation_id_conflict' });
    if (error instanceof BusinessUnavailableError) return reply.code(410).send({ error: 'business_unavailable' });
    app.log.error({ error_type: error instanceof Error ? error.name : 'UnknownError' }, 'request_failed');
    return reply.code(500).send({ error: 'internal_error' });
  });

  app.addHook('onClose', async () => Promise.all([options.store.close(), options.identityStore.close()]));
  return app;
}

function authenticated(identities: WeakMap<FastifyRequest, AuthIdentity>, request: FastifyRequest): AuthIdentity {
  const identity = identities.get(request);
  if (!identity) throw new IdentityError('unauthorized', 401);
  return identity;
}

function enforceScope(request: FastifyRequest, identity: AuthIdentity): void {
  if (request.headers['x-business-id'] !== identity.businessId) throw new IdentityError('business_scope_mismatch', 403);
}

function requestKey(request: FastifyRequest): string {
  return request.ip || 'unknown';
}

function tokenResponse(value: IssuedIdentity): Record<string, unknown> {
  return {
    business_id: value.businessId,
    device_id: value.deviceId,
    permissions: value.permissions,
    access_token: value.accessToken,
    refresh_token: value.refreshToken,
    access_expires_at: value.accessExpiresAt,
    refresh_expires_at: value.refreshExpiresAt,
  };
}

function publicPage(reply: import('fastify').FastifyReply, html: string) {
  return reply
    .header('Cache-Control', 'public, max-age=300')
    .header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
    .header('Referrer-Policy', 'no-referrer')
    .header('X-Content-Type-Options', 'nosniff')
    .type('text/html; charset=utf-8')
    .send(html);
}
