# Estado del piloto CAPC

Actualizado el 9 de octubre de 2026.

## Instalacion privada completada

- Commit instalado: `a3f9d5f` de `feature/cross-platform-updates`.
- Clon aislado: `/opt/capc-sync-pilot/repository`.
- Proceso: `capc-sync-pilot`, administrado por PM2 y guardado para reinicio.
- API privada: `http://127.0.0.1:3101`.
- Base y usuario exclusivos: `capc_sync_pilot`.
- Migraciones comprobadas: 001, 002, 003, 004 y 005.
- Entorno: `/etc/capc-sync-pilot/capc-sync.env`, propietario root y modo 0600.
- Respaldo: `/var/backups/capc-sync-pilot`, con tarea diaria a las 03:40.
- Restauracion de ensayo completada en una base temporal y eliminada despues.
- Typecheck, 26 pruebas unitarias y build del servidor aprobados.

Produccion continuo respondiendo en `127.0.0.1:3100` y en
`https://api.capcmultiservicios.site/health`. PostgreSQL permanecio ligado a
localhost. No se modifico la base, el proceso PM2 ni Nginx de produccion.

## Publicacion pendiente

`api-test.capcmultiservicios.site` aun no tiene registro DNS. Crear en Hostinger
un registro A para `api-test` hacia `2.25.80.190`. Despues, desde el clon piloto,
ejecutar como root:

```bash
./deploy/vps/deploy-pilot.sh
```

El script comprobara el DNS antes de instalar Nginx, solicitar TLS y validar la
ruta HTTPS. Hasta entonces el puerto 3101 no esta expuesto publicamente.

La contrasena root compartida durante la operacion debe cambiarse desde un canal
seguro. No se guardo en el repositorio ni en archivos del piloto.
