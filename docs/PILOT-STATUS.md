# Estado del piloto CAPC

Actualizado el 27 de octubre de 2026.

## Instalacion y publicacion completadas

- Commit instalado: `a3f9d5f` de `feature/cross-platform-updates`.
- Clon aislado: `/opt/capc-sync-pilot/repository`.
- Proceso: `capc-sync-pilot`, administrado por PM2 y guardado para reinicio.
- API privada: `http://127.0.0.1:3101`.
- API publica: `https://api-test.capcmultiservicios.site`.
- Nginx redirige HTTP a HTTPS.
- Certificado Let's Encrypt valido hasta el 7 de enero de 2027, con renovacion
  automatica configurada por Certbot.
- Base y usuario exclusivos: `capc_sync_pilot`.
- Migraciones comprobadas: 001, 002, 003, 004 y 005.
- Entorno: `/etc/capc-sync-pilot/capc-sync.env`, propietario root y modo 0600.
- Respaldo: `/var/backups/capc-sync-pilot`, con tarea diaria a las 03:40.
- Restauracion de ensayo completada en una base temporal y eliminada despues.
- Typecheck, 26 pruebas unitarias y build del servidor aprobados.

Produccion continuo respondiendo en `127.0.0.1:3100` y en
`https://api.capcmultiservicios.site/health`. PostgreSQL permanecio ligado a
localhost. No se modifico la base, el proceso PM2 ni Nginx de produccion.

## Validacion publica

El registro A de `api-test.capcmultiservicios.site` apunta a `2.25.80.190`. Se
comprobaron desde Internet la respuesta HTTPS y la redireccion HTTP 301. Tambien
respondieron correctamente `/privacidad` y `/eliminar-cuenta`.

El proceso Node y PostgreSQL conservan sus enlaces privados a localhost; solo
Nginx publica el servicio mediante los puertos 80/443.

La contrasena root compartida durante la operacion debe cambiarse desde un canal
seguro. No se guardo en el repositorio ni en archivos del piloto.

## Pausa del 9 de octubre de 2026

El usuario pidio pausar antes de compilar los clientes del piloto. Se interrumpio
el comando local de analisis/pruebas antes de recibir su resultado. No se inicio
la compilacion de Windows ni Android y no se instalaron clientes en los equipos.

Al continuar:

1. Ejecutar `flutter analyze --no-pub` y `flutter test --no-pub`.
2. Compilar Windows release con
   `CAPC_SYNC_URL=https://api-test.capcmultiservicios.site`.
3. Compilar el APK Android debug con la misma URL.
4. Crear artefactos identificados expresamente como piloto sin reemplazar el
   lanzador normal ni instalar sobre las bases reales.
5. Probar con `CAPC_DATA_DIR` aislado, datos ficticios y la matriz de
   `docs/VALIDACION-OFFLINE-FIRST.md`.

La rotacion de la contrasena root compartida sigue siendo una tarea urgente y no
debe posponerse al comenzar la proxima sesion.

## Reanudacion del 27 de octubre de 2026

Se completaron los pasos locales previos al piloto fisico:

- `flutter analyze --no-pub` termino sin observaciones.
- Las 207 pruebas Flutter fueron aprobadas.
- Windows release y Android debug compilaron con
  `CAPC_SYNC_URL=https://api-test.capcmultiservicios.site` y
  `CAPC_CREDENTIAL_NAMESPACE=pilot-2026-10`.
- Se comprobo que el snapshot Windows contiene la URL y el espacio de
  credenciales del piloto, y que el ejecutable corresponde a `0.4.1+8`.
- La clave segura de las compilaciones normales permanece sin cambios. El
  piloto usa una clave separada y un lanzador que fija `CAPC_DATA_DIR` en su
  propio directorio `DATOS-PILOTO`.
- El paquete incluye la carpeta Windows completa, el APK debug, instrucciones,
  metadatos y manifiesto SHA-256. No contiene bases SQLite.

Artefacto local:

`dist/CAPC-PILOTO-AISLADO-0.4.1-8-20261027-194555-709.zip`

SHA-256:

`BCC6D71FED54E21BE66257F9C58886EACC5787D1D673C1BB29BD7D8B61672E64`

El intento anterior se conservo, incluida su base ficticia, en
`dist/CAPC-PILOTO-INTENTO-ANTERIOR-0.4.1-8-20261027-182921-128`. No se modifico
la credencial segura normal de Windows. El paquete nuevo no se instalo ni se
ejecuto sobre los equipos. El siguiente paso es extraerlo en una carpeta nueva
del primer equipo Windows, abrir exclusivamente `ABRIR-CAPC-PILOTO.cmd`,
conectar el negocio antes de crear movimientos y comenzar la matriz con un
segundo Windows y un Android. El APK es de depuracion y no es publicable.

## Pausa solicitada el 27 de octubre de 2026

El usuario debio salir y solicito detener y guardar. No quedaron procesos Dart,
Flutter ni CAPC iniciados por esta tarea. El codigo, la documentacion, el
empaquetador y el artefacto aislado permanecen guardados localmente, sin commit
ni push. No se abrio el paquete nuevo ni se modificaron las bases reales.

Antes de la pausa se amplio la regresion para comprobar con almacenamiento
seguro simulado que limpiar la sesion `pilot-2026-10` conserva la credencial
normal. La ejecucion de esa ultima prueba fue cancelada al solicitar la pausa,
por lo que debe repetirse al continuar. El analisis habia quedado limpio y la
suite completa de 207 pruebas habia aprobado antes de ampliar esa asercion. El
codigo de aplicacion no cambio despues de compilar y auditar el ZIP aislado.

Al continuar:

1. Ejecutar `flutter test --no-pub test/sync_identity_test.dart -r expanded`.
2. Ejecutar `flutter analyze --no-pub` y, para el cierre final, la suite Flutter
   completa.
3. Revisar `git diff --check` y conservar el paquete aislado ya generado si las
   validaciones terminan verdes.
4. Solo entonces extraer el ZIP en una carpeta nueva y conectar el negocio
   piloto antes de crear movimientos.

## Cierre local del 27 de octubre de 2026

Se completaron las validaciones que habian quedado pendientes durante la pausa:

- La regresion de identidad remota aprobo sus 13 pruebas, incluida la
  comprobacion de que limpiar la credencial `pilot-2026-10` conserva la
  credencial normal.
- `flutter analyze --no-pub` termino sin observaciones. La demora del primer
  intento provenia de cuatro procesos Dart residuales de la ejecucion
  interrumpida; despues de cerrarlos, el analisis termino normalmente.
- La suite Flutter completa aprobo sus 207 pruebas.
- `git diff --check` no encontro errores.
- El ZIP conservo el SHA-256 documentado. Las 30 entradas de `SHA256.csv`
  coincidieron en hash y tamano, no se encontraron bases SQLite, y el snapshot
  de Windows contiene la URL del servidor piloto y el espacio de credenciales
  `pilot-2026-10`.

No fue necesario recompilar ni reemplazar el paquete. Tampoco se extrajo,
instalo, ejecuto, publico ni copio a equipos reales. El siguiente hito sigue
siendo el piloto fisico descrito en la seccion anterior.

## Inicio del piloto fisico del 28 de octubre de 2026

- Los commits `be719f5` y `76f7600` se publicaron en
  `feature/cross-platform-updates`; el workflow `Cloud Sync Identity` aprobo
  PostgreSQL, Windows y Android para `76f7600`.
- Se corrigieron las alertas de dependencias de produccion que bloquearon el
  primer intento de CI. `npm audit --omit=dev` termino con cero
  vulnerabilidades.
- El ZIP auditado se extrajo en una carpeta nueva del Escritorio y se abrio
  exclusivamente mediante `ABRIR-CAPC-PILOTO.cmd`.
- La base creada quedo dentro de `DATOS-PILOTO`; la ubicacion normal de datos no
  recibio modificaciones durante la apertura.
- Se creo el propietario local ficticio y se comprobo el ingreso posterior.
  Todavia no se creo el negocio remoto ni se vinculo el segundo equipo.
- La prueba manual descubrio que el acceso superior con el texto
  `Conecta el negocio para sincronizar` estaba deshabilitado antes de conectar.
  La ruta `Configuracion > Conexion remota y dispositivos` sigue disponible.
  Se preparo una correccion con regresion automatizada; debe validarse,
  recompilarse y generar un paquete piloto nuevo antes de continuar la prueba
  fisica.

No se usaron datos reales, no se copio el paquete al equipo del local y no se
instalo el APK Android.

## Paquete corregido del 28 de octubre de 2026

- El commit `2e58ecf` quedo publicado en `feature/cross-platform-updates` y el
  workflow `Cloud Sync Identity` aprobo PostgreSQL, Windows y Android.
- `flutter analyze --no-pub` termino sin observaciones, las 208 pruebas Flutter
  aprobaron y las 6 pruebas del empaquetador aprobaron.
- Se recompilaron Windows release y Android debug con
  `CAPC_SYNC_URL=https://api-test.capcmultiservicios.site` y
  `CAPC_CREDENTIAL_NAMESPACE=pilot-2026-10`.
- Se genero el paquete corregido
  `dist/CAPC-PILOTO-AISLADO-0.4.1-8-20261028-144622-179.zip` con SHA-256
  `966ED753805D1398ECFFD2122F8FF735D1CD0C91C83578D8D47962BC2420544E`.
- Las 30 entradas del manifiesto coincidieron en hash y tamano. El paquete
  contiene el lanzador y el APK esperado, y no contiene bases SQLite.
- El ZIP se extrajo en una carpeta nueva del Escritorio:
  `C:\Users\CAPC\Desktop\CAPC-PILOTO-CORREGIDO-20261028\CAPC-PILOTO-AISLADO-0.4.1-8-20261028-144622-179`.
  La carpeta del intento anterior permanece intacta.
- El cliente corregido se abrio mediante `ABRIR-CAPC-PILOTO.cmd` y quedo en la
  creacion del primer propietario. Aun no se ha creado el negocio remoto, no se
  ha vinculado el segundo Windows y no se ha instalado el APK Android.

## Vinculacion inicial del piloto corregido

- Se creo un propietario local ficticio en el Windows de desarrollo. Su base
  aislada conserva un usuario, cero productos, cero ventas y cero operaciones
  pendientes.
- El Windows de desarrollo quedo conectado y sincronizado con el negocio
  piloto. La aplicacion confirmo una identidad de negocio y de dispositivo en
  la base nueva, sin reutilizar datos SQLite del intento anterior.
- El APK debug se instalo correctamente por ADB en el Xiaomi M2102J20SG. Se
  creo su propietario local ficticio y se vinculo mediante un codigo temporal
  de un solo uso.
- La lista central de dispositivos confirmo `LAPTOP-B9UDDQA5` en Windows y
  `Xiaomi M2102J20SG` en Android, ambos con acceso el 28 de octubre de 2026 a
  las 15:12. Windows mostro `Sincronizado` y ninguna operacion pendiente.
- El ZIP y su archivo `.sha256` se copiaron a
  `E:\CAPC-PILOTO-CORREGIDO-20261028`. El ZIP copiado mide 109623945 bytes y
  su SHA-256 coincide con el origen:
  `966ED753805D1398ECFFD2122F8FF735D1CD0C91C83578D8D47962BC2420544E`.
- El workflow `Cloud Sync Identity` del commit `5fe5f14` aprobo todas sus
  validaciones. Falta instalar y vincular el segundo Windows antes de comenzar
  la matriz fisica de operaciones.
