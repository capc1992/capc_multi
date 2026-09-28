import type { PullPage, PushAcknowledgement, SyncOperation } from './protocol.js';

export class IdempotencyConflictError extends Error {}
export class BusinessUnavailableError extends Error {}

export interface SyncStore {
  push(operation: SyncOperation): Promise<PushAcknowledgement>;
  pull(businessId: string, after: number, limit: number): Promise<PullPage>;
  deleteBusiness(businessId: string): Promise<void>;
  close(): Promise<void>;
}
