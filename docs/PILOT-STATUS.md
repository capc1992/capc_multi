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
