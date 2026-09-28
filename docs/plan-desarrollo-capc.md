> Actualización local: 25 de septiembre de 2026. El proyecto Windows canónico está en `C:\Users\CAPC\capc_multi`. La etapa actual implementa operación local sin internet, usuarios/roles locales, SQLite transaccional, compras, cartera, cotizaciones/trabajos, caja, reportes, impresión y recuperación. No incluye sincronización ni despliegue VPS. Las decisiones y APIs vigentes están en `CONTRACT.md`, y la evidencia de verificación en `CONTINUAR_AQUI.md`.
>
> Decisiones confirmadas: cantidades enteras; compras por costo unitario o total mayorista; costo promedio ponderado; precio sugerido por porcentaje sobre costo elegido por el usuario, aceptación explícita o precio manual. Se conservaron la base original y las pantallas; se corrigieron los fallos detectados antes de ampliarlas. No se instaló Microsoft Build Tools: el equipo ya tenía Visual Studio Community 2026 Insiders. Windows Release compiló; la prueba USB requiere el modelo real.
>
> Las secciones siguientes conservan el plan general de evolución Android/VPS y no afirman que esas funciones estén disponibles. El antiguo requisito de no administrar usuarios offline correspondía a la futura sincronización: esta versión sí administra cuentas locales autónomas.
# Plan de desarrollo de CAPC MULTISERVICIO

Propuesta del 23 de septiembre de 2026, ajustada a la infraestructura del propietario. Este documento define el desarrollo; todavía no representa una aplicación publicada ni una instalación realizada en el VPS.

## Alcance confirmado

- Aplicación Android distribuible por Google Play y programa de escritorio para Windows.
- Administración de un negocio desde celular y computador, con datos compartidos.
- Plataforma que pueda ofrecerse a otros negocios; cada empresa tendrá sus propios usuarios, catálogo, clientes, proveedores y documentos.
- Continuidad de ventas cuando se interrumpe internet.
- Impresora conectada por USB al computador Windows. Falta identificar marca, modelo y ancho de papel antes de integrar y validar la impresión.
- VPS propio con Ubuntu y 4 GB de RAM. Ya utiliza PM2 y aloja aplicaciones web, incluida una página de bolsa de valores. La versión de Ubuntu, CPU, disco disponible y consumo actual no se han comprobado.
- Cuenta de Google Play Console ya pagada. Falta comprobar su tipo, verificaciones y acceso a producción; no hay que presupuestar un nuevo registro para esa misma cuenta.

## Arquitectura recomendada

**Flutter para Android y Windows**, con una base compartida de código y adaptaciones de pantalla e impresión para cada plataforma. Flutter soporta ambas plataformas; compartir código no elimina las pruebas y configuraciones específicas de cada una. [Plataformas de Flutter](https://docs.flutter.dev/reference/supported-platforms).

**Servidor propio: API con Node.js, TypeScript y Fastify, y base central PostgreSQL**, como propuesta para aprovechar el VPS existente. La API concentrará usuarios, permisos, operaciones de negocio y sincronización. Se organizará como una sola aplicación con módulos internos para simplificar el primer despliegue. Fastify se presenta como un framework de bajo consumo adicional para Node.js; eso no sustituye medir nuestra aplicación y el servidor real. [Documentación de Fastify](https://fastify.dev/docs/latest/).

La API tendrá su propia configuración de PM2, identidad de servicio, directorio y puerto local, con conexiones HTTPS a través del servidor web que se confirme instalado. La base de datos no se expondrá directamente a los celulares. Las operaciones de venta, cobro e inventario se validarán y guardarán juntas en el servidor. La autenticación utilizará bibliotecas mantenidas, sesiones revocables y recuperación de acceso; los permisos de empresa y rol se comprobarán en cada operación. [Configuración de aplicaciones en PM2](https://pm2.keymetrics.io/docs/usage/application-declaration/).

**No se instalará inicialmente la plataforma completa de Supabase en este VPS compartido.** Su documentación indica un mínimo de 4 GB de RAM para todos sus componentes y recomienda 8 GB o más. Como los 4 GB actuales también sostienen otras aplicaciones, esa instalación dejaría un margen incierto. La alternativa ligera propuesta también depende de verificar recursos libres; no se garantiza capacidad por conocer solamente la RAM total. [Requisitos de Supabase autohospedado](https://supabase.com/docs/guides/self-hosting/docker).

**SQLite local en cada equipo**, más una capa de sincronización que se construirá explícitamente. Una venta confirmada localmente debe sobrevivir al cierre de la aplicación y al reinicio del equipo. Mientras no haya conexión, otros equipos mostrarán la información de su última sincronización. [Diseño de aplicaciones Flutter sin conexión](https://docs.flutter.dev/app-architecture/design-patterns/offline-first).

**Generación propia de PDF y conexión a impresión Windows**. La aplicación real generará los documentos sin depender de esta conversación. La conexión USB se validará con el modelo de impresora real y su controlador o protocolo compatible.

## Aprovechamiento del VPS existente

Antes de desplegar, comprobar mediante una revisión de solo lectura:

1. Versión de Ubuntu, CPU, memoria disponible y uso en horas de mayor actividad, disco libre y crecimiento de archivos.
2. Aplicaciones y procesos existentes, puertos ocupados, servidor web y certificados. Identificar si ya existe PostgreSQL y cómo se respalda.
3. Dominio o subdominio disponible para CAPC, control de DNS y modalidad de acceso autorizado al servidor. No compartir contraseñas ni claves privadas en la conversación.
4. Lugar de respaldo fuera del VPS, frecuencia y procedimiento probado de restauración, incluyendo base de datos y documentos adjuntos.

La primera instalación será un piloto con CAPC, condicionado al margen medido de recursos. Se usará un proceso de API inicial y un límite de conexiones a la base acorde con la memoria disponible. Compilar y ejecutar las pruebas fuera del servidor compartido cuando sea posible. Un nombre distinto en PM2 organiza procesos, pero no aísla por sí solo el consumo ni los datos: se requieren permisos y configuración propios.

Se documentará el despliegue y la vuelta a la versión anterior antes de cambiar producción. Los cambios se dirigirán únicamente al servicio CAPC y a su configuración; no se actualizarán runtimes compartidos ni se reiniciarán todas las aplicaciones como parte de esta instalación.

Antes de incorporar más negocios, medir tiempos de respuesta, memoria, CPU, conexiones y crecimiento del disco con carga representativa. Si no existe margen suficiente, ampliar recursos o separar CAPC en otro VPS. El servidor actual es una opción de inicio, no una capacidad comercial ya validada.

## Separación entre empresas y usuarios

- Cada registro de negocio tendrá un identificador de empresa. El servidor comprobará que el usuario pertenece a esa empresa antes de permitir cualquier operación.
- Roles iniciales: propietario, administrador y cajero. Cambiar precios, anular ventas, devolver dinero y modificar permisos requerirá la autorización del rol correspondiente.
- La identidad de quien registra una venta se tomará de su sesión, no de un nombre escrito libremente.
- Cada empresa configurará nombre comercial, logo, contactos, moneda, numeración y formatos de documentos.
- La base local y los archivos se separarán por empresa y sesión para evitar mostrar datos de otro negocio al cambiar de cuenta.
- La administración de la plataforma gestionará empresas y accesos. Cualquier acceso excepcional de soporte deberá ser autorizado y quedar registrado.
- Las cuentas de infraestructura, publicación y repositorio deberán pertenecer al titular del proyecto; los colaboradores recibirán acceso por invitación.

## Reglas para vender sin internet

1. Guardar en una sola operación local la venta, sus conceptos, el movimiento de inventario, el cobro o saldo pendiente y el evento por sincronizar.
2. Asignar un identificador único por operación. Si se reenvía diez veces por fallos de red, el servidor debe registrarla una sola vez.
3. Mostrar los estados: guardado en este equipo, pendiente de sincronizar, sincronizado o requiere revisión.
4. Sincronizar de manera transaccional: ninguna venta puede quedar con el cobro guardado y el inventario sin descontar.
5. Para ventas de materiales desde varios equipos desconectados, asignar existencias o cupos por caja/dispositivo. Las unidades reservadas para una caja no podrán venderse simultáneamente desde otra. Una transferencia de cupo requiere coordinación con el servidor.
6. Comenzar el piloto con una caja habilitada para venta offline por negocio y ampliar a varias cajas después de validar la asignación de existencias. La arquitectura debe prever esa ampliación desde el inicio.
7. Definir aparte el cobro de deudas offline: un saldo no debe poder cobrarse simultáneamente en dos cajas. Para el piloto, asignar la cobranza offline a una caja responsable y bloquear cobros concurrentes sobre las cuentas que tenga asignadas.
8. Los cambios de permisos y la baja de un dispositivo se aplicarán al reconectar. Definir una vigencia limitada de autorización offline y no permitir administración de usuarios sin conexión.

La sincronización no es un respaldo: se necesitan copias de seguridad y una prueba de recuperación independiente. Tampoco debe prometerse información simultánea entre dispositivos mientras están desconectados.

## Impresión con la USB existente

- Desde Windows: impresión local mediante el controlador o integración compatible, incluso sin internet.
- Desde Android: generar PDF y compartirlo; para imprimir en la USB del café, enviar un trabajo al componente de impresión del computador. Para ese envío remoto, el PC deberá estar encendido, la impresora disponible y ambos extremos conectados al servicio.
- Imprimir desde Android cuando internet esté caído requeriría una conexión por la red local y un componente adicional; no asumir que la USB del computador es accesible directamente por el celular.
- Incluir vista previa, selección del papel admitido y reimpresión marcada como copia.
- Evitar reintentos ciegos después de un fallo de impresora: si se desconoce si el papel salió, pedir revisión antes de repetir.
- Validar acentos, cantidades, saldos, documentos largos, márgenes y corte de papel en el equipo real. No prometer corte automático si la impresora no lo admite.

## Módulos de la primera versión operativa

| Módulo | Funciones necesarias |
|---|---|
| Negocios y usuarios | Empresas separadas, roles, cajas, dispositivos y configuración |
| Inventario | Materiales, servicios, códigos, costos, precios, mínimos y movimientos |
| Ventas | Varios conceptos, contado/crédito, comprobantes y devoluciones |
| Clientes y deudas | Clientes identificados, abonos, saldos y estados de cuenta |
| Compras y proveedores | Recepción de materiales, compras a crédito y pagos parciales |
| Cotizaciones | Alcance, conceptos, vigencia, condiciones, aceptación y conversión única |
| Trabajos | Recibido, en proceso, listo y entregado; responsable, plazo y archivos |
| Caja y gastos | Apertura, movimientos, cierre por turno y diferencias |
| Reportes | Ventas, compras, cartera, caja, existencias, PDF y exportación |
| Operación | Sincronización, respaldo, restauración y registro de cambios |

Los anticipos de trabajos se distinguirán de ventas e ingresos devengados, y se aplicarán al documento correspondiente sin volver a cobrarlo. Los estados de pago serán **Pagado, Pendiente, Abono parcial y Anulado** para evitar la ambigüedad de “cancelado”.

Las anulaciones y devoluciones conservarán el historial y registrarán los movimientos compensatorios con su fecha. El cálculo de utilidad requiere costo de venta y reglas de valoración del inventario; no se presentará el flujo de caja como utilidad. La facturación electrónica, si se requiere, tendrá un alcance e integración propios.

## Etapas y criterios para avanzar

### 1. Base de producción

Crear el repositorio, ambientes de desarrollo/prueba/producción, esquema de datos, usuarios, permisos, almacenamiento local, sincronización y copias de seguridad. El prototipo actual aporta pantallas y reglas comprobadas; sus datos se recrean en memoria y su impresión depende de solicitudes a la conversación.

Entrega: un negocio puede iniciar sesión en Android y Windows, registrar una operación sencilla y conservarla tras cerrar y abrir ambas aplicaciones. Un usuario de otro negocio no puede acceder a ella.

### 2. Venta completa en CAPC

Implementar catálogo, venta, stock, cobro, crédito, abonos y comprobante con la impresora USB real. Validar primero este recorrido completo antes de ampliar todos los módulos.

Entrega: una venta offline queda guardada, puede imprimirse desde Windows y se sincroniza una sola vez al reconectar. Dos equipos no pueden consumir la misma unidad asignada.

### 3. Operación completa y piloto

Añadir compras, proveedores, gastos, caja por turno, cotizaciones, trabajos y reportes. Usar CAPC como primer negocio piloto y luego incorporar otro negocio de prueba para comprobar la separación de datos.

Entrega: caja, saldos e inventario concilian; se restaura un respaldo en un equipo limpio; se documenta la capacitación y el soporte.

### 4. Distribución y mantenimiento

Preparar versión Android firmada para pruebas en Google Play y un instalador de Windows con mecanismo de actualización. Publicar después de probar los flujos reales, la pérdida de conexión, la restauración y la impresora.

Si se decide cobrar a otros negocios, definir planes, licencias, soporte y facturación del servicio. Revisar las reglas aplicables de la tienda antes de implementar pagos o suscripciones dentro de Android.

## Preparación de Google Play

- Utilizar la cuenta de Play Console que el propietario ya tiene pagada. Comprobar titularidad, verificaciones y estado de publicación. El pago del registro no equivale a que esta aplicación esté aprobada. [Registro de Play Console](https://support.google.com/googleplay/android-developer/answer/6112435?hl=es).
- Confirmar si la cuenta existente es personal o de organización y cumplir los requisitos que le correspondan. Las cuentas de organización requieren datos verificables, incluido D-U-N-S según los requisitos vigentes. [Tipos de cuenta](https://support.google.com/googleplay/android-developer/answer/13634885?hl=en).
- Preparar aplicación firmada, ficha, icono, capturas y requisitos técnicos vigentes. [Publicación Android con Flutter](https://docs.flutter.dev/deployment/android).
- Política de privacidad, declaración de seguridad de datos y acceso de revisión. La app y la API ya incluyen solicitud de eliminación autenticada y recurso web; falta desplegar sus URL públicas y completar la ficha de Play Console. [Datos de usuario](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en-GB), [eliminación de cuentas](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).
- Para cuentas personales creadas después del 13 de noviembre de 2023, realizar la prueba cerrada exigida con al menos **12 participantes inscritos continuamente durante 14 días** antes de solicitar acceso a producción. Cumplir ese período no garantiza aprobación automática. [Pruebas requeridas](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en).

## Costos que deben presupuestarse por separado

El propietario ya dispone de VPS y registro pagado en Play Console. Aprovecharlos puede evitar contratar otro alojamiento al inicio, si la revisión confirma capacidad. No elimina el costo recurrente del VPS ni posibles ampliaciones.

Presupuestar desarrollo inicial; respaldo externo y recuperación; dominio, archivos y comunicaciones según necesidades; preparación de la publicación; soporte y mantenimiento; pruebas e integración de impresoras. La estimación depende del número de negocios, usuarios, cajas, volumen de documentos y disponibilidad requerida. Durante este trabajo no se ha contratado ningún servicio adicional ni se ha accedido o instalado software en el VPS.

## Dato pendiente para la integración física

Marca y modelo exactos de la impresora USB y ancho del papel. Se verificará compatibilidad antes de elegir una biblioteca o prometer funciones de impresión específicas.

