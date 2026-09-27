import { timingSafeEqual } from 'node:crypto';

import Fastify, { type FastifyInstance } from 'fastify';
import { ZodError } from 'zod';

import { PullQuerySchema, PushSchema } from './protocol.js';
import { IdempotencyConflictError, type SyncStore } from './store.js';

interface BuildAppOptions {
  store: SyncStore;
  sharedSecret: string;
  logger?: boolean | { level: string; redact: string[] };
}

export function buildApp(options: BuildAppOptions): FastifyInstance {
  const app = Fastify({
    logger:
      options.logger ??
      {
        level: 'info',
        redact: [
          'req.headers.authorization',
          'req.headers.cookie',
          'res.headers.set-cookie',
        ],
    },
    bodyLimit: 1024 * 1024,
  });

  app.get('/health', async () => ({ status: 'ok', service: 'capc-sync', version: 1 }));

  app.addHook('preHandler', async (request, reply) => {
    if (!request.url.startsWith('/api/')) return;
    const authorization = request.headers.authorization;
    const supplied = authorization?.startsWith('Bearer ') ? authorization.slice(7) : '';
    if (!safeEqual(supplied, options.sharedSecret)) {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });

  app.post('/api/v1/sync/push', async (request, reply) => {
    const payload = PushSchema.parse(request.body);
    const scope = request.headers['x-business-id'];
    if (typeof scope !== 'string' || payload.operations.some((item) => item.business_id !== scope)) {
      return reply.code(403).send({ error: 'business_scope_mismatch' });
    }
    const accepted = [];
    for (const operation of payload.operations) {
      accepted.push(await options.store.push(operation));
    }
    return { accepted };
  });

  app.get('/api/v1/sync/pull', async (request, reply) => {
    const query = PullQuerySchema.parse(request.query);
    const scope = request.headers['x-business-id'];
    if (typeof scope !== 'string' || query.business_id !== scope) {
      return reply.code(403).send({ error: 'business_scope_mismatch' });
    }
    return options.store.pull(query.business_id, query.after, query.limit);
  });

  app.setErrorHandler(async (error, _request, reply) => {
    if (error instanceof ZodError) {
      return reply.code(400).send({ error: 'invalid_request', issues: error.issues });
    }
    if (error instanceof IdempotencyConflictError) {
      return reply.code(409).send({ error: 'operation_id_conflict' });
    }
    const safeError = error instanceof Error
      ? { name: error.name, message: error.message }
      : { name: 'UnknownError', message: 'Unknown server failure' };
    app.log.error({ err: safeError }, 'request_failed');
    return reply.code(500).send({ error: 'internal_error' });
  });

  app.addHook('onClose', async () => options.store.close());
  return app;
}

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}
