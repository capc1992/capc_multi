# CAPC Sync Server

API Fastify/TypeScript para identidad remota y sincronización offline-first sobre PostgreSQL 16. SQLite sigue siendo la fuente operativa de cada equipo: la API almacena eventos idempotentes, proyecciones revisadas, hechos financieros inmutables y movimientos de inventario.

## Seguridad e identidad

- Cada propietario remoto usa una contraseña independiente de las cuentas locales.
- Nunca se reciben ni copian contraseñas/hashes locales ni códigos de recuperación offline.
- Los tokens opacos y códigos de vinculación se guardan únicamente como hashes SHA-256 con `AUTH_TOKEN_PEPPER`.
- Acceso: 15 minutos por defecto. Renovación: 30 días, rotación obligatoria y revocación por familia ante reutilización.
- Cada sesión contiene `business_id`, `device_id` y permisos. `X-Business-Id` solo se compara contra esa identidad.
- Ingreso, renovación y vinculación tienen límites persistentes por ventana.
- Fastify oculta `Authorization`, cookies y `X-Business-Id`; los handlers no registran contraseñas, códigos, tokens ni cuerpos.

## Requisitos

- Node.js 22 o posterior.
- PostgreSQL 16 (la misma versión fijada en GitHub Actions y prevista para el futuro VPS).
- Base y usuario exclusivos con permisos mínimos sobre esa base.

No se necesita Docker para desarrollar Flutter. La integración SQL se ejecuta en GitHub Actions con un servicio PostgreSQL real.

## Configuración

```powershell
Copy-Item .env.example .env
npm ci
npm run check
npm test
```

Variables sin valores reales en el repositorio:

- `DATABASE_URL`: conexión PostgreSQL.
- `AUTH_TOKEN_PEPPER`: secreto aleatorio de al menos 32 caracteres.
- `ACCESS_TOKEN_TTL_MINUTES`: 5–60; predeterminado 15.
- `REFRESH_TOKEN_TTL_DAYS`: 1–90; predeterminado 30.
- `HOST`, `PORT`, `LOG_LEVEL`.

## Migraciones y reversa

Desde `server/` y con las variables cargadas:

```powershell
npm run migrate
npm run migrate                 # comprueba idempotencia
npm run test:postgres
npm run migrate:rollback        # revierte solo la última migración
npm run migrate:verify-rollback
npm run migrate                 # reaplica identidad
```

`schema_migrations` registra versiones. `001_sync_foundation.sql` crea el registro/proyecciones de sincronización; `002_remote_identity.sql` crea negocios, propietarios remotos, dispositivos, sesiones, renovaciones, códigos, revocaciones, auditoría y límites. Cada versión tiene `.down.sql` y usa transacciones.

Antes de migrar un entorno existente se exige respaldo y restauración ensayada. En el VPS futuro se usará `pg_dump --format=custom` y verificación/restauración en otra base. Esta rama no accede ni despliega al VPS.

## API

El contrato está en `openapi.yaml`. Flujo resumido:

1. `POST /api/v1/identity/businesses`: crea negocio remoto y primer dispositivo usando el `business_id` local como ID canónico.
2. Un dispositivo autorizado crea un código temporal con `POST /identity/link-codes`.
3. El equipo nuevo llama `POST /identity/link`; el cliente solo lo permite si no tiene movimientos ni otra identidad remota.
4. `POST /identity/login` solo funciona para dispositivos autorizados.
5. `POST /identity/refresh` rota la renovación. `DELETE /identity/devices/{id}` revoca un equipo perdido.
6. Push/pull verifican token, negocio, dispositivo y permiso antes de procesar eventos.

## Verificación

```powershell
npm run check
npm test
npm run build
npm audit --omit=dev
```

Sin `DATABASE_URL`, Vitest omite únicamente `postgres.integration.test.ts`; no debe interpretarse como aprobación SQL. El workflow `.github/workflows/cloud-sync-identity.yml` crea PostgreSQL 16 desde cero, aplica migraciones dos veces, prueba identidad/sincronización, verifica rollback/reaplicación, ejecuta auditoría de producción y compila el servidor.
