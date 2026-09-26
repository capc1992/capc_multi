# Productos, servicios y reportes en Excel

## Cargar muchos productos o servicios

1. En **Inventario**, pulsa **Descargar plantilla Excel** y elige dónde guardarla.
2. Abre el archivo en Excel o una aplicación compatible con `.xlsx`.
3. Completa la hoja **Productos** debajo de los encabezados. Consulta las hojas de instrucciones y ejemplos. Los ejemplos están separados y no se importan.
4. Guarda el archivo como `.xlsx`. En CAPC, pulsa **Importar Excel** y **Seleccionar Excel**.
5. Revisa el resumen y la vista previa. Pulsa **Importar registros** para confirmar.

Cada archivo admite hasta 5.000 filas y 10 MB. Para un catálogo más grande, usa varios archivos. La ventana muestra los primeros 20 registros, pero valida e importa todas las filas del archivo.

El inventario muestra 50 registros por página. La búsqueda consulta todo el catálogo y **Exportar Excel** incluye todos los resultados filtrados, aunque ocupen varias páginas.

Columnas de la plantilla:

| Columna | Contenido |
| --- | --- |
| Código | Código único. Conserva el formato Texto si lleva ceros al inicio. |
| Nombre | Nombre del producto o servicio. |
| Tipo | Producto, Material o Servicio. |
| Categoría | Opcional. |
| Unidad | Por ejemplo, Unidad, Hoja u Hora. |
| Costo de compra | Pesos colombianos enteros, sin símbolos ni separadores al escribir como texto. Vacío equivale a cero. |
| Precio de venta | Pesos colombianos enteros, mayor o igual a cero. |
| Stock inicial | Cantidad entera. Vacío equivale a cero. |
| Stock mínimo | Cantidad entera. Vacío equivale a cero. |

Los servicios deben tener stock inicial y mínimo en cero. Configura sus materiales consumidos desde CAPC después de importar. Si utilizas fórmulas en Excel, convierte sus resultados a valores antes de cargar el archivo.

La importación crea registros nuevos. No reemplaza códigos existentes ni modifica sus precios o existencias. Si una fila tiene un error o un código repetido, se cancela el lote completo: corrige las filas indicadas y vuelve a seleccionar el archivo. Las existencias iniciales de productos generan sus movimientos y costos habituales. La importación requiere permisos para administrar el catálogo.

## Descargar información

- **Inventario → Exportar Excel:** productos y servicios de la búsqueda y filtro actuales. Incluye códigos, precios y existencias actuales. El stock actual se coloca en la columna Stock inicial para permitir cargar un catálogo en una base nueva. Importarlo en la misma base se rechaza por códigos existentes.
- **Clientes y deudas → Exportar Excel:** clientes de la búsqueda actual, teléfonos y saldos pendientes actuales.
- **Historial → Exportar Excel:** ventas de la búsqueda actual, fechas de Bogotá, cliente, estado, importes, devoluciones y saldo actual.
- **Reportes → Exportar Excel:** elige el reporte. Conserva el período seleccionado; inventario, cartera y cuentas por pagar corresponden al estado actual, tal como indica cada reporte.

Los importes y cantidades se guardan como números para facilitar sumas y filtros. Los identificadores y teléfonos se conservan como texto. Los archivos Excel son copias para consulta y organización; no reemplazan el respaldo de la base de datos.

## Crear un cliente durante una venta

En **Nueva venta**, junto al selector de cliente, pulsa **Nuevo cliente**. Escribe nombre y teléfono opcional y guarda. El cliente queda seleccionado en la venta y se conserva el carrito, el pago y el vencimiento. Cancelar conserva el cliente anterior.

## Comprobante de venta

CAPC ya genera el comprobante al confirmar una venta y permite abrirlo desde **Historial**. Tiene vista previa, guardado en PDF e impresión en Carta o tirilla de 80 mm. Continúa siendo un comprobante interno sin validez fiscal.
