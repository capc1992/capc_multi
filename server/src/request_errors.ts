// Use controlled messages: raw parser/SQL errors can contain passwords, tokens,
// input values, connection strings or entire failing rows.
const safeMessages: Readonly<Record<string, string>> = {
  FST_ERR_CTP_INVALID_JSON_BODY: 'Invalid JSON body',
  FST_ERR_CTP_EMPTY_JSON_BODY: 'Empty JSON body',
  FST_ERR_CTP_INVALID_MEDIA_TYPE: 'Unsupported Content-Type',
  FST_ERR_CTP_INVALID_CONTENT_LENGTH: 'Content-Length does not match body length',
  FST_ERR_CTP_BODY_TOO_LARGE: 'Request body exceeds size limit',
  FST_ERR_VALIDATION: 'Request validation failed',
  '42P01': 'PostgreSQL relation does not exist; check applied migrations',
  '42703': 'PostgreSQL column does not exist; check applied migrations',
  '42501': 'PostgreSQL insufficient privileges',
  '28P01': 'PostgreSQL password authentication failed',
  '28000': 'PostgreSQL authorization failed',
  '3D000': 'PostgreSQL database does not exist',
  '23505': 'PostgreSQL unique constraint violation',
  '23503': 'PostgreSQL foreign key violation',
  '23502': 'PostgreSQL not-null constraint violation',
  '23514': 'PostgreSQL check constraint violation',
  '22P02': 'PostgreSQL invalid input syntax for data type',
  '53300': 'PostgreSQL connection limit exceeded',
  ECONNREFUSED: 'Database connection refused',
  ETIMEDOUT: 'Database connection timed out',
  ENOTFOUND: 'Database hostname could not be resolved',
};

export function requestErrorDiagnostic(error: unknown) {
  const fields = typeof error === 'object' && error !== null
    ? error as Record<string, unknown> : {};
  const code = typeof fields.code === 'string' && /^[A-Z0-9_]{1,80}$/.test(fields.code)
    ? fields.code : 'UNKNOWN';
  const status = code.startsWith('FST_ERR_') && typeof fields.statusCode === 'number'
    && Number.isInteger(fields.statusCode) && fields.statusCode >= 400 && fields.statusCode < 500
    ? fields.statusCode : 500;
  return {
    error_type: error instanceof Error && /^[A-Za-z][A-Za-z0-9_]{0,79}$/.test(error.name)
      ? error.name : 'UnknownError',
    error_code: code,
    status_code: status,
    message: safeMessages[code] ?? (status < 500 ? 'Request rejected by Fastify' : 'Internal request failure; raw message omitted'),
  };
}
