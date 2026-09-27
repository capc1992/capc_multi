# Contrato local CAPC MULTISERVICIO - esquema 2

Este contrato sustituye el alcance antiguo sin autenticación. La interfaz y las operaciones locales comparten reglas entre Windows y la adaptación Android offline, en español, COP enteros y cantidades enteras. Una empresa/caja local activa; sin servidor ni sincronización. Windows `0.3.0` continúa como base estable. La carpeta canónica es `C:\Users\CAPC\capc_multi`.

## Arquitectura y compatibilidad

`lib/data/models.dart` exporta los modelos comunes y `operations_models.dart`. `CapcRepository` es la frontera transaccional y de autorización. `operations.dart` comparte su biblioteca y reutiliza ejecutores de transacción para compras, cotizaciones y trabajos: no anida transacciones públicas.

SQLite conserva claves foráneas, WAL, synchronous FULL, identificadores UUID, eventos locales e historial. Migración v1 a v2 conserva productos, clientes, líneas históricas, ventas, pagos, movimientos, numeración y operaciones idempotentes. Las nuevas tablas identifican negocio y dispositivo; las consultas se limitan al negocio local. La aplicación Windows permite una sola instancia por sesión para evitar restauraciones concurrentes; el mutex y el código nativo de ventana no se ejecutan en Android.

`AppPlatformServices` separa ubicación privada, driver local, selector/exportación, impresión/compartir e información del dispositivo. Windows y Android reutilizan `CapcRepository` y el mismo SQLite incluido; no existen repositorios de negocio duplicados por plataforma.

No se destruyen ni recrean datos del negocio durante actualización. Una versión posterior desconocida se rechaza. La base vacía exige alta de propietario; una base v1 migrada también exige crear su propietario antes de operar.

## Identidad y permisos

`needsSetup`, `setupOwner`, `login`, `logout`, `listUsers` y `saveUser` gestionan usuarios locales. Roles `owner`, `admin`, `cashier`; el primer usuario es propietario, sin credenciales predeterminadas. Contraseñas Argon2id con sal de 16 bytes, 19 MiB, 2 iteraciones, paralelismo 1, hash de 32 bytes. Nunca se registran contraseñas en auditoría.

Permisos verificados en el repositorio, con comprobación de vigencia de sesión y usuario activo. Propietario administra usuarios/configuración/restauración. Administrador gestiona operación y acciones sensibles salvo esas funciones. Cajero vende/cobra y gestiona clientes/cotizaciones/trabajos/caja propia; no modifica precios de catálogo ni efectúa compensaciones o compras. La identidad del actor proviene de sesión, no de un nombre libre.

Recuperación offline: `generateRecoveryCode` exige sesión vigente y contraseña actual; genera 32 bytes aleatorios y conserva solo SHA-256 en settings por usuario. Cada generación sustituye la anterior. `resetPasswordWithRecoveryCode` requiere usuario activo y código válido, cambia la contraseña en una transacción, consume el código, limpia el bloqueo de ingreso e invalida las sesiones. No inicia sesión automáticamente. La recuperación tiene su propio límite de intentos y no revela si el usuario o el código existen. Códigos y contraseñas no aparecen en auditoría.

El mantenimiento autorizado puede preparar `owner_reconfiguration_user_id` únicamente fuera de la app, con acceso al archivo y respaldo validado antes de escribir. Mientras existe, ingreso y operaciones autenticadas quedan bloqueados. `completeOwnerReconfiguration` permite elegir nombre, usuario y contraseña nuevos para ese propietario activo, mantiene su ID y todas las operaciones, registra el cambio y consume el marcador en una transacción. No existe un botón de restablecimiento sin credencial en la app normal. El esquema continúa en versión 2; la recuperación utiliza settings.

## Inventario, costo y venta

Productos: código único sin distinguir mayúsculas, nombre, categoría, unidad, servicio/material, costo de referencia, precio final, stock y mínimo. Editar producto no cambia existencias. Entradas/salidas/ajustes conservan motivo, usuario, fecha y referencia; servicios consumen recetas de materiales o trabajan sin existencias.

La valoración usa cantidad y valor total en millonésimas de peso, con intermediarios BigInt y límites al guardar. Compra por total mayorista o costo unitario; el promedio se actualiza al recibir. Las salidas asignan costo proporcional y la última unidad conserva el residuo exacto. Los costos históricos de v1 quedan marcados legacy; los costos desconocidos impiden utilidad completa.

La sugerencia usa porcentaje sobre costo elegido por el usuario, suma materiales de servicio y costo directo sin duplicarlos y redondea al peso más cercano. Es optativa: introducir el porcentaje no cambia el precio. Solo aceptar la sugerencia o escribir un precio fija la venta.

`importProducts` crea hasta 5000 registros nuevos en una sola transacción, con las mismas validaciones, permisos, movimientos de stock inicial, costos y eventos que `saveProduct`. Rechaza identificadores suministrados y códigos repetidos o existentes, sin sobrescribir registros. `sourceRows` permite conservar las filas originales del Excel al informar errores. La vista previa no escribe en SQLite; el usuario confirma después de validar el libro completo. Una falla cancela todo el lote.

Excel usa `.xlsx` con hoja Productos y nueve encabezados documentados en `docs/EXCEL.md`. El lector rechaza fórmulas, decimales monetarios y de cantidades, columnas desconocidas y stock de servicios. Límites: 10 MB de archivo, 40 MB descomprimidos y 5000 registros. Exportaciones de catálogo, clientes, historial y reportes conservan números y fechas tipados; identificadores y teléfonos son texto. Enteros mayores de 15 cifras se conservan como texto para evitar redondeo de Excel. Los archivos exportados no sustituyen un respaldo.

`createSale` confirma en una transacción venta, snapshots, consumos/stock, pago, caja, auditoría e identificador de operación. Agrega demanda compartida entre productos/servicios para validar existencias. Precios manuales requieren permiso. Cliente y vencimiento obligatorios si queda deuda. Guarda UTC y presenta Bogotá UTC-5.

Cada pago distingue recibido, aplicado y cambio. Solo efectivo produce cambio. `addPayment` evita sobrepago y duplicación sin volver a descontar inventario. Estados: Pagada, Debe, Abono parcial, Anulada.

Las mutaciones con efecto monetario o inventario tienen operationId; el mismo identificador y contenido devuelve el resultado previo, contenido distinto se rechaza. La UI mantiene el identificador mientras reintenta y bloquea doble clic. Confirmar documentos no depende de imprimir correctamente.

## Compensaciones y caja

`returnSale` y `cancelSale` conservan el original y escriben documento compensatorio fechado. Devuelven como máximo cantidades no compensadas. El crédito reduce primero deuda; lo que excede el saldo se reintegra. Solo existencias declaradas recuperables vuelven con su costo histórico. Servicios ya realizados no recuperan automáticamente sus materiales.

Caja registra apertura, cobros, anticipos, gastos, pagos a proveedores y reintegros; los importes de movimientos son con signo. Esperado en efectivo = apertura + movimientos efectivos netos. Tarjeta/transferencia se muestran por separado. Cierre conserva esperado, contado y diferencia, sin ajustar movimientos para ocultarla.

## Compras, cotizaciones y trabajos

Proveedor y compra multilínea con referencia y vencimiento si queda crédito. Registrar compra no ingresa stock; recibir una compra lo hace una sola vez. Abonos a proveedores no superan deuda.

Cotizaciones Borrador/Enviada/Aceptada/Rechazada/Vencida/Convertida. Ninguna cotización descuenta stock o genera pagos. Se acepta dentro de vigencia; la aceptación conserva condiciones y permite conversión posterior. Solo una venta por cotización, manteniendo precios aceptados y valorando stock real al confirmar.

Trabajos Recibido/En proceso/Listo/Entregado con responsable y fecha prevista. Anticipos son flujo de caja y se aplican al documento sin nuevo cobro. Con cotización vinculada se exige aceptación antes del anticipo. No rechazar/vencer una cotización con anticipos: convertir y compensar mediante venta conserva trazabilidad del reintegro.

## Documentos, reportes y recuperación

`CapcDocuments.buildSale`, `buildReport`, `buildStatement` y `buildTableDocument` generan PDF con fuentes locales. `showCapcDocument` presenta PDF real, guardado y diálogo Windows explícito. Formatos Carta y 80 x 250 mm paginado. Sin datos fiscales inventados ni validación de impresora USB real implícita.

`SalesPeriodReport` aplica días civiles Bogotá. Ventas por fecha de confirmación, devoluciones por fecha compensatoria, cobros/reintegros por fecha de pago, costos históricos y gastos separados. Una devolución posterior no modifica un reporte de ventas de un período anterior. Utilidad bruta omite gastos/salarios/impuestos; no se calcula completa con costos desconocidos/legacy. Cartera e inventario se identifican como saldos actuales.

Respaldo consistente SQLite y validación antes de ofrecerlo. Restauración trabaja sobre copia temporal, valida integridad/esquema/referencias y conserva copia previa antes de reemplazar bajo acceso exclusivo. `recoverDatabase` permite restaurar desde fallo de inicio verificando credenciales propietarias del respaldo. No mezclar -wal/-shm de bases distintas.

No hay cifrado integral de SQLite, sincronización remota, multiempresa activa, Android publicado ni facturación electrónica. El historial de auditoría no sustituye la protección del usuario y de los archivos del sistema. La compilación Android de comprobación sigue pendiente del NDK requerido; consulta `docs/ANDROID.md`.
