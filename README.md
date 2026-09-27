# CAPC MULTISERVICIO

Aplicación Flutter en español con operación local SQLite. Windows `0.3.0` es la base estable; la rama Android comparte la misma lógica y prepara funcionamiento offline sin servidor. Esta carpeta es el proyecto canónico; la plantilla anterior está archivada en `migration/flutter-template`.

Consulta [CONTINUAR_AQUI.md](CONTINUAR_AQUI.md) para resultados de verificación, [CONTRACT.md](CONTRACT.md) para reglas técnicas y [el plan](docs/plan-desarrollo-capc.md) para alcance y límites.

La arquitectura y el estado comprobado de la adaptación móvil están en [Android offline](docs/ANDROID.md).

## Abrir

Para usar el programa compilado, abre `ABRIR_CAPC.cmd`. Consulta [la guía de operación](docs/GUIA-OPERACION.md) y [las instrucciones de respaldo](docs/ABRIR-Y-RESPALDAR.md).

Para desarrollar con Flutter desde IntelliJ o terminal, trabaja en `C:\Users\CAPC\capc_multi`:

```powershell
flutter pub get
flutter run -d windows
```

También: `powershell -ExecutionPolicy Bypass -File tools/windows.ps1 run`.

El ejecutable compilado se ubica en `build/windows/x64/runner/Release/capc_multi.exe`. Distribuir la carpeta Release completa (DLL, fuentes, datos Flutter y SQLite), nunca solo el EXE. Consulta el estado real de compilación en CONTINUAR_AQUI.md.

Para comprobar Android durante el desarrollo:

```powershell
flutter build apk --debug
```

La aplicación Android usa almacenamiento privado y el selector de documentos del sistema; no solicita acceso general a todos los archivos. Consulta `docs/ANDROID.md` antes de interpretar una compilación como una publicación o una prueba física terminada.

## Primer uso

1. Crear la cuenta propietaria con nombre, usuario y contraseña propia de al menos 10 caracteres. No existen credenciales predeterminadas.
2. Registrar productos, materiales, servicios y clientes. Los códigos son únicos sin distinguir mayúsculas. El stock inicial registra movimiento y costo.
3. Configurar Materiales del servicio cuando una prestación consuma inventario. Las cantidades son enteras.
4. Abrir Caja indicando efectivo inicial. Las ventas y operaciones monetarias requieren caja abierta.
5. Agregar conceptos a Nueva venta. Si queda deuda, seleccionar cliente y vencimiento. Distinguir recibido, importe aplicado y cambio; solo el efectivo permite cambio.
6. Confirmar. El comprobante queda en Historial con vista previa, Guardar PDF e Imprimir mediante diálogo de Windows.
7. Registrar abonos desde Clientes y deudas; cerrar caja con el efectivo contado. Cerrar y reabrir la aplicación conserva las operaciones; se vuelve a iniciar sesión.

El catálogo de ejemplo es opcional y exige catálogo vacío. No crea ventas ficticias.

## Excel y carga de catálogo

Inventario permite **Descargar plantilla Excel**, **Importar Excel** y **Exportar Excel**. La importación `.xlsx` valida hasta 5.000 productos y servicios nuevos antes de confirmar y guarda el lote completo en una sola transacción. Los códigos existentes no se sobrescriben. Clientes, Historial y Reportes también permiten exportar Excel con importes numéricos. Consulta [la guía de Excel](docs/EXCEL.md).

En Nueva venta, **Nuevo cliente** abre el formulario y selecciona al cliente guardado sin perder la venta en curso. Los comprobantes PDF e impresión existentes siguen disponibles.

## Costos, compras y precios

Registrar proveedor, referencia, cantidades y costo unitario o total del lote mayorista. La compra aumenta inventario solo al recibir materiales, una sola vez. Admite crédito con vencimiento y pagos parciales.

Las recepciones actualizan el costo promedio ponderado. La valoración interna usa enteros en millonésimas de peso: $100 por tres unidades conserva exactamente $100, con el residuo asignado al consumir la última unidad.

El usuario escribe el porcentaje sobre costo para sugerir precio. Puede aceptar la sugerencia o escribir un precio manual. No hay porcentaje preestablecido ni cambios automáticos del precio de venta al comprar. Editar costo de referencia no revalúa el inventario existente.

Cada venta conserva nombres, precios y costos históricos. Los servicios suman materiales y costo directo adicional. Costos desconocidos o históricos declarados impiden presentar utilidad completa.

## Operación

- Clientes/proveedores: búsqueda, abonos sin sobrepago, vencimientos, saldos e historial; estados de cuenta imprimibles.
- Cotizaciones: conceptos de catálogo o personalizados, condiciones y vigencia; edición mientras están en Borrador, sin cobro ni stock. Los conceptos personalizados requieren permiso de precios. Se aceptan durante su vigencia y luego conservan sus condiciones hasta su conversión única.
- Trabajos: Recibido, En proceso, Listo y Entregado, responsable y fecha prevista. Anticipos aplicados sin un segundo cobro. Si hay cotización vinculada, debe estar aceptada para recibir anticipos.
- Anulaciones/devoluciones: permiso y motivo obligatorios, original conservado y compensaciones. Solo se reponen materiales recuperables declarados; devolver dinero por un servicio realizado no recupera automáticamente insumos.
- Caja: apertura, movimientos, gastos, cierre, esperado/contado y diferencia. Transferencia/tarjeta se separan del efectivo.
- Reportes: ventas, cobros, compras/proveedores, gastos/flujo, inventario, cartera, caja y productos más vendidos. Las compensaciones afectan su fecha; ventas, cobros y utilidad bruta se distinguen.

## Usuarios, datos y respaldo

Propietario: control completo, usuarios y restauración. Administrador: operación, catálogo, compras, precios, compensaciones y reportes. Cajero: ventas, cobros, clientes, cotizaciones, trabajos y caja propia. Los permisos se comprueban también en el repositorio.

Contraseñas con Argon2id y sal aleatoria. La base y respaldos contienen información privada y dependen también de los permisos de Windows; no se afirma cifrado completo del archivo SQLite.

La pantalla de ingreso incluye **Olvidé mi contraseña**. Requiere el código de recuperación de un solo uso generado desde **Seguridad de mi cuenta**, previa verificación de la contraseña actual. Al crear o reconfigurar el propietario se ofrece guardar ese código. Consulta [Recuperar acceso](docs/RECUPERAR-ACCESO.md).

Configuración muestra la ruta exacta. Los datos viven bajo la carpeta de aplicación del usuario en `CAPC/local/capc.sqlite3`, fuera del ejecutable. `CAPC_DATA_DIR` permite pruebas aisladas; dentro se crea `CAPC/local`.

Guardar respaldos desde Configuración. Restaurar valida una copia temporal, conserva una copia previa y cierra conexiones antes del reemplazo. La recuperación desde el error de inicio exige la cuenta propietaria y contraseña del respaldo. Conservar copias también fuera del disco del equipo.

## Verificación

```powershell
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release
powershell -ExecutionPolicy Bypass -File tools/package-windows.ps1
```

Para revisión visual, definir `CAPC_UI_QA_DIR=output/qa/ui` y `CAPC_PDF_QA_DIR=output/qa/pdf` antes de las pruebas. `tools/verify_pdfs.py` renderiza todas las páginas y verifica texto, dimensiones y paginación. Sus dependencias se instalan dentro del proyecto con `python -m pip install --target .qa-python pypdfium2 pillow pypdf`.

El empaquetado comprueba la versión, las dependencias y que no haya código Dart más reciente que la compilación. Genera carpeta y ZIP nuevos en `dist`, con manifiesto SHA-256, guías y acceso `ABRIR_CAPC.cmd`. `dist/ultima-version.json` identifica el paquete actual. Las versiones anteriores se conservan.

## Límites

Una empresa y caja local activas. Negocio/dispositivo y eventos locales preparan una evolución futura: no existe sincronización Android/VPS ni se accedió al servidor. No se usa Chrome como sustituto.

Se detectó Visual Studio Community 2026 Insiders y se activó el modo de desarrollador Windows. No se instaló Microsoft Build Tools; su instalación separada continúa pendiente.

Comprobantes internos sin validez fiscal. Carta y 80 mm con vista previa y paginación; compatibilidad USB, corte y controlador requieren probar la impresora real. Impresión siempre solicitada por el usuario.
