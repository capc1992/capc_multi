import { z } from 'zod';

const forbiddenKeys = new Set([
  'password',
  'password_hash',
  'password_salt',
  'recovery_code',
  'recovery_hash',
  'token',
  'access_token',
  'refresh_token',
  'secret',
]);

function containsSecret(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsSecret);
  if (value !== null && typeof value === 'object') {
    return Object.entries(value).some(
      ([key, child]) => forbiddenKeys.has(key.toLowerCase()) || containsSecret(child),
    );
  }
  return false;
}

export const OperationSchema = z
  .object({
    business_id: z.string().uuid(),
    device_id: z.string().uuid(),
    operation_id: z.string().uuid(),
    type: z.string().regex(/^[a-z][a-z0-9]*(?:\.[a-zA-Z0-9]+)+$/).max(80),
    schema_version: z.literal(1),
    occurred_at: z.iso.datetime({ offset: true }),
    content: z.record(z.string(), z.unknown()),
  })
  .strict()
  .superRefine((operation, context) => {
    if (containsSecret(operation.content)) {
      context.addIssue({
        code: 'custom',
        path: ['content'],
        message: 'El contenido incluye campos secretos no sincronizables',
      });
    }
  });

export const PushSchema = z
  .object({ operations: z.array(OperationSchema).min(1).max(100) })
  .strict();

export const PullQuerySchema = z.object({
  business_id: z.string().uuid(),
  device_id: z.string().uuid(),
  after: z.coerce.number().int().min(0).default(0),
  limit: z.coerce.number().int().min(1).max(500).default(200),
});

export type SyncOperation = z.infer<typeof OperationSchema>;

export type StoredOperation = SyncOperation & { server_cursor: number };

export interface PushAcknowledgement {
  operation_id: string;
  server_cursor: number;
  duplicate: boolean;
  conflicts: number;
}

export interface PullPage {
  operations: StoredOperation[];
  next_cursor: number;
  has_more: boolean;
}
