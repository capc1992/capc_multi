# Protocolo de sincronización CAPC v2

## Principios

Windows y Android conservan SQLite privado como fuente operativa. Guardar ventas, pagos, inventario, compras, devoluciones, caja, gastos, cotizaciones, trabajos o anticipos no depende de internet: la mutación y su outbox se confirman en la misma transacción. PostgreSQL distribuye eventos por negocio mediante un cursor monotónico; ningún dispositivo conecta directamente con otro.

Sin `CAPC_SYNC_URL`, el motor queda en `local_only`, la interfaz indica operación offline y no abre conexiones. La dirección `https://api.capcmultiservicios.site` está preparada como referencia, pero no está incorporada a compilaciones normales.

## Identidad remota

La identidad local y la remota son independientes. Nunca se transmiten usuarios, contraseñas, sales/hashes locales, sesiones locales ni códigos de recuperación offline.

El primer equipo crea el negocio remoto usando su `business_id` local como ID canónico. Crea a la vez un propietario remoto y autoriza ese `device_id`. Las contraseñas remotas se derivan con scrypt y sal aleatoria en PostgreSQL.

Un equipo autorizado genera un código aleatorio temporal (10 minutos), de un solo uso y almacenado solo como hash. El segundo equipo lo introduce y recibe el mismo `business_id` más tokens exclusivos para su `device_id`. Flutter permite adopción automática únicamente si:

- no existe una identidad segura asociada a otro negocio; y
- SQLite es una instalación nueva o no tiene ventas, pagos, movimientos de inventario, devoluciones, caja, gastos, compras, cotizaciones, trabajos ni anticipos.

Si hay movimientos u otra identidad, se rechaza y se exige respaldo y migración explícita. No se mezclan negocios silenciosamente.

Los dispositivos se pueden listar y revocar. Revocar marca el dispositivo, sus sesiones y renovaciones; el equipo pierde acceso aunque conserve un token anterior.

## Tokens y permisos

Los tokens son opacos y aleatorios. PostgreSQL conserva únicamente `SHA-256(AUTH_TOKEN_PEPPER || token)`, nunca el valor entregado al cliente. Flutter los guarda mediante `SecureCredentialStore`: Android Keystore o Windows Credential Manager. No aparecen en SQLite, preferencias simples, archivos de configuración, outbox, logs ni auditoría.

- acceso: 15 minutos por defecto;
- renovación: 30 días por defecto, rotación en cada uso;
- reutilizar una renovación revoca toda su familia y las sesiones derivadas;
- cierre de sesión y revocación de dispositivo invalidan credenciales activas;
- cada sesión liga `business_id`, `device_id`, propietario remoto y permisos (`sync:read`, `sync:write`, `devices:read`, `devices:manage`).

`X-Business-Id` debe coincidir con la sesión autenticada, pero nunca autoriza por sí mismo. Push exige además que cada operación coincida en negocio y dispositivo; pull exige lo mismo en sus parámetros. Ingreso, renovación y vinculación tienen límites persistentes de intentos.

## Sobre de operación

```json
{
  "business_id": "uuid",
  "device_id": "uuid",
  "operation_id": "uuid",
  "type": "sale.created",
  "schema_version": 1,
  "occurred_at": "2026-09-27T03:00:00.000Z",
  "content": {}
}
```

`operation_id` permanece estable en reintentos. El mismo ID/contenido devuelve el cursor previo; contenido distinto devuelve `409`. `occurred_at` es UTC del negocio y PostgreSQL agrega `received_at`. El contenido rechaza claves de contraseña, hash, recuperación, token o secreto.

Dinero local continúa como pesos enteros; costos/valoración viajan en millonésimas exactas. Enteros fuera del rango seguro JSON viajan como cadenas decimales y llegan a `BIGINT`. No se usa punto flotante.

## Push, pull e idempotencia

`POST /api/v1/sync/push` admite hasta 100 operaciones. Cada operación se confirma en una transacción que inserta el evento canónico, valida su huella, materializa proyecciones/libros y registra conflictos. Si se pierde la respuesta, reenviar devuelve el mismo cursor sin repetir efectos.

`GET /api/v1/sync/pull` devuelve solo el negocio autenticado, con cursor mayor que `after`, en orden ascendente. `next_cursor` no disminuye. Flutter inserta primero la inbox y luego materializa por dependencias; una dependencia ausente permanece `received` para reintento, y un conflicto determinista queda durable.

## Materializadores

SQLite esquema 8 y PostgreSQL cubren:

- entidades revisadas: productos, clientes, proveedores, cotizaciones, trabajos y configuración del negocio;
- tombstones sincronizables para productos, clientes y proveedores, sin borrado físico inmediato;
- hechos financieros inmutables: ventas, pagos, compras, abonos a proveedores, devoluciones/anulaciones, caja, gastos, anticipos y conversiones;
- documentos compuestos: compras/líneas, cotizaciones/líneas, trabajos/anticipos;
- inventario: solo `sync_inventory_movements` y movimientos SQLite; nunca stock absoluto.

Ventas offline nunca se eliminan. Dos ventas concurrentes se conservan; un saldo global negativo crea `inventory.negative`. Revisiones inferiores o iguales con contenido diferente crean `revision.stale`. Cotizaciones terminales (`converted`, `rejected`, `expired`) no retroceden. Cada consulta/proyección incluye `business_id`.

Los documentos creados en paralelo pueden partir del mismo consecutivo visible. El receptor conserva ambos UUID y, solo cuando el número ya existe para otro ID, agrega un sufijo estable derivado del dispositivo de origen. La secuencia local de ventas se reasigna al materializar para respetar su restricción única. Ningún documento se descarta por una colisión de numeración.

## Conflictos y auditoría

Los conflictos quedan en `sync_conflicts` y se muestran a usuarios con `conflictos.ver`. La acción protegida por `conflictos.resolver` marca el caso como revisado y conserva el evento, el detalle y la fecha; no reemplaza datos automáticamente. Los conflictos financieros se corrigen con una operación compensatoria explícita.

Cada evento de negocio incorpora en `_audit` la identidad local o central que lo originó. PostgreSQL conserva el sobre canónico y `GET /api/v1/access/audit` combina esos eventos con la auditoría de seguridad. La respuesta está aislada por `business_id` y requiere `auditoria.ver` o el permiso administrativo compatible `access:read`. Si el servidor no responde, la auditoría local continúa disponible.

Las sesiones centrales activas renuevan su concesión offline al rotar el token. Flutter valida de nuevo la firma Ed25519, negocio, dispositivo, usuario, versión de seguridad y vencimiento, actualiza la caché local y mantiene el límite máximo de 72 horas. Un cambio central de permisos se aplica en la siguiente renovación conectada; un equipo desconectado conserva únicamente la concesión firmada vigente hasta su vencimiento.

## PostgreSQL

Tablas de datos: `sync_operations`, `sync_entities`, `sync_financial_events`, `sync_inventory_movements`, `sync_conflicts`.

Tablas de identidad: `businesses`, `remote_owners`, `devices`, `sessions`, `refresh_tokens`, `linking_codes`, `token_revocations`, `security_audit`, `auth_attempts`.

Control de acceso central: `access_permissions`, `access_roles`, `access_role_permissions`, `business_users` y `business_user_roles`. Todas las asignaciones se validan dentro del `business_id`; los roles usan versión optimista, pueden clasificarse como administrativos u operativos y el código de activación de un usuario se almacena únicamente como hash con vencimiento. La contraseña central se deriva con scrypt. Una sesión individual recibe una concesión Ed25519 de hasta 72 horas ligada al negocio, dispositivo, usuario, permisos y versión de seguridad; Flutter valida firma, alcance y vencimiento antes de considerarla para trabajo offline.

GitHub Actions usa PostgreSQL 16 real. Parte de una base vacía, aplica migraciones dos veces, prueba idempotencia, aislamiento, revocación, códigos vencidos/reutilizados, dispositivo ajeno, límites y cursor monotónico; después revierte la migración de identidad, verifica el esquema y la reaplica. `MemorySyncStore` queda solo para pruebas unitarias.

## Registros y recuperación

Fastify oculta Authorization, cookies, `Set-Cookie` y el alcance de negocio. Los handlers no registran cuerpos, contraseñas, códigos ni tokens; fallos internos registran solo el tipo de error. Auditoría de seguridad guarda evento, IDs y metadatos no secretos.

Un fallo de red conserva outbox/inbox. Restaurar SQLite conserva el `device_id` del equipo según las reglas de respaldo. Restaurar PostgreSQL exige detener escrituras, recuperar desde respaldo validado, comprobar secuencias/restricciones y reabrir tráfico. Los conflictos se resuelven con compensaciones auditables, nunca borrando operaciones.
