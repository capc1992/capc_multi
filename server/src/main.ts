import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { PostgresSyncStore } from './postgres_store.js';
import { PostgresIdentityStore } from './postgres_identity_store.js';

const config = loadConfig();
const store = new PostgresSyncStore(config.DATABASE_URL);
const identityStore = new PostgresIdentityStore(
  config.DATABASE_URL,
  config.AUTH_TOKEN_PEPPER,
  config.ACCESS_TOKEN_TTL_MINUTES,
  config.REFRESH_TOKEN_TTL_DAYS,
);
const app = buildApp({
  store,
  identityStore,
  logger: {
    level: config.LOG_LEVEL,
    redact: [
      'req.headers.authorization',
      'req.headers.cookie',
      'req.headers.x-business-id',
      'res.headers.set-cookie',
    ],
  },
});

await app.listen({ host: config.HOST, port: config.PORT });

let closing = false;
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    if (closing) return;
    closing = true;
    app.log.info({ signal }, 'shutdown_started');
    void app.close().then(
      () => process.exit(0),
      (error: unknown) => {
        app.log.error({ error_type: error instanceof Error ? error.name : 'UnknownError' }, 'shutdown_failed');
        process.exit(1);
      },
    );
  });
}
