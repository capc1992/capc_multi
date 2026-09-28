# Privacidad y eliminación de cuenta

CAPC MULTISERVICIO incluye dos rutas públicas servidas por la API:

- `GET /privacidad`: política de privacidad HTML, adaptable y sin recursos externos.
- `GET /eliminar-cuenta`: formulario de eliminación accesible aun después de desinstalar la aplicación.

La aplicación enlaza ambas rutas desde `Configuración > Conexión remota y dispositivos`. Una cuenta conectada muestra además `Eliminar cuenta remota`.

## Garantías del flujo

1. La persona confirma el correo y la contraseña remotos y escribe `ELIMINAR`.
2. El servidor limita intentos y no revela si el correo existe.
3. PostgreSQL toma un bloqueo por negocio y borra en una transacción la identidad, dispositivos, sesiones, tokens, códigos, auditoría y datos sincronizados.
4. Las operaciones nuevas se rechazan si el negocio ya no existe, incluso si una solicitud de sincronización estaba en curso.
5. La aplicación elimina la credencial guardada en Keystore o Credential Manager después de recibir confirmación.
6. SQLite local se conserva. Es la base offline del dispositivo, no la cuenta remota, y puede contener registros que el propietario deba conservar por obligaciones contables.

El formulario web permite omitir el identificador del negocio cuando el correo y la contraseña identifican una sola cuenta. Si las mismas credenciales administran varias, exige el ID para evitar borrar el negocio equivocado.

## Antes de Google Play

- desplegar la API y verificar ambas páginas mediante HTTPS público;
- verificar que `nicolasperdomoliz@gmail.com` reciba correctamente las consultas de privacidad;
- completar la sección Seguridad de los datos y registrar la URL de eliminación en Play Console;
- revisar la política con asesoría legal según los datos y obligaciones reales del negocio;
- probar eliminación desde la app y desde la web contra un negocio ficticio, nunca contra la base real.
