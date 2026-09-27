# Protocolo de sincronización CAPC v1

## Propósito y límites

Windows y Android conservan su SQLite privado como fuente de verdad durante la operación. Guardar una venta, pago, movimiento, compra o gasto no depende de internet: la mutación local y su evento de outbox se confirman en la misma transacción. La API central nunca conecta un dispositivo directamente con otro; almacena eventos por negocio en PostgreSQL y los distribuye mediante un cursor monotónico.

Esta base no despliega el VPS ni activa sincronización en una instalación existente. Sin `CAPC_SYNC_URL`, el motor permanece en `local_only` y no abre conexiones. La autenticación remota definitiva y el almacenamiento seguro de sus tokens quedan para la siguiente etapa.

## Sobre de operación

Cada elemento enviado a `/api/v1/sync/push` contiene:

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

- `business_id` define el aislamiento de todas las consultas y escrituras.
- `device_id` identifica el origen, no concede autorización.
- `operation_id` es estable durante todos los reintentos. Su reutilización con contenido distinto devuelve `409`.
- `schema_version` versiona el contenido del evento, independientemente del esquema SQLite.
- `occurred_at` es UTC y se conserva como dato de negocio; el servidor agrega su propia fecha de recepción.
- `content` se valida, tiene un límite de transporte y no admite contraseñas, hashes, códigos de recuperación, tokens ni secretos.

Los pesos continúan como enteros. Valores en millonésimas que exceden el entero seguro de JSON se transportan como cadenas decimales y PostgreSQL los guarda como `BIGINT`; el cliente los convierte de nuevo a entero exacto. No se usan números de punto flotante para dinero.

## Push e idempotencia

`POST /api/v1/sync/push` acepta hasta 100 operaciones. El encabezado `X-Business-Id` debe coincidir con cada `business_id` del lote. Por cada operación, PostgreSQL ejecuta una transacción que:

1. inserta el evento canónico con restricción única `(business_id, operation_id)`;
2. compara la huella si ya existía;
3. aplica la proyección de entidad, evento financiero o movimiento de inventario;
4. registra conflictos sin borrar el evento;
5. confirma y devuelve `server_cursor`.

Las proyecciones versionadas se serializan por entidad y los saldos de movimientos por producto mediante bloqueos transaccionales consultivos de PostgreSQL. Así dos solicitudes concurrentes no pueden observar el mismo estado anterior y ocultar una revisión o un saldo negativo.

Si la respuesta se pierde después del `COMMIT`, el cliente reenvía el mismo `operation_id`; recibe el mismo cursor y no repite la proyección. La outbox local conserva `retry_count`, `last_attempt_at`, `acknowledged_at`, `server_cursor` y `last_error`.

## Pull, inbox y cursor

`GET /api/v1/sync/pull?business_id=…&device_id=…&after=…&limit=…` devuelve únicamente eventos del negocio cuyo `server_cursor` sea mayor que `after`, ordenados ascendentemente. `next_cursor` nunca disminuye y `has_more` indica paginación.

El cliente primero inserta todo el lote en `inbox` con unicidad por operación y cursor. Después materializa dependencias en orden: catálogo/clientes, movimientos, ventas y pagos. Un evento con dependencia ausente queda en `received` y se reintenta después; un conflicto determinista pasa a `conflict`. Avanzar el cursor no elimina la inbox pendiente.

## Tablas locales SQLite, esquema 3

- `outbox`: evento local, estado, intentos, error y confirmación remota.
- `inbox`: evento recibido, cursor, estado de aplicación y error.
- `sync_state`: cursor por negocio, último intento, último éxito y estado interno.
- `sync_conflicts`: conflicto durable y resoluble sin modificar el evento original.
- `products`, `customers` y `quotes`: columna `revision` positiva.

La migración 2→3 reconstruye únicamente la outbox para ampliar su restricción de estados; copia todos los eventos pendientes y crea el resto con `IF NOT EXISTS`. La migración 1→2→3 continúa siendo transaccional.

Estados internos: `local_only`, `pending`, `syncing`, `synced` y `error`. “Sincronizado” solo puede mostrarse después de confirmar push y pull; sin configuración la interfaz debe seguir comunicando almacenamiento local.

## Tablas PostgreSQL

- `sync_operations`: log canónico, cursor global monotónico y huella idempotente.
- `sync_entities`: proyección versionada de productos, clientes y cotizaciones.
- `sync_financial_events`: eventos financieros inmutables.
- `sync_inventory_movements`: libro de movimientos; nunca guarda stock absoluto.
- `sync_conflicts`: revisiones obsoletas, inventario negativo y futuros conflictos de dominio.

Todas las claves e índices de lectura incluyen `business_id`. Ninguna consulta del almacén recibe un identificador de entidad sin el negocio correspondiente.

## Reglas de convergencia

- Ventas, líneas, pagos, abonos, devoluciones, compras, gastos y caja son anexos inmutables o compensaciones.
- El inventario central es la suma de movimientos. Dos ventas offline se conservan; si la suma queda negativa se crea `inventory.negative`.
- Productos, servicios y clientes solo avanzan a una revisión superior. Una revisión igual con contenido distinto o inferior crea `revision.stale`.
- Cotizaciones no pueden retroceder desde `converted`, `rejected` o `expired`; esta regla se materializará por completo antes del piloto remoto.
- Ninguna operación financiera usa “último cambio gana”.
- UUID, `operation_id` y la representación monetaria exacta se preservan extremo a extremo.

## Seguridad y registros

La API exige Bearer y alcance explícito `X-Business-Id`. El secreto compartido actual es solo una base de desarrollo; antes de desplegar se sustituirá por tokens cortos ligados a negocio/dispositivo, rotación y revocación. Flutter recibirá el token desde almacenamiento seguro del sistema mediante un proveedor en memoria; nunca se escribirá en SQLite ni en `.env` versionado.

Fastify oculta `Authorization`, cookies y `Set-Cookie`. Los manejadores no registran cuerpos. Los errores enviados al cliente son genéricos. `.env.example` solo contiene marcadores.

## Recuperación

Un fallo de red deja la operación en `error` o `sending`; el siguiente ciclo la reclama de nuevo. Una respuesta perdida se recupera por idempotencia. Si el cursor local se pierde pero la inbox se conserva, puede reiniciarse desde el último cursor confirmado. Si se restaura un respaldo SQLite, el `device_id` local se conserva según las reglas existentes y el servidor vuelve a entregar los eventos posteriores al cursor restaurado.

Ante corrupción central se restaura PostgreSQL desde respaldo, se verifica la secuencia y se reinicia el servicio antes de aceptar tráfico. No se deben borrar operaciones para “resolver” conflictos; se agregan compensaciones o resoluciones auditables.
