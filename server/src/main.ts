import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { PostgresSyncStore } from './postgres_store.js';

const config = loadConfig();
const store = new PostgresSyncStore(config.DATABASE_URL);
const app = buildApp({
  store,
  sharedSecret: config.SYNC_SHARED_SECRET,
  logger: {
    level: config.LOG_LEVEL,
    redact: [
      'req.headers.authorization',
      'req.headers.cookie',
      'res.headers.set-cookie',
    ],
  },
});

await app.listen({ host: config.HOST, port: config.PORT });
