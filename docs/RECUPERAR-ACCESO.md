# Recuperar el acceso a CAPC

La recuperación funciona sin internet. Cada usuario puede generar su propio código desde una sesión abierta. Guarda el código en un lugar privado: permite elegir una contraseña nueva para esa cuenta.

## Preparar tu código

1. Inicia sesión y abre **Seguridad de mi cuenta** en la barra superior.
2. Escribe tu contraseña actual y genera el código de recuperación.
3. Guarda el código que aparece. Puedes copiarlo o guardarlo como archivo de texto. La aplicación conserva su huella, no el código visible.

Cada código se muestra al generarlo. Generar otro reemplaza el anterior. Si cambias la contraseña desde la administración de usuarios, genera también un código nuevo.

## Si olvidas la contraseña

1. En la pantalla de ingreso selecciona **Olvidé mi contraseña**.
2. Escribe tu usuario, el código guardado y una contraseña nueva de entre 10 y 256 caracteres. Repítela para comprobarla.
3. Confirma el restablecimiento e inicia sesión con tu contraseña nueva.
4. En **Seguridad de mi cuenta**, genera y guarda otro código: el utilizado ya no sirve.

El restablecimiento no cambia ventas, inventario ni clientes. Las sesiones anteriores se invalidan. Tras cinco códigos incorrectos se espera cinco minutos antes de volver a intentar la recuperación.

Si no tienes un código, otra cuenta propietaria puede cambiar tu contraseña desde **Usuarios y auditoría → Editar usuario**. Cuando se pierde el único acceso propietario, se necesita mantenimiento local autorizado con respaldo previo. No hay una contraseña universal ni se restablece el acceso con solo escribir un nombre de usuario.

## Configurar el nuevo acceso propietario

Después de preparar un cambio autorizado, CAPC muestra un formulario para elegir nombre, usuario y contraseña. Los datos del negocio y las referencias históricas se conservan. El cambio termina al guardar ese formulario; posteriormente aparece el código de recuperación para guardarlo.

La herramienta de mantenimiento `tools/reset_owner_access.py` exige CAPC cerrada, el propietario actual indicado expresamente y permisos de escritura sobre la base. Valida la integridad, genera un respaldo completo en `CAPC/local/respaldos_acceso`, invalida las sesiones y prepara una sola configuración. No borra la cuenta ni las operaciones y no asigna una contraseña temporal.

## Al restaurar un respaldo

Un respaldo recupera las contraseñas y el estado de los códigos vigentes cuando se creó. Un código consumido después de esa fecha podría volver a estar vigente al restaurarlo. Después de restaurar, inicia sesión con las credenciales de esa copia y genera un código nuevo.

Conserva el código separado de la contraseña y de las copias de la base; no lo compartas en mensajes de soporte.
