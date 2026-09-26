# Continuidad de CAPC MULTISERVICIO

Actualizado el 25 de septiembre de 2026. Proyecto canónico: `C:\Users\CAPC\capc_multi`.

## Alcance y autorización vigentes

Solicitud más reciente: descargar plantilla Excel e importar productos y servicios en lote; exportar datos de catálogo y otras secciones; crear un cliente desde Nueva venta conservando lo escrito. Se comprobó que los comprobantes con PDF e impresión ya estaban implementados y se conservaron.

La solicitud previa de apertura mostró una ventana negra. El proceso abierto en esta conversación (PID 26148, versión 0.2.3) sigue sin ventana visible y mantiene el mutex de instancia única. No afirmar que las funciones nuevas resolvieron ese fallo nativo ni volver a lanzar otra instancia mientras esté presente. Reiniciar Windows permite liberar esa instancia; falta verificar la ventana real de la nueva versión después.

Solicitud anterior: restablecer el acceso propietario para elegir un usuario nuevo y agregar recuperación de contraseña dentro de la app. Se conserva el negocio por defecto: no se autorizó borrar ventas, clientes o inventario. El cambio de acceso se prepara después de respaldo y se completa cuando el usuario escribe sus credenciales nuevas en la app; no se elige una contraseña por él.

Continúa el desarrollo Flutter desde IntelliJ y su terminal. La entrega actual es Windows, una empresa/caja local, funcionamiento sin internet y SQLite persistente. El plan general Android/VPS está en `docs/plan-desarrollo-capc.md`; no confundirlo con funcionalidades disponibles.

No instalar Microsoft Build Tools: la autorización anterior fue retirada. El equipo ya cuenta con Visual Studio Community 2026 Insiders y compila Windows con él. No se ha accedido al VPS ni se ha desplegado ningún servicio. No ejecutar la aplicación en Chrome como sustituto de SQLite FFI.

## Código disponible

- Versión del proyecto: `0.3.0+6`; esquema SQLite 2 con migración conservadora de v1.
- Usuarios locales propietario/administrador/cajero, contraseñas Argon2id, permisos en repositorio y revocación de sesión.
- Recuperación offline con código aleatorio de 256 bits, hash SHA-256, uso único, rotación y límite de intentos. «Olvidé mi contraseña» en ingreso y «Seguridad de mi cuenta» para generar/guardar código tras verificar contraseña actual. Alta/reconfiguración propietaria muestran el código al terminar.
- Materiales, servicios y recetas, inventario con movimientos, costo promedio y sugerencia de precio optativa.
- Ventas multilínea, efectivo/transferencia/tarjeta, crédito, abonos, cambio, devoluciones y anulaciones trazables.
- Compras y proveedores, recepción única, deuda y pagos; cotizaciones y trabajos con anticipos.
- Caja por turno, gastos, cierre y diferencias; reportes de ventas/costos/cobros, cartera y existencias.
- PDF Carta y 80 mm, vista previa, guardado y diálogo explícito de impresión.
- Respaldo consistente, restauración con copia previa y recuperación de inicio con credenciales del respaldo.

Las reglas y APIs vigentes están en `CONTRACT.md`. Los datos reales están fuera del ejecutable; Configuración muestra la ruta. Las pruebas usan bases temporales o memoria y no deben abrir la base del negocio.

## Excel y alta de cliente desde venta (0.3.0)

- `lib/services/spreadsheets.dart`: plantilla `.xlsx` con instrucciones y ejemplos separados, importación validada, exportación con datos tipados, filtros y encabezados fijos. Dependencias `excel_community`, `archive` y `xml`, compatibles con PDF/impresión existentes.
- `CapcRepository.importProducts`: una transacción para hasta 5000 altas nuevas, sin sobrescritura de códigos existentes. Conserva validaciones, autorización, costo, movimientos iniciales, eventos y auditoría. `sourceRows` conserva el número de fila original para errores.
- `lib/ui/spreadsheet_actions.dart`: selección local de archivo, lectura fuera del hilo de interfaz, vista previa y confirmación. Los errores cancelan todo el lote. Guardado `.xlsx` con cancelación y protección de archivos existentes.
- Exportación desde Inventario, Clientes y deudas, Historial y los diez Reportes. Las búsquedas y períodos indicados se respetan. Inventario, cartera y cuentas por pagar reflejan saldos actuales.
- Nueva venta: **Nuevo cliente** guarda y selecciona la cuenta creada sin perder carrito, abono, recibido ni vencimiento. Cancelar conserva el cliente anterior. Los comprobantes existentes siguen usando la vista previa/PDF/impresión habitual.
- Guía: `docs/EXCEL.md`, incluida también en la distribución. No se abrió ni modificó la base real durante estas mejoras.

## Verificación actual (0.3.0)

- `flutter analyze --no-pub`: sin observaciones.
- `flutter test --no-pub --dart-define=CAPC_UI_QA_DIR=output/qa/excel-ui --reporter expanded`: **157 pruebas aprobadas**. Incluyen 13 pruebas de importación transaccional, 23 de Excel/OOXML, 7 de flujo Excel y paginación, 3 de cliente en venta y 2 de tipos de datos de reportes.
- Revisión adicional con archivos OOXML independientes: se rechazan fórmulas con resultado almacenado vacío, se conservan códigos con ceros y formatos por secciones, se acotan combinaciones y dimensiones antes de decodificar.
- Capturas de pruebas temporales revisadas: `output/qa/excel-ui/13-excel-vista-previa.png`, `14-excel-producto-importado.png` y `12-cliente-seleccionado-en-venta.png`. También pasaron recorridos a 1000x700 con texto al 200%. Estas capturas no sustituyen la comprobación de la ventana nativa.
- Inventario muestra 50 registros por página; búsqueda y exportación utilizan todos los resultados filtrados. La prueba con 51 registros confirma exportación desde la segunda página y ajuste de página al cambiar los datos.
- Se repitieron las 3 pruebas de cliente tras ajustar el aviso de deuda para que reconozca al cliente seleccionado: aprobadas.
- `flutter build windows --release --no-pub`: correcto. Paquete final `dist/CAPC-MULTISERVICIO-0.3.0-20260925-235344-597`. `ABRIR_CAPC.cmd` y `dist/ultima-version.json` apuntan a él; las distribuciones anteriores se conservaron.
- SHA-256 del ZIP: `A7EBC770ABD156CA654ED90BB6F36408DE7223CC7C4D19B03EF024EBF574FAFD`.
- Verificados los 26 archivos del manifiesto tanto en la carpeta como dentro del ZIP, además de la huella del ZIP y la guía Excel incluida.
- **Pendiente nativo:** PID 26148 de la distribución 0.2.3 seguía vivo, sin ventana y con `Local\\CAPC_MULTISERVICIO_DESKTOP` presente. No se cerró forzosamente ni se repitieron lanzamientos. Reiniciar Windows antes de abrir la nueva distribución. No se corrigió ni se dio por resuelta la pantalla negra en este trabajo de Excel/clientes.

## Trabajo de esta continuación

Se añadió `lib/data/recovery.dart` con recuperación por código y configuración autorizada de nuevo acceso propietario. `tools/reset_owner_access.py` prepara el cambio solo con CAPC cerrada (mutex Windows), respaldo SQLite validado, control de cambios concurrentes y huella de las tablas del negocio. Invalida sesiones y marca el mismo ID propietario; no borra usuarios ni operaciones ni asigna clave temporal. La guía está en `docs/RECUPERAR-ACCESO.md`.

El marcador `owner_reconfiguration_user_id` no tiene una API de activación en la app. Su preparación exige mantenimiento autorizado sobre el archivo. Con marcador pendiente se bloquean ingreso/operaciones hasta completar el formulario. Contraseña, código y marcador se actualizan transaccionalmente; auditoría sin secretos. Restaurar respaldos antiguos restaura también sus contraseñas/códigos: generar un código nuevo al volver a ingresar.

Cambios de la entrega anterior:

Se corrigieron vencimientos omitidos en ventas con deuda, permisos de precios personalizados, dobles activaciones de formularios y recarga de módulos administrativos. Se completó la edición de cotizaciones en Borrador y se alinearon las acciones de estados/anticipos con las reglas del repositorio. Los trabajos ofrecen el estado actual y el siguiente; Entregado exige haber aplicado sus anticipos.

Los reportes PDF distinguen importe aplicado de efectivo recibido para dar cambio. El empaquetado comprueba versión, dependencias y antigüedad de compilación; crea una carpeta nueva, ZIP, manifiesto SHA-256, guías y `ABRIR_CAPC.cmd`. Se conservan los paquetes anteriores.

## Verificación anterior (0.2.3, revisión antes de abrir)

- Se corrigió `CapcRepository.open`: si falla la lectura de configuración o la auditoría inicial después de abrir SQLite, se cierra la conexión antes de propagar el error. Evita dejar el archivo bloqueado durante la recuperación de inicio.
- La nueva regresión en `test/core_backup_test.dart` reprodujo el fallo antes de corregirlo (`database is locked` y archivo en uso). Después comprueba la liberación de SQLite, la restauración desde una copia válida y la conservación del inventario, todo en una base temporal.
- `flutter analyze --no-pub`: sin problemas.
- `flutter test --no-pub --reporter expanded`: **109 pruebas aprobadas** tras la corrección. Las 2 pruebas Python de mantenimiento también pasaron; no se abrió ni modificó la base real durante esta revisión.
- `flutter build windows --release --no-pub`: correcto, versión `0.2.3+5`.
- Paquete actual: `dist/CAPC-MULTISERVICIO-0.2.3-20260925-212832-624`. `ABRIR_CAPC.cmd` y `dist/ultima-version.json` apuntan a esta versión; se conservaron las anteriores.
- SHA-256 del ZIP: `DBC5C368B15B542CDB8E90B4D1D60CD6850C36AAE49F3772F8EC619F00A3734A`. Verificados los 24 archivos del manifiesto en la carpeta y el ZIP, sus tamaños, dependencias y versión.
- Proyecto abierto en IntelliJ, con `lib/main.dart` seleccionado.
- **La aplicación continúa pendiente de apertura.** Se confirmó que Windows no se había reiniciado (último arranque 25/09/2026 18:44 Colombia). El PID 15952 conserva un hilo, no tiene ventana visible y mantiene presente el mutex `Local\\CAPC_MULTISERVICIO_DESKTOP`, aunque `HasExited` indica true. No se lanzó otra instancia ni se intentó terminarlo nuevamente. Reiniciar Windows y después abrir `ABRIR_CAPC.cmd`; la corrección de SQLite no demuestra resolver este bloqueo nativo previo a Dart. Falta verificar la ventana real tras reiniciar y completar las credenciales elegidas por el usuario.

## Verificación anterior (0.2.2)

- `flutter analyze --no-pub`: sin problemas.
- **108 pruebas Flutter aprobadas**: 89 de repositorio/documentos y 19 de interfaz. Incluyen recuperación, código de uso único, sesiones revocadas, reconfiguración preservando datos y ventana compacta con texto al 200%.
- **2 pruebas Python aprobadas** de `tools/test_reset_owner_access.py`: respaldo y conservación de datos, y rechazo/rollback del mantenimiento.
- Capturas de recuperación inspeccionadas en `build/qa-recovery`; usan bases temporales. El código mostrado usa Roboto incluido en la app.
- `flutter build windows --release --no-pub`: compilación correcta, versión `0.2.2+4`.
- Paquete de esa revisión: `dist/CAPC-MULTISERVICIO-0.2.2-20260925-203446-435`; conservado como versión anterior.
- SHA-256 del ZIP: `8AEACDCF4B556C92108399E98408EF7299A3C32EBAB4A68198F662E54D46DA18`. Verificados los 24 archivos del manifiesto en la carpeta y el ZIP.

## Estado del cambio de usuario en la base real

Preparación aplicada el 25 de septiembre de 2026 (20:36 Colombia). Base: `C:\Users\CAPC\AppData\Roaming\CAPC MULTISERVICIO\CAPC MULTISERVICIO\CAPC\local\capc.sqlite3`.

- Respaldo validado: `C:\Users\CAPC\AppData\Roaming\CAPC MULTISERVICIO\CAPC MULTISERVICIO\CAPC\local\respaldos_acceso\antes-nuevo-propietario-20260926T013659Z-017fcf82.sqlite3`.
- Marcador de nuevo propietario preparado sobre la cuenta anterior `capc`. No repetir el mantenimiento ni borrar la base: falta que el usuario complete el formulario con sus credenciales elegidas.
- Verificación posterior de integridad y huella de tablas: datos conservados; 1 producto, 1 cliente, 1 venta, 1 pago y 1 sesión de caja. Registro técnico sin contraseñas en `output/access-reset/preparacion.json`.
- **Apertura pendiente por bloqueo de Windows.** El proceso 15952 del nuevo EXE creó una ventana Flutter oculta y quedó detenido antes de cargar Dart/SQLite. No se consiguió presentar el formulario real. Tras solicitar cierre, `.HasExited` devolvió true, pero el proceso conservó un hilo y `WaitForSingleObject` devolvió 258 (timeout); un segundo `TerminateProcess` falló con error 5. No repetir intentos de lanzamiento ni modificar drivers. Se indicó reiniciar Windows, después abrir `ABRIR_CAPC.cmd` para configurar el nuevo propietario y guardar el código de recuperación. No se reinició el equipo automáticamente.
- Las pruebas y capturas de la interfaz son de bases temporales; no afirmar que el nuevo usuario real ya fue creado ni que la ventana quedó abierta.

## Verificación anterior (0.2.1)

- `flutter analyze --no-pub`: **sin problemas**, después de los cambios finales.
- **90 pruebas aprobadas**: 77 de datos/documentos en el pase general y 13 de interfaz en su pase final. El primer pase general detectó un getter incorrecto en una prueba UI; se corrigió y se ejecutó todo `test/ui_flow_test.dart` satisfactoriamente.
- Dos recorridos UI se repitieron con capturas: edición de cotización y anticipos vinculados; ambos aprobados. Se inspeccionaron `06-editar-cotizacion.png` y `07-trabajo-con-anticipo.png`.
- PDF: **8 documentos, 42 páginas** renderizadas con texto y numeración verificados. Se inspeccionaron el reporte vacío, todas las páginas del reporte largo en su vista conjunta y la tirilla habitual. Informe: `output/qa/rendered/verification.json`.
- Los tests de interfaz incluyen ventana 1000 x 700 y texto al 200%; no equivalen a un piloto con datos reales ni a pruebas de la impresora física.
- `flutter build windows --release --no-pub`: **compilación correcta**, versión `0.2.1+3`.
- Paquete anterior conservado en `dist/CAPC-MULTISERVICIO-0.2.1-20260925-193056-250` y ZIP con el mismo nombre.
- SHA-256 del ZIP: `110AA1B111D5452A2C9C1A803616176F56CF93CCF08DD3A72E19BCAEB5A90BDF`. Se cotejaron las huellas del manifiesto tanto en la carpeta como en el contenido comprimido.

Comandos de verificación desde la raíz:

```powershell
flutter analyze --no-pub
$env:CAPC_UI_QA_DIR = 'output/qa/ui'
$env:CAPC_PDF_QA_DIR = 'output/qa/pdf'
flutter test --no-pub --reporter expanded
python tools/verify_pdfs.py
flutter build windows --release
powershell -NoProfile -ExecutionPolicy Bypass -File tools/package-windows.ps1
```

Evidencia visual: `output/qa/ui` y `output/qa/rendered`. Las dependencias de renderizado Python ya están en `.qa-python`. Flutter instalado en `C:\Users\CAPC\flutter\bin\flutter.bat`; `tools/windows.ps1` usa el SDK instalado antes de una copia local.

## Abrir y distribuir

`ABRIR_CAPC.cmd` abre el último paquete terminado. `dist/ultima-version.json` contiene versión, ruta del ejecutable, ZIP y SHA-256. Distribuir la carpeta completa o el ZIP, nunca solo el EXE. Documentación de uso: `docs/ABRIR-Y-RESPALDAR.md` y `docs/GUIA-OPERACION.md`.

## Pendientes para el alcance completo

1. **Piloto local:** validar el turno real completo y la recuperación en otro equipo Windows; todavía no se afirma esa validación física.
2. **Impresora USB:** falta marca/modelo/ancho y prueba real de controlador, márgenes, documentos largos y corte si corresponde.
3. **Distribución:** paquete portable disponible; instalador firmado y actualización automática aún no implementados.
4. **Android y sincronización:** no publicados ni conectados. Requieren API, autenticación remota, aislamiento por negocio, asignación de existencias/cobranza offline y pruebas entre equipos.
5. **VPS:** revisar recursos y acceso autorizado antes de cualquier despliegue. No instalar Supabase completo por defecto ni modificar aplicaciones PM2 existentes.
6. **Funciones del plan futuro:** adjuntos de trabajos, configuración comercial ampliada y exportación de datos fuera de PDF deben definirse e implementarse en su etapa.

No hay facturación electrónica ni cifrado integral del archivo SQLite. El avance se informa por funcionalidades y evidencia, sin asignar un porcentaje global que incluya tareas todavía no construidas o probadas.
