# CAPC Sync Server

Servicio pequeño de sincronización para CAPC. Usa Node.js, TypeScript, Fastify y PostgreSQL. No reemplaza SQLite: recibe eventos idempotentes y los distribuye por cursor.

## Requisitos

- Node.js 22 o posterior;
- PostgreSQL 15 o posterior;
- una base y un usuario exclusivos con permisos mínimos sobre esa base.

## Configuración local

```powershell
Copy-Item .env.example .env
npm install
npm run check
npm test
```

Variables:

- `DATABASE_URL`: conexión PostgreSQL; nunca se versiona la real.
- `SYNC_SHARED_SECRET`: mínimo 32 caracteres, solo fundamento de desarrollo.
- `HOST` y `PORT`: escucha; por defecto `127.0.0.1:3100`.
- `LOG_LEVEL`: nivel de Fastify. Los encabezados sensibles están ocultos y los cuerpos no se registran.

La aplicación Flutter recibe la URL con `--dart-define=CAPC_SYNC_URL=https://…`. Sin esa definición funciona completamente local. El token debe proporcionarlo posteriormente un adaptador de almacenamiento seguro; no se guarda en SQLite.

## Migración

Con PostgreSQL disponible:

```powershell
psql "$env:DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/001_sync_foundation.sql
npm run build
npm start
```

La migración está encerrada en `BEGIN/COMMIT` y es repetible para los objetos de esta etapa. Antes de aplicarla en un entorno existente se exige respaldo y prueba de restauración.

## Respaldo y recuperación

Use `pg_dump --format=custom` con una cuenta de respaldo y conserve cifrado fuera del VPS. Verifique periódicamente con `pg_restore --list` y realice restauraciones de ensayo en otra base. Detenga la recepción de operaciones durante una restauración; después compruebe el cursor máximo y las restricciones únicas antes de reabrir tráfico.

## Despliegue futuro con PM2

No se desplegó nada en esta etapa. El procedimiento futuro será: compilar en una ruta versionada, cargar secretos desde el gestor del servidor, ejecutar migración respaldada, iniciar `dist/src/main.js` con PM2 como usuario sin privilegios y colocar un proxy HTTPS delante. No se debe guardar `DATABASE_URL` ni el secreto en `ecosystem.config.js` versionado. Configure reinicio, límites de memoria y rotación de logs sin cuerpos.

## Comprobaciones actuales

`npm run check`, `npm test` y `npm run build` no necesitan PostgreSQL porque las pruebas HTTP usan el mismo contrato sobre `MemorySyncStore`. La verificación real de SQL y transacciones requiere PostgreSQL local/CI; no debe darse por aprobada hasta ejecutar migración y pruebas de integración allí.
