import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';

import { Client } from 'pg';

import { loadConfig } from './config.js';

const config = loadConfig();
const command = process.argv[2] ?? 'up';
if (command !== 'up' && command !== 'down') throw new Error('Uso: migrate up|down');

const migrationsDirectory = join(process.cwd(), 'migrations');
const client = new Client({ connectionString: config.DATABASE_URL });
await client.connect();

try {
  await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )`);
  const names = (await readdir(migrationsDirectory))
    .filter((name) => /^\d{3}_.+\.sql$/.test(name) && !name.endsWith('.down.sql'))
    .sort();
  if (command === 'up') {
    for (const name of names) {
      const version = Number(name.slice(0, 3));
      const exists = await client.query('SELECT 1 FROM schema_migrations WHERE version=$1', [version]);
      if (exists.rowCount) continue;
      await client.query(await readFile(join(migrationsDirectory, name), 'utf8'));
      await client.query('INSERT INTO schema_migrations (version,name) VALUES ($1,$2)', [version, name]);
    }
  } else {
    const latest = await client.query<{ version: number; name: string }>(
      'SELECT version,name FROM schema_migrations ORDER BY version DESC LIMIT 1',
    );
    const row = latest.rows[0];
    if (row) {
      const downName = row.name.replace(/\.sql$/, '.down.sql');
      await client.query(await readFile(join(migrationsDirectory, downName), 'utf8'));
      await client.query('DELETE FROM schema_migrations WHERE version=$1', [row.version]);
    }
  }
} finally {
  await client.end();
}
