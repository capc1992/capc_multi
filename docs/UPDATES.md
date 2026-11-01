# Actualizaciones de CAPC MULTISERVICIO

## Dos acciones distintas

**Actualizar datos** vuelve a consultar la información local y, cuando la sincronización remota está configurada, permite enviar o recibir cambios del negocio. **Actualizaciones** comprueba si existe una versión nueva del programa. Una acción nunca sustituye a la otra.

CAPC continúa operando con SQLite cuando no hay internet. Un error del actualizador no bloquea ventas, inventario, caja, clientes, deudas, compras ni respaldos. Actualizar el programa nunca debe borrar, sustituir ni incluir en el instalador la base local, sus respaldos, la configuración o los documentos del negocio.

## Centro de actualizaciones

La sección `Configuración > Actualizaciones` obtiene la versión y el número de compilación del paquete instalado. Muestra canal, última versión, publicación, notas y los estados: buscando, actualizada, disponible, descargando, lista para instalar, sin internet y error.

Al iniciar, la comprobación se programa en segundo plano y no retrasa la apertura. La fecha de la última consulta se conserva en un pequeño archivo de estado privado junto a los datos de la aplicación; no contiene credenciales ni datos del negocio. La consulta automática ocurre como máximo una vez cada 24 horas. El botón manual puede comprobar en cualquier momento.

Configuración de compilación pública:

```text
--dart-define=CAPC_UPDATE_CHANNEL=stable
--dart-define=CAPC_UPDATE_WINDOWS_URL=https://updates.capcmultiservicios.site/windows/stable/latest.json
--dart-define=CAPC_WINDOWS_UPDATE_PUBLISHER=Nombre exacto del editor del certificado
```

La URL puede reemplazarse en pruebas, pero el cliente siempre exige HTTPS y el host autorizado `updates.capcmultiservicios.site`. Los canales válidos son `stable`, `beta` y `testing`.

## Windows

La dirección estable predeterminada es `https://updates.capcmultiservicios.site/windows/stable/latest.json`.

El cliente valida el esquema del manifiesto, plataforma, canal, versión y build. Nunca ofrece una versión igual o inferior. La descarga usa timeout, redirecciones controladas y una carpeta temporal privada. Solo admite HTTPS en el dominio CAPC, comprueba el tamaño exacto, SHA-256, firma Authenticode y el editor esperado. Una descarga interrumpida, alterada, sin firma o con editor diferente se elimina y no se ejecuta.

Antes de instalar, el propietario confirma la operación y CAPC crea un respaldo coherente en `respaldos_actualizacion`, vuelve a comprobar tamaño, hash y firma, abre Inno Setup y cierra correctamente el repositorio. El AppId fijo es `{9A6B92F7-CB1F-49B3-9D91-7358AE30A3A8}`; `tools/build-windows-installer.ps1` falla si cambia. Inno actualiza sobre el mismo directorio y su paquete contiene solamente binarios y documentación, nunca SQLite ni archivos del negocio.

El instalador de desarrollo actual no tiene certificado comercial. La detección, descarga y validaciones están implementadas, pero una compilación normal no lo instalará: falta configurar el certificado y `CAPC_WINDOWS_UPDATE_PUBLISHER`. Es una protección intencional.

## Android y Google Play

Android usa exclusivamente Play In-App Updates. El modo flexible es el predeterminado; Google Play administra la descarga y CAPC ofrece `Reiniciar para actualizar` al terminar. El modo inmediato solo se solicita cuando la versión es obligatoria o su prioridad en Play es crítica. Si la API interna no está disponible, se puede abrir la ficha oficial. La distribución publicada en Play no descarga ni instala APK directamente.

Play Core informa el `versionCode` disponible, la prioridad y el estado, pero no entrega a la aplicación el `versionName`, la fecha ni las notas de Play Console. Por eso el centro muestra la compilación disponible y señala que la fecha y las notas son administradas por Google Play, sin inventar metadatos.

Auditoría actual:

- `versionName` y `versionCode` provienen de `pubspec.yaml`.
- La compilación release exige variables de firma; solo un `dry_run` explícito puede usar firma debug.
- El `applicationId` definitivo es `site.capcmultiservicios.capc`. Debe conservarse en Play Console y en todas las publicaciones futuras.
- Al crear la aplicación definitiva, habilitar Play App Signing y conservar de forma segura la clave de carga. No guardar keystores ni contraseñas en Git.

La publicación real continúa bloqueada hasta configurar la firma de producción y registrar este identificador en Play Console; la compilación y verificación `dry_run` sí pueden utilizarse.

## Publicar una versión

En GitHub Actions, abre **Publicar versión CAPC** y pulsa **Run workflow / Ejecutar flujo de trabajo**. Completa `version_name`, `build_number`, `channel`, `release_notes`, `mandatory`, `android_track` y `dry_run`. Usa la pista `internal` para las primeras pruebas y conserva `dry_run` activado hasta validar artefactos y firmas.

El flujo valida versión creciente, formato, análisis, pruebas Flutter/Python y servidor, y la auditoría npm de producción. Después compila Windows, audita el AppId, crea y opcionalmente firma el instalador, calcula SHA-256/tamaño, genera y valida `latest.json`, y compila el AAB. `dry_run` conserva los artefactos de Actions sin conectarse al VPS, Google Play ni crear tags.

En una publicación real, todos los secretos son obligatorios. El AAB se envía a la pista elegida, el instalador se carga en una ruta versionada, se verifica de nuevo en el servidor y solo entonces se reemplaza atómicamente `latest.json`. Finalmente se crea el tag y la versión de GitHub. El flujo no despliega el servidor de sincronización ni ejecuta migraciones PostgreSQL.

### Secretos de GitHub pendientes

Configurar en el repositorio, sin escribir sus valores en archivos o registros:

- `WINDOWS_CERT_PFX_BASE64`
- `WINDOWS_CERT_PASSWORD`
- `WINDOWS_EXPECTED_PUBLISHER`
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
- `UPDATES_SSH_PRIVATE_KEY`
- `UPDATES_SSH_KNOWN_HOSTS`
- `UPDATES_VPS_HOST`
- `UPDATES_VPS_USER`
- `UPDATES_PUBLISH_PATH` (normalmente `/var/www/capc-updates`)

No se necesita un secreto para el dominio público. El flujo comprueba las ausencias y falla con el nombre de la configuración pendiente, sin mostrar valores.

## Servidor estático y Nginx

La plantilla no aplicada está en `deploy/nginx/updates.capcmultiservicios.site.conf`. La estructura esperada es:

```text
/var/www/capc-updates/windows/stable/latest.json
/var/www/capc-updates/windows/stable/0.4.1/CAPC-MULTISERVICIO-Setup-0.4.1.exe
```

El manifiesto no usa caché prolongada; los instaladores versionados son inmutables. Nginx solo sirve `GET/HEAD`, añade cabeceras seguras y debe tener acceso de lectura. DNS, TLS, permisos y `sudo` limitado deben revisarse manualmente antes de aplicar la plantilla. Este trabajo no accede al VPS.

## Recuperación de una versión anterior

Las carpetas versionadas no se eliminan. Para recuperar una versión, se verifica la firma y el SHA-256 del instalador anterior y que el código entienda el esquema local vigente. Después se publica ese código con un **nuevo** número de versión/build. El cliente rechaza descensos, por lo que nunca se apunta `latest.json` a un build inferior ni se reemplaza silenciosamente SQLite.

## Verificación local

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
python -m unittest discover -s tools -p "test_*.py"
flutter build windows --release --no-pub
.\tools\build-windows-installer.ps1
```

Para un AAB de prueba sin credenciales se puede definir temporalmente `CAPC_ALLOW_DEBUG_RELEASE_SIGNING=true`. Ese AAB no es publicable. La compilación real requiere las cuatro variables `CAPC_ANDROID_*` de firma.
