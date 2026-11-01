# CAPC MULTISERVICIO en iPhone y iPad

La versión iOS utiliza el identificador `site.capcmultiservicios.capc`, requiere
iOS 15 o posterior y se conecta a la API de producción cuando se compila con
`CAPC_SYNC_URL=https://api.capcmultiservicios.site`.

## Compilación en Codemagic

1. Conecta el repositorio `capc1992/capc_multi` en Codemagic.
2. Selecciona la rama `feature/cross-platform-updates`.
3. Ejecuta el workflow **CAPC iOS · Sideloadly · Producción** definido en
   `codemagic.yaml`.
4. Descarga la IPA y su archivo `.sha256` desde **Artifacts**.

El workflow compila en release sin firma comercial y crea una estructura IPA
que Sideloadly vuelve a firmar durante la instalación.

## Instalación con Sideloadly

1. Descarga Sideloadly únicamente desde <https://sideloadly.io/>.
2. Conecta el iPhone o iPad por USB y confirma que confías en el computador.
3. Arrastra la IPA de CAPC, escribe tu Apple ID y pulsa **Start**.
4. Si iOS lo solicita, habilita el modo desarrollador y confía en el perfil.
5. Usa el mismo Apple ID al instalar futuras versiones.

Un Apple ID gratuito normalmente requiere renovar la firma cada siete días.
La base SQLite permanece en el almacenamiento privado de la aplicación cuando
se instala una actualización con el mismo identificador.
