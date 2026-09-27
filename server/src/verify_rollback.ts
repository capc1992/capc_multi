import { Client } from 'pg';

import { loadConfig } from './config.js';

const client = new Client({ connectionString: loadConfig().DATABASE_URL });
await client.connect();
try {
  const result = await client.query<{ identity: string | null; foundation: string | null }>(
    `SELECT to_regclass('public.businesses')::text AS identity,
            to_regclass('public.sync_operations')::text AS foundation`,
  );
  if (result.rows[0]?.identity !== null || result.rows[0]?.foundation !== 'sync_operations') {
    throw new Error('El rollback de identidad no dejó el esquema esperado.');
  }
} finally {
  await client.end();
}
