# Clientes del piloto CAPC

Este paquete es exclusivamente para validar CAPC con datos ficticios contra el
servidor piloto `https://api-test.capcmultiservicios.site`. No es una entrega de
produccion ni una actualizacion para las instalaciones actuales.

Esta compilacion usa el espacio de credenciales `pilot-2026-10`. Puede convivir
con la credencial de la version normal en el mismo usuario de Windows. Las dos
aplicaciones deben permanecer cerradas por turnos: nunca las abra al mismo
tiempo.

## Windows

1. Extraiga el ZIP completo en una carpeta nueva.
2. Cierre cualquier otra instancia de CAPC.
3. Abra `ABRIR-CAPC-PILOTO.cmd`; no abra solamente el EXE.
4. El lanzador guarda la base de prueba en `DATOS-PILOTO`, dentro de esta misma
   carpeta. No copie una base SQLite real a ese directorio.
5. Conecte el negocio remoto antes de registrar inventario, ventas o caja.

La carpeta `windows` debe permanecer completa. El ejecutable solo no funciona.
Para usar un segundo equipo, copie el ZIP y extraigalo en ese equipo; no copie
`DATOS-PILOTO` entre dispositivos.

## Android

`android/CAPC-MULTISERVICIO-PILOTO-debug.apk` es un APK de depuracion para un
telefono de prueba. No debe publicarse en Google Play ni presentarse como una
version definitiva.

## Reglas del piloto

- Use unicamente datos ficticios.
- No instale ni copie estos archivos encima de la version normal.
- No cambie manualmente el stock para compensar diferencias de sincronizacion.
- Cree el negocio en el primer dispositivo y vincule los demas mediante codigos
  temporales.
- Conserve la carpeta completa y valide los archivos con `SHA256.csv`.

La matriz de pruebas esta en `VALIDACION-OFFLINE-FIRST.md`, dentro del paquete.
