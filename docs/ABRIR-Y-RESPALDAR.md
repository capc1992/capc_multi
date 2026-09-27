# Abrir CAPC MULTISERVICIO en Windows

En este equipo, abre `C:\Users\CAPC\capc_multi\ABRIR_CAPC.cmd` con doble clic. Este acceso apunta a la última versión empaquetada. También puedes abrir `capc_multi.exe` dentro de la carpeta de distribución.

`dist/ultima-version.json` identifica la versión actual y su ZIP. En el paquete se incluyen `GUIA-OPERACION.md` con los recorridos de trabajo y `SHA256.csv` con las huellas de los archivos.

Si CAPC ya está abierta, guarda o termina el formulario actual y cierra su ventana antes de abrir una versión nueva. Solo se permite una instancia por sesión de Windows. No hace falta ejecutar Flutter para usar la carpeta compilada.

## Primera vez

1. Crea tu cuenta propietaria y contraseña propia (mínimo 10 caracteres). No existe una contraseña predeterminada.
   Al crearla se muestra un código de recuperación: guárdalo antes de continuar. Sirve una vez para elegir una contraseña nueva desde **Olvidé mi contraseña**.
2. Registra los productos, materiales, servicios y clientes. El catálogo de ejemplo es opcional y no genera ventas.
3. Abre Caja con el efectivo inicial. Registra la venta, selecciona cliente y vencimiento si queda deuda y confirma.
4. Desde el comprobante puedes ver, guardar PDF o abrir el diálogo de impresión. Selecciona Carta o tirilla de 80 mm según tu impresora.
5. Registra los abonos y cierra Caja con el efectivo contado al terminar. Al volver a abrir, inicia sesión para consultar tus datos.

## Datos y actualizaciones

Configuración muestra la ubicación exacta de la base SQLite. Los datos se guardan en la carpeta de aplicación de tu usuario de Windows, bajo `CAPC/local/capc.sqlite3`, fuera del ejecutable. Abrir una nueva versión desde otra carpeta en el mismo equipo y con el mismo usuario utiliza esos datos.

No copies únicamente el EXE: necesita las DLL y la carpeta `data` que lo acompañan. El ZIP contiene el programa, no contiene tus ventas ni sustituye un respaldo. La ejecución en otro equipo Windows requiere comprobar los componentes de ejecución de Microsoft y la impresora de ese equipo; todavía no se ha validado ese traslado.

## Respaldo y recuperación

Guarda un respaldo desde Configuración con la cuenta propietaria y conserva otra copia en un medio distinto al disco del computador. Hazlo también antes de actualizar.

Para restaurar, selecciona el respaldo desde Configuración. La aplicación lo valida y conserva una copia previa antes del reemplazo. Inicia sesión de nuevo con las credenciales que estaban vigentes en ese respaldo. La restauración recupera el estado de esa copia; no mezcla automáticamente las operaciones posteriores.

Si una base dañada impide abrir CAPC, la pantalla de recuperación permite seleccionar un respaldo y verificar la cuenta propietaria del respaldo. Conserva los archivos anteriores para recuperación.

Para una contraseña olvidada utiliza el código guardado, no la restauración de toda la base. Consulta **RECUPERAR-ACCESO.md**. Después de restaurar una base, genera un código nuevo porque se recupera también el estado de las credenciales de la copia.

## Impresión y alcance

Los documentos son comprobantes internos, sin validez fiscal. Guardar el PDF es independiente de confirmar la venta. Imprimir siempre abre un diálogo; no envía trabajos automáticamente.

Antes de usar la impresora USB en la operación diaria, prueba su modelo real: controlador, márgenes, acentos, Carta o 80 mm, documentos largos y corte si el equipo lo admite. La compatibilidad física sigue pendiente de esa prueba.

Esta versión trabaja sin internet en un negocio/caja local. Android, conexión al VPS y sincronización entre dispositivos todavía no están disponibles.
# Instalar en dos o más equipos

El archivo `CAPC-MULTISERVICIO-0.4.0-....zip` es el paquete portable instalable. Copia el ZIP completo a cada equipo, verifica su archivo `.sha256`, extráelo en una carpeta propia y ejecuta `capc_multi.exe`. No copies únicamente el EXE: las DLL y la carpeta `data` son obligatorias.

Cada equipo crea su propia base SQLite y guarda las credenciales remotas en Windows Credential Manager. El ZIP no contiene datos, contraseñas ni tokens. Sin una compilación con `CAPC_SYNC_URL`, los equipos funcionan separados y completamente offline; copiar el programa no sincroniza bases. Para compartir un negocio remoto, el primer equipo debe generar un código temporal y el segundo debe estar nuevo o sin movimientos. Una base con movimientos requiere respaldo y migración explícita.

## Instalador de Windows

`CAPC-MULTISERVICIO-Setup-0.4.0.exe` instala la aplicación para el usuario actual, crea una entrada en el menú Inicio, ofrece un acceso directo de escritorio y registra un desinstalador en Configuración de Windows. La instalación y la desinstalación no incluyen ni eliminan la base SQLite del negocio, que vive fuera de la carpeta del programa.

El instalador aún no tiene firma comercial. Verifica primero el archivo `.sha256`; Windows puede mostrar una advertencia de SmartScreen aunque la huella sea correcta. No desactives el antivirus ni descargues copias desde ubicaciones distintas a la entrega controlada.

Ejecuta el mismo instalador en cada computador. Mientras `CAPC_SYNC_URL` continúe desactivada, ambos equipos funcionan offline con bases independientes; instalar la aplicación no activa por sí solo la sincronización.
