# Guía de operación local de CAPC MULTISERVICIO

Esta versión permite trabajar sin internet en una empresa y caja de Windows. Todos los importes se escriben en pesos colombianos enteros; las cantidades también son enteras.

## Preparar el negocio

1. Crea la cuenta propietaria al abrir por primera vez. Guarda su usuario y contraseña: se necesitan para administrar usuarios y recuperar respaldos.
2. En Inventario registra materiales y servicios con código, nombre, unidad, costo, precio y mínimo. El stock inicial es una entrada de inventario. Para corregir existencias después, utiliza el movimiento de ajuste e indica su motivo.
3. En los servicios que consumen insumos, configura Materiales del servicio. Su venta descontará esos materiales. El costo directo del servicio se suma al de los materiales.
4. Registra clientes y proveedores. Crea cuentas para administradores o cajeros desde Usuarios y auditoría si otras personas usarán la aplicación.

Un porcentaje sobre costo solo genera una sugerencia. El precio cambia al aceptar esa sugerencia o escribirlo expresamente. Recibir compras no cambia automáticamente el precio de venta.

Para cargar muchos productos y servicios, utiliza **Descargar plantilla Excel** e **Importar Excel** en Inventario. Revisa los errores y confirma la vista previa. También puedes **Exportar Excel** desde Inventario, Clientes, Historial y Reportes. Consulta [la guía de Excel](EXCEL.md).

## Abrir caja y vender

1. En Caja registra el efectivo con el que empieza el turno.
2. En Nueva venta busca por nombre o código, agrega conceptos y revisa cantidades y total.
3. Selecciona el medio de pago. En efectivo puedes indicar un recibido mayor al importe aplicado: la diferencia será el cambio. Tarjeta y transferencia no generan cambio.
4. Si queda deuda, selecciona cliente y vencimiento. Confirma una sola vez y espera el resultado.
5. Consulta el comprobante en Historial. Guardar PDF e Imprimir son acciones posteriores; cancelar la impresión no deshace la venta.

Para cobrar una deuda, abre Clientes y deudas y registra el abono de la venta correspondiente. No vuelvas a crear la venta: el abono reduce el saldo sin descontar otra vez el inventario.

Si el cliente es nuevo, pulsa **Nuevo cliente** junto al selector de Nueva venta. Al guardar queda seleccionado automáticamente y conservas los productos y el pago de la venta en curso.

## Compras y proveedores

Registra una compra con sus materiales y cantidades. Indica el costo unitario o el total del lote, según la factura del proveedor. Si queda deuda, fija el vencimiento.

La compra queda pendiente de recepción. Cuando llegue, utiliza Recibir para ingresar las existencias y actualizar el costo promedio. Los pagos al proveedor se registran por separado y reducen la deuda de esa compra.

## Cotizaciones y trabajos

Crea la cotización con cliente, conceptos, vigencia y condiciones. Mientras esté en Borrador puedes editarla; al enviarla, revisa las condiciones antes de aceptar. Una cotización no descuenta existencias ni registra una venta.

Una cotización aceptada se convierte una sola vez en venta. El inventario se comprueba al convertirla. Si el cobro deja saldo, se requieren cliente y vencimiento.

Registra los trabajos con descripción, responsable y fecha prevista. Avanza por Recibido, En proceso, Listo y Entregado. Si el trabajo está vinculado a una cotización, acéptala antes de registrar anticipos. Convierte la cotización para aplicar esos anticipos a su venta; no registres el anticipo otra vez como un cobro nuevo.

## Devoluciones, gastos y cierre

El propietario o administrador puede devolver o anular una venta indicando el motivo. El documento original se conserva. Indica qué materiales se recuperaron físicamente; un servicio ya prestado no devuelve automáticamente sus insumos al inventario.

Registra los gastos desde Caja. Al finalizar, cuenta el efectivo real y cierra el turno. La aplicación muestra el esperado y la diferencia; tarjeta y transferencia se informan por separado.

Reportes distingue ventas, cobros, devoluciones y utilidad bruta. Los cobros pueden corresponder a ventas de días anteriores. La cartera y el inventario son saldos actuales. Si falta un costo histórico fiable, no se presenta una utilidad completa.

## Respaldar y actualizar

Desde Configuración guarda un respaldo y conserva otra copia fuera del disco del equipo. Hazlo antes de actualizar. El ZIP del programa no incluye los datos del negocio.

Cierra CAPC antes de abrir la versión nueva. Mantén juntos el EXE, las DLL y la carpeta data. En el mismo usuario de Windows, la versión nueva utiliza la base de datos existente.

Restaurar recupera el estado de la copia seleccionada y exige volver a ingresar con las credenciales vigentes en ella. No incorpora automáticamente operaciones registradas después del respaldo. Consulta LEEME.md o docs/ABRIR-Y-RESPALDAR.md para recuperación cuando la base no abre.

## Validaciones pendientes en el negocio

La impresora USB debe probarse con su modelo, controlador y papel reales. Los comprobantes son internos, sin validez fiscal. Android, sincronización entre dispositivos y conexión al VPS pertenecen a una etapa posterior.
