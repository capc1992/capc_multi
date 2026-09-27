import { createHash } from 'node:crypto';

import { Pool, type PoolClient } from 'pg';

import type { PullPage, PushAcknowledgement, SyncOperation } from './protocol.js';
import { IdempotencyConflictError, type SyncStore } from './store.js';

function digest(operation: SyncOperation): string {
  return createHash('sha256').update(JSON.stringify(operation)).digest('hex');
}

export class PostgresSyncStore implements SyncStore {
  constructor(databaseUrl: string) {
    this.pool = new Pool({ connectionString: databaseUrl, max: 10 });
  }

  private readonly pool: Pool;

  async push(operation: SyncOperation): Promise<PushAcknowledgement> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const hash = digest(operation);
      const inserted = await client.query<{ server_cursor: string }>(
        `INSERT INTO sync_operations
          (business_id,device_id,operation_id,type,schema_version,occurred_at,content,content_hash)
         VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8)
         ON CONFLICT (business_id,operation_id) DO NOTHING
         RETURNING server_cursor`,
        [
          operation.business_id,
          operation.device_id,
          operation.operation_id,
          operation.type,
          operation.schema_version,
          operation.occurred_at,
          JSON.stringify(operation.content),
          hash,
        ],
      );
      if (inserted.rowCount === 0) {
        const existing = await client.query<{ server_cursor: string; content_hash: string }>(
          `SELECT server_cursor,content_hash FROM sync_operations
           WHERE business_id=$1 AND operation_id=$2 FOR UPDATE`,
          [operation.business_id, operation.operation_id],
        );
        if (existing.rows[0]?.content_hash !== hash) throw new IdempotencyConflictError();
        await client.query('COMMIT');
        return {
          operation_id: operation.operation_id,
          server_cursor: Number(existing.rows[0]!.server_cursor),
          duplicate: true,
          conflicts: 0,
        };
      }
      const conflicts = await this.apply(client, operation);
      await client.query('COMMIT');
      return {
        operation_id: operation.operation_id,
        server_cursor: Number(inserted.rows[0]!.server_cursor),
        duplicate: false,
        conflicts,
      };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async pull(businessId: string, after: number, limit: number): Promise<PullPage> {
    const result = await this.pool.query<{
      server_cursor: string;
      business_id: string;
      device_id: string;
      operation_id: string;
      type: string;
      schema_version: 1;
      occurred_at: Date;
      content: Record<string, unknown>;
    }>(
      `SELECT server_cursor,business_id,device_id,operation_id,type,schema_version,occurred_at,content
       FROM sync_operations
       WHERE business_id=$1 AND server_cursor>$2
       ORDER BY server_cursor ASC LIMIT $3`,
      [businessId, after, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit).map((row) => ({
      ...row,
      server_cursor: Number(row.server_cursor),
      occurred_at: row.occurred_at.toISOString(),
    }));
    return {
      operations: rows,
      next_cursor: rows.at(-1)?.server_cursor ?? after,
      has_more: hasMore,
    };
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  private async apply(client: PoolClient, operation: SyncOperation): Promise<number> {
    let conflicts = 0;
    const entity = entityRevision(operation);
    if (entity) {
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [
        `entity:${operation.business_id}:${entity.type}:${entity.id}`,
      ]);
      const current = await client.query<{ revision: number; payload: Record<string, unknown> }>(
        `SELECT revision,payload FROM sync_entities
         WHERE business_id=$1 AND entity_type=$2 AND entity_id=$3 FOR UPDATE`,
        [operation.business_id, entity.type, entity.id],
      );
      const local = current.rows[0];
      const terminalRegression =
        entity.type === 'quote' &&
        local !== undefined &&
        isTerminalQuoteStatus(local.payload.status) &&
        local.payload.status !== operation.content.status;
      if (terminalRegression) {
        conflicts += await this.conflict(client, operation, 'quote.terminal', entity.id, {
          local_status: local.payload.status,
          remote_status: operation.content.status,
          local_revision: local.revision,
          remote_revision: entity.revision,
        });
      } else if (local && entity.revision <= local.revision) {
        if (JSON.stringify(local.payload) !== JSON.stringify(operation.content)) {
          conflicts += await this.conflict(client, operation, 'revision.stale', entity.id, {
            local_revision: local.revision,
            remote_revision: entity.revision,
          });
        }
      } else {
        await client.query(
          `INSERT INTO sync_entities (business_id,entity_type,entity_id,revision,payload,updated_at)
           VALUES ($1,$2,$3,$4,$5::jsonb,$6)
           ON CONFLICT (business_id,entity_type,entity_id) DO UPDATE
           SET revision=EXCLUDED.revision,payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at`,
          [
            operation.business_id,
            entity.type,
            entity.id,
            entity.revision,
            JSON.stringify(operation.content),
            operation.occurred_at,
          ],
        );
      }
    }
    for (const movement of inventoryMovements(operation)) {
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [
        `inventory:${operation.business_id}:${movement.product_id}`,
      ]);
      const inserted = await client.query(
        `INSERT INTO sync_inventory_movements
          (business_id,movement_id,operation_id,product_id,delta,cost_micros,occurred_at,payload)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
         ON CONFLICT (business_id,movement_id) DO NOTHING`,
        [
          operation.business_id,
          movement.id,
          operation.operation_id,
          movement.product_id,
          movement.delta,
          movement.cost_micros,
          operation.occurred_at,
          JSON.stringify(movement),
        ],
      );
      if (inserted.rowCount === 1) {
        const balance = await client.query<{ stock: string }>(
          `SELECT COALESCE(SUM(delta),0)::text AS stock FROM sync_inventory_movements
           WHERE business_id=$1 AND product_id=$2`,
          [operation.business_id, movement.product_id],
        );
        const stock = Number(balance.rows[0]!.stock);
        if (stock < 0) {
          conflicts += await this.conflict(
            client,
            operation,
            'inventory.negative',
            movement.product_id,
            { stock, movement_id: movement.id },
          );
        }
      }
    }
    if (isFinancial(operation.type)) {
      await client.query(
        `INSERT INTO sync_financial_events
          (business_id,operation_id,type,occurred_at,payload)
         VALUES ($1,$2,$3,$4,$5::jsonb)
         ON CONFLICT (business_id,operation_id) DO NOTHING`,
        [
          operation.business_id,
          operation.operation_id,
          operation.type,
          operation.occurred_at,
          JSON.stringify(operation.content),
        ],
      );
    }
    return conflicts;
  }

  private async conflict(
    client: PoolClient,
    operation: SyncOperation,
    type: string,
    entityId: string,
    details: Record<string, unknown>,
  ): Promise<number> {
    const result = await client.query(
      `INSERT INTO sync_conflicts
        (business_id,operation_id,type,entity_id,details)
       VALUES ($1,$2,$3,$4,$5::jsonb)
       ON CONFLICT (business_id,operation_id,type,entity_id) DO NOTHING`,
      [operation.business_id, operation.operation_id, type, entityId, JSON.stringify(details)],
    );
    return result.rowCount ?? 0;
  }
}

function entityRevision(operation: SyncOperation): { type: string; id: string; revision: number } | null {
  const content = operation.content;
  if (operation.type === 'product.saved' && typeof content.id === 'string') {
    return { type: 'product', id: content.id, revision: Number(content.revision ?? 1) };
  }
  if (operation.type === 'customer.saved' && typeof content.id === 'string') {
    return { type: 'customer', id: content.id, revision: Number(content.revision ?? 1) };
  }
  if (operation.type.startsWith('quote.') && typeof content.quoteId === 'string') {
    return { type: 'quote', id: content.quoteId, revision: Number(content.revision ?? 1) };
  }
  return null;
}

function inventoryMovements(operation: SyncOperation): Array<Record<string, unknown> & {
  id: string;
  product_id: string;
  delta: number;
  cost_micros: number | string;
}> {
  const raw: unknown[] = [];
  if (operation.type === 'stock.adjusted') raw.push(operation.content.movement);
  if (operation.type === 'sale.created' && Array.isArray(operation.content.stockMovements)) {
    raw.push(...operation.content.stockMovements);
  }
  return raw.filter(
    (value): value is Record<string, unknown> & {
      id: string;
      product_id: string;
      delta: number;
      cost_micros: number | string;
    } =>
      value !== null &&
      typeof value === 'object' &&
      typeof (value as Record<string, unknown>).id === 'string' &&
      typeof (value as Record<string, unknown>).product_id === 'string' &&
      typeof (value as Record<string, unknown>).delta === 'number' &&
      (typeof (value as Record<string, unknown>).cost_micros === 'number' ||
        (typeof (value as Record<string, unknown>).cost_micros === 'string' &&
          /^\d+$/.test((value as Record<string, unknown>).cost_micros as string))),
  );
}

function isFinancial(type: string): boolean {
  return /^(sale\.|payment\.|purchase\.|supplier\.|expense\.|cash\.|work\.advance|quote\.converted)/.test(type);
}

function isTerminalQuoteStatus(value: unknown): boolean {
  return value === 'converted' || value === 'rejected' || value === 'expired';
}
