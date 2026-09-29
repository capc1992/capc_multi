# CAPC 0.4.1+8: existencias iniciales

Estado: corrección local; no publicada ni instalada en los equipos del negocio.

Verificación local: 39 pruebas aprobadas (stock inicial, sincronización, libro de
inventario y Centro de actualizaciones), análisis Flutter sin observaciones y
compilación Windows release correcta. Las pruebas usan bases temporales; no se
modificaron las bases reales ni se comprobó la corrección en los equipos del usuario.

Se generaron `dist/CAPC-MULTISERVICIO-Setup-0.4.1.exe` y
`dist/latest-stock-0.4.1.draft.json` (esquema de manifiesto validado). Son candidatos
locales sin firma y sin editor configurado, no una publicación lista para instalar
desde el Centro de actualizaciones. Hay que recompilar con el editor, firmar y
regenerar el manifiesto antes de publicar.

## Corrección

- Al crear o importar un producto, o cargar ejemplos, se envía también el
  movimiento inicial mediante el protocolo existente `stock.adjusted`.
- Cada movimiento usa su ID original como ID de operación. Los reintentos y
  respuestas perdidas no duplican las existencias ni el costo.
- Antes de enviar un lote se recuperan las entradas iniciales que versiones
  anteriores guardaron solo localmente. Se incluyen únicamente movimientos
  originados en ese dispositivo; no se vuelven a publicar los recibidos de otro.
- El receptor reconstruye cantidad y valor desde los movimientos cuando llega
  una entrada inicial atrasada, incluyendo las salidas que habían quedado en
  conflicto. Los conflictos se conservan como historial con fecha de resolución;
  los saldos inconsistentes permanecen sin resolver.
- Si el receptor recibió la entrada con una versión anterior, también repara
  el saldo pendiente en la siguiente sincronización después de actualizar.
- No se cambia el esquema SQLite ni se requiere una migración del servidor.

## Centro de actualizaciones: bloqueo de la versión instalada

La versión 0.4.0+7 distribuida en esta sesión se compiló sin
`CAPC_WINDOWS_UPDATE_PUBLISHER`. Ese valor queda dentro de la aplicación y no
puede cambiarse mediante `latest.json`, una variable del sistema ni un cambio en
el VPS. El verificador rechaza la instalación si el editor esperado está vacío,
incluso cuando el archivo descargado tiene una firma válida.

Además, al comprobar el 28 de septiembre de 2026,
`updates.capcmultiservicios.site` no resolvió por DNS. El servidor de sincronización
`api.capcmultiservicios.site` es un servicio diferente.

Por ello no se puede entregar esta primera corrección exclusivamente mediante
el botón de la versión instalada. Se necesita habilitar el canal y una
actualización inicial del cliente con el editor configurado. No se ha eliminado
la validación de firma, editor, HTTPS, tamaño ni SHA-256.

## Preparación de una publicación real

1. Configurar el DNS y HTTPS de `updates.capcmultiservicios.site` y la plantilla
   `deploy/nginx/updates.capcmultiservicios.site.conf` en el VPS.
2. Disponer de un certificado de firma de código confiable para Windows y
   confirmar su nombre de editor. No enviar claves privadas ni contraseñas por chat.
3. Compilar 0.4.1+8 con `CAPC_SYNC_URL`, `CAPC_UPDATE_CHANNEL=stable` y
   `CAPC_WINDOWS_UPDATE_PUBLISHER` igual al editor del certificado.
4. Firmar ejecutable e instalador con `tools/release/sign-windows.ps1`.
5. Generar `latest.json` **después de firmar** con
   `tools/release/latest_manifest.py`; la firma cambia el hash y el tamaño.
6. Subir el instalador a la ruta versionada y publicar el manifiesto al final.
   Los borradores locales sin firma no son artefactos publicables.
7. Aplicar una vez el instalador con el editor configurado en cada equipo,
   conservando datos y credenciales. Las siguientes versiones superiores podrán
   descargarse e instalarse desde el Centro de actualizaciones.

El workflow existente publica conjuntamente Windows y Android, con sus respectivos
secretos; no ejecutarlo como alternativa solo para Windows sin preparar ambos.
Su versión de entrada debe superar la de `pubspec.yaml`: para reconstruir el
candidato local 0.4.1+8 usar los scripts locales, no ese workflow con la misma versión.

## Validación en los equipos

Actualizar ambos equipos antes de verificar el resultado. Sincronizar primero
el principal y luego el segundo hasta que no queden operaciones pendientes.
Comparar cantidades y valor del inventario; repetir la sincronización y confirmar
que no cambian. No introducir ajustes manuales para compensar la entrada omitida.
Si ya hubo ajustes compensatorios, revisarlos antes de activar la recuperación.

El estado «Sincronizado» confirma los eventos en cola, no una conciliación manual
del inventario físico. Los servicios no tienen existencias propias.
