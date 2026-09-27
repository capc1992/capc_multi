# Hoja de ruta de sincronización

## Etapa 1 — fundamento funcional (completada)

- SQLite con outbox/inbox, cursor, estados y conflictos;
- contratos Dart, transporte opcional y motor desactivado sin URL;
- Fastify/PostgreSQL con idempotencia, aislamiento y cursor monotónico;
- materialización inicial de catálogo, clientes, ventas, pagos e inventario;
- pruebas entre dos SQLite y almacén central en memoria.

Referencia: `858dedbc31367074408ebe623027b3381e0b97d5` en `feature/cloud-sync-foundation`.

## Etapa 2 — identidad remota y PostgreSQL integrado (implementada; aprobación condicionada a CI)

- identidad individual de negocio, propietario remoto y dispositivo; eliminado `SYNC_SHARED_SECRET`;
- acceso con vencimiento, renovación rotatoria, revocación por familia/dispositivo y permisos ligados a negocio/equipo;
- códigos temporales de un solo uso, límites de intentos y auditoría sin secretos;
- almacenamiento Flutter mediante Android Keystore/Windows Credential Manager;
- pantallas de conectar, ingresar, vincular, listar/revocar equipos y cerrar sesión;
- protección contra mezcla: solo instalación nueva/sin movimientos adopta automáticamente el ID canónico;
- SQLite esquema 4 y materializadores de compras/proveedores, devoluciones, caja/gastos, cotizaciones, trabajos/anticipos;
- migraciones PostgreSQL ascendentes/descendentes y GitHub Actions con PostgreSQL 16 real;
- paquete Windows portable para instalar/copiar en dos o más equipos, sin incluir datos ni credenciales.

La implementación no se considera aprobada contra PostgreSQL hasta que el workflow `Cloud Sync Identity` termine satisfactoriamente en GitHub. No se accedió al VPS ni a la base real.

## Etapa 3 — resolución y experiencia operativa

- estado de cola/último éxito/reintento manual;
- bandeja de conflictos y resolución asistida;
- numeración visible sin colisiones entre dispositivos;
- reintentos progresivos y sincronización en segundo plano según plataforma;
- flujo explícito de migración de un negocio con datos (nunca mezcla automática).

## Etapa 4 — piloto controlado

- VPS de ensayo separado, TLS, firewall, usuario PostgreSQL mínimo y secretos externos;
- desconexión prolongada, reloj incorrecto, respuesta perdida y restauración;
- dos Windows y un Android con datos ficticios;
- respaldo/restore, observabilidad y reversa ensayados.

Requiere autorización separada para acceder al VPS.

## Etapa 5 — producción y distribución

- despliegue autorizado con servicio supervisado y proxy TLS;
- migraciones con ventana, respaldo y reversa;
- firma Android/Windows, instalador firmado y actualización controlada;
- habilitación gradual por negocio.

Play Console, publicación y activación de `https://api.capcmultiservicios.site` requieren autorización separada.
