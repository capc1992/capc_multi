import type { PullPage, PushAcknowledgement, SyncOperation } from './protocol.js';

export class IdempotencyConflictError extends Error {}

export interface SyncStore {
  push(operation: SyncOperation): Promise<PushAcknowledgement>;
  pull(businessId: string, after: number, limit: number): Promise<PullPage>;
  close(): Promise<void>;
}
