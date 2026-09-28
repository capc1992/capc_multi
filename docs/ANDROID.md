# Android offline de CAPC MULTISERVICIO

Esta rama adapta la versión Windows `0.3.0+6` para ejecutar la misma lógica local en Android. La sincronización continúa siendo opcional: sin configuración remota Android trabaja completamente local. La API de producción está desplegada en `https://api.capcmultiservicios.site`; todavía falta generar y publicar una compilación Android firmada que active esa URL. No se añadió Firebase ni se publicó en Google Play.

## Arquitectura

La aplicación conserva una sola instancia de `CapcRepository` como frontera transaccional y de autorización. Productos, recetas, inventario, ventas, pagos, devoluciones, clientes, compras, proveedores, cotizaciones, trabajos, caja, usuarios, reportes, auditoría, `business_id`, `device_id`, `operation_id` y `outbox` siguen en los mismos archivos y tablas.

`lib/platform/platform_services.dart` define la frontera de plataforma:

- driver de base local;
- ubicación privada y temporal;
- selección y exportación de documentos;
- impresión y compartir PDF;
- información descriptiva del dispositivo.

`lib/platform/platform_factory_io.dart` es el único selector de sistema operativo. El código de negocio y la interfaz no reparten comprobaciones `Platform.isAndroid`.

## Archivos compartidos

- `lib/data/repository.dart`, `operations.dart`, `recovery.dart` y modelos: esquema, migraciones, transacciones, autorización e idempotencia.
- `lib/services/spreadsheets.dart`: lectura y escritura OOXML, incluidos códigos con ceros iniciales.
- `lib/services/documents.dart` y `reporting.dart`: PDF Carta y tirilla de 80 mm, sin acceso a red.
- `lib/services/backup_transfer.dart`: prepara copias consistentes y materializa respaldos seleccionados en almacenamiento temporal privado.
- `lib/ui/`: los mismos flujos funcionales, con navegación lateral en escritorio y menú móvil en pantallas estrechas.

## Implementaciones por plataforma

### Windows

`platform_windows.dart` mantiene `CAPC_DATA_DIR` para pruebas aisladas, usa el selector nativo de archivos, el diálogo moderno de impresión y rutas sin distinción entre mayúsculas y minúsculas. El mutex de instancia única continúa exclusivamente en `windows/runner/main.cpp`.

### Android

`platform_android.dart` usa el directorio de soporte privado de la aplicación y el selector de documentos del sistema para importar. `MainActivity.kt` implementa exportación con `ACTION_CREATE_DOCUMENT`; Android decide el destino y solicita confirmación antes de reemplazar un documento. No se solicita acceso general a los archivos del teléfono.

Windows y Android usan `sqflite_common_ffi` con SQLite incluido por `sqlite3`. Esto conserva el mismo SQL, esquema 2, migración v1 a v2, WAL, claves foráneas y límites transaccionales. El driver está detrás de `LocalDatabaseDriver` para poder cambiar la implementación sin duplicar reglas de negocio.

## Base local Android

La ruta se calcula como:

```text
getApplicationSupportDirectory()/CAPC/local/capc.sqlite3
```

Es almacenamiento privado de la aplicación. La ruta exacta se muestra en Configuración. Desinstalar la aplicación puede eliminar ese almacenamiento; por eso deben exportarse respaldos periódicos mediante el selector de documentos.

La operación es completamente local. Una venta, su pago, el movimiento de existencias, auditoría, `operation_id` y evento de outbox se guardan en una misma transacción. Los reintentos con el mismo identificador son idempotentes y los botones mantienen protección contra doble toque.

## Estado offline

Sin URL remota la interfaz muestra **Guardado en este dispositivo**, el motor queda en `local_only` y no transmite eventos. El esquema 3 conserva outbox, inbox y cursor para una conexión futura. “Sincronizado” solo será válido después de un ciclo push/pull confirmado.

## Respaldos y Excel

- Exportar respaldo crea primero una instantánea SQLite coherente y validada en almacenamiento temporal privado; después abre `ACTION_CREATE_DOCUMENT`.
- Restaurar usa el selector del sistema, copia el documento elegido al área temporal privada, valida integridad, esquema y referencias, y conserva una copia de los datos actuales antes de reemplazarlos.
- Importar y exportar Excel usa el selector del sistema y el mismo lector/escritor compartido. Los identificadores y códigos con ceros iniciales permanecen como texto.
- Cancelar el selector no construye ni escribe el archivo. Windows conserva además la confirmación explícita si debe añadir una extensión que ya existe.

## PDF, compartir e impresión

La vista previa y la generación de PDF son compartidas. Se mantienen Carta y tirilla de 80 mm. Android ofrece Guardar PDF, Compartir PDF y el diálogo de impresión del sistema; ninguna acción envía documentos automáticamente.

Android no accede directamente a la impresora USB conectada al computador Windows. Esa integración requeriría un servicio posterior y conectividad; no forma parte de esta etapa.

## Verificación y limitaciones actuales

Las pruebas automatizadas usan bases temporales o `:memory:`. Incluyen una ejecución con el adaptador Android para persistencia, venta offline, idempotencia, stock, deuda, abonos, outbox, respaldo y navegación móvil. Las suites existentes conservan migraciones, compras, recepción única, cotizaciones, caja, Excel, PDF y comportamiento Windows.

La compilación de comprobación `flutter build apk --debug --no-pub` fue aprobada con NDK `28.2.13676358`. El artefacto local se genera en `build/app/outputs/flutter-apk/app-debug.apk`. Esto valida el ensamblado Android, pero todavía no equivale a una prueba de instalación, persistencia, selector de documentos o impresión en un teléfono físico.

## Pendiente para etapas posteriores

- probar apertura, persistencia, selector, restauración, compartir e impresión en un dispositivo Android real;
- definir el identificador definitivo de aplicación, firma e iconos, y desplegar públicamente la política de privacidad ya implementada;
- completar autenticación remota, almacenamiento seguro de tokens, materializadores y piloto PostgreSQL/VPS;
- probar sincronización entre equipos antes de mostrar “Sincronizado”;
- preparar pruebas cerradas y publicación en Play Console solo con autorización posterior.

## Privacidad y eliminación de cuenta

`Configuración > Conexión remota y dispositivos` ofrece la política de privacidad, el recurso web externo y, cuando hay una identidad conectada, `Eliminar cuenta remota`. La eliminación exige correo, contraseña remota y escribir `ELIMINAR`; borra la identidad y los datos sincronizados del servidor y limpia la credencial segura del dispositivo. No elimina silenciosamente SQLite local.

Las URL que deben permanecer públicas y registrarse en Play Console son:

- `https://api.capcmultiservicios.site/privacidad`
- `https://api.capcmultiservicios.site/eliminar-cuenta`

Ambas URL están públicas mediante HTTPS desde el 28 de septiembre de 2026 y pueden registrarse en Play Console.
