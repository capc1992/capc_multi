# Estado del piloto CAPC

Actualizado el 9 de octubre de 2026.

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
