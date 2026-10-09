# Identidad visual de CAPC MULTISERVICIO

## Archivos maestros

- `capc_logo_horizontal.png`: logo oficial completo entregado por CAPC. Conserva la transparencia y se usa sobre fondos oscuros.
- `capc_app_icon_master.png`: icono cuadrado para Android, Windows y web. Mantiene el símbolo reconocible sin texto pequeño.
- `capc_play_store_icon_512.png`: copia lista para cargar como icono de la ficha en Google Play Console.

Los iconos finales de cada plataforma se generan desde `capc_app_icon_master.png` con `flutter_launcher_icons`. No se deben editar manualmente los archivos de `mipmap-*`, `web/icons` ni `windows/runner/resources/app_icon.ico`.

## Colores de aplicación

- Azul oscuro de fondo: `#142638`
- Naranja de marca: `#FF6E08`
- Dorado de marca: `#FFBF1F`
- Blanco: `#FFFFFF`

## Uso recomendado

- Barra lateral, acceso y pantalla de inicio: logo horizontal sobre azul oscuro.
- Icono instalado, acceso directo, pestaña web y Play Store: icono cuadrado.
- Reportes y comprobantes impresos: logo horizontal dentro de una franja azul oscuro, para que el texto blanco conserve contraste.
- Mantener espacio libre alrededor del logo y no deformar, recolorear ni volver a escribir el nombre.

## Regenerar iconos

Desde la raíz del proyecto:

```powershell
flutter pub run flutter_launcher_icons
```
