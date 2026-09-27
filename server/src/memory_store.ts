import { createHash } from 'node:crypto';

import type { PullPage, PushAcknowledgement, StoredOperation, SyncOperation } from './protocol.js';
import { IdempotencyConflictError, type SyncStore } from './store.js';

function digest(operation: SyncOperation): string {
  return createHash('sha256').update(JSON.stringify(operation)).digest('hex');
}

export class MemorySyncStore implements SyncStore {
  private cursor = 0;
  private readonly operations: Array<StoredOperation & { digest: string }> = [];
  private readonly inventory = new Map<string, number>();
  readonly conflicts: Array<{ businessId: string; productId: string; operationId: string }> = [];

  async push(operation: SyncOperation): Promise<PushAcknowledgement> {
    const existing = this.operations.find(
      (item) =>
        item.business_id === operation.business_id &&
        item.operation_id === operation.operation_id,
    );
    const hash = digest(operation);
    if (existing) {
      if (existing.digest !== hash) throw new IdempotencyConflictError();
      return {
        operation_id: operation.operation_id,
        server_cursor: existing.server_cursor,
        duplicate: true,
        conflicts: 0,
      };
    }
    const stored = structuredClone({ ...operation, server_cursor: ++this.cursor, digest: hash });
    this.operations.push(stored);
    const conflicts = this.applyInventory(operation);
    return {
      operation_id: operation.operation_id,
      server_cursor: stored.server_cursor,
      duplicate: false,
      conflicts,
    };
  }

  async pull(businessId: string, after: number, limit: number): Promise<PullPage> {
    const matches = this.operations
      .filter((operation) => operation.business_id === businessId && operation.server_cursor > after)
      .sort((a, b) => a.server_cursor - b.server_cursor);
    const selected = matches.slice(0, limit);
    return {
      operations: selected.map(({ digest: _digest, ...operation }) => structuredClone(operation)),
      next_cursor: selected.at(-1)?.server_cursor ?? after,
      has_more: matches.length > selected.length,
    };
  }

  async close(): Promise<void> {}

  private applyInventory(operation: SyncOperation): number {
    const content = operation.content;
    const candidates: unknown[] = [];
    if (operation.type === 'stock.adjusted') candidates.push(content.movement);
    if (operation.type === 'sale.created' && Array.isArray(content.stockMovements)) {
      candidates.push(...content.stockMovements);
    }
    let count = 0;
    for (const candidate of candidates) {
      if (candidate === null || typeof candidate !== 'object') continue;
      const movement = candidate as Record<string, unknown>;
      if (typeof movement.product_id !== 'string' || typeof movement.delta !== 'number') continue;
      const key = `${operation.business_id}:${movement.product_id}`;
      const next = (this.inventory.get(key) ?? 0) + movement.delta;
      this.inventory.set(key, next);
      if (next < 0) {
        this.conflicts.push({
          businessId: operation.business_id,
          productId: movement.product_id,
          operationId: operation.operation_id,
        });
        count++;
      }
    }
    return count;
  }
}
