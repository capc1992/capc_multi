# Hoja de ruta de sincronización

## Etapa 1 — fundamento funcional (esta rama)

- esquema SQLite 3 con outbox ampliada, inbox, cursor, estados y conflictos;
- contratos Dart, transporte HTTP y motor desactivado sin URL;
- API Fastify v1, migración PostgreSQL, idempotencia y cursor monotónico;
- materialización inicial de producto, cliente, venta, pago y movimiento;
- pruebas con dos SQLite temporales y almacén central en memoria;
- documentación de seguridad, recuperación y despliegue futuro.

No incluye despliegue, cuentas remotas, interfaz de inicio de sesión remoto ni piloto con PostgreSQL real.

## Etapa 2 — identidad remota y PostgreSQL integrado

- credenciales por negocio y dispositivo, expiración, rotación y revocación;
- almacenamiento seguro en Credential Manager/Keystore mediante adaptadores de plataforma;
- pruebas de integración contra PostgreSQL efímero en CI;
- migrador ejecutable, respaldo/restore ensayado y métricas sin contenido sensible;
- materializadores completos para compras, devoluciones, caja, gastos, cotizaciones y trabajos.

## Etapa 3 — resolución y experiencia operativa

- pantalla de estado, cola, último éxito y reintento manual;
- bandeja de conflictos con inventario negativo y revisiones concurrentes;
- reglas completas de cotizaciones terminales y edición asistida de catálogo;
- asignación de numeración visible sin colisiones entre dispositivos;
- límites, reintentos con espera progresiva y sincronización en segundo plano según plataforma.

## Etapa 4 — piloto controlado

- VPS de ensayo separado, TLS, firewall, usuario PostgreSQL mínimo y secretos fuera del repositorio;
- pruebas de desconexión prolongada, reloj incorrecto, respuesta perdida y restauración;
- dos equipos Windows y un Android con datos ficticios;
- simulación de respaldo y recuperación, observabilidad y plan de reversa.

## Etapa 5 — producción y distribución

- despliegue autorizado con PM2/systemd, proxy TLS y copias verificadas;
- migraciones con ventana y reversa documentadas;
- firma Android/Windows, política de privacidad y pruebas cerradas;
- habilitación gradual por negocio. Play Console y publicación requieren autorización separada.
