import { Client } from 'pg';

import { loadConfig } from './config.js';

const client = new Client({ connectionString: loadConfig().DATABASE_URL });
await client.connect();
try {
  const result = await client.query<{
    access: string | null;
    baseline_permission: boolean;
    catalog_permission: boolean;
    profile: string | null;
    identity: string | null;
    foundation: string | null;
    version: number | null;
  }>(
    `SELECT to_regclass('public.businesses')::text AS identity,
            to_regclass('public.access_roles')::text AS access,
            to_regclass('public.business_assets')::text AS profile,
            to_regclass('public.sync_operations')::text AS foundation,
            EXISTS (
              SELECT 1 FROM access_permissions WHERE key='productos.ver'
            ) AS baseline_permission,
            EXISTS (
              SELECT 1 FROM access_permissions WHERE key='clientes.ver'
            ) AS catalog_permission,
            (SELECT max(version) FROM schema_migrations) AS version`,
  );
  const row = result.rows[0];
  if (
    row?.access !== 'access_roles' ||
    row?.baseline_permission !== true ||
    row?.catalog_permission !== false ||
    row?.profile !== 'business_assets' ||
    row?.identity !== 'businesses' ||
    row?.foundation !== 'sync_operations' ||
    row?.version !== 4
  ) {
    throw new Error('El rollback de la última migración no dejó el esquema esperado.');
  }
} finally {
  await client.end();
}
