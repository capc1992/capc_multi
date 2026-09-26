import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../services/spreadsheets.dart';
import 'ui_shared.dart';

const excelFileType = XTypeGroup(label: 'Libro de Excel', extensions: ['xlsx']);

Future<List<int>> buildProductTemplate() => compute(_templateBytes, null);
List<int> _templateBytes(void _) => CapcSpreadsheets.productTemplate();

Future<void> saveExcelFile(
  BuildContext context, {
  required String name,
  required Future<List<int>> Function() build,
}) async {
  final destination = await getSaveLocation(
    suggestedName: '$name.xlsx',
    acceptedTypeGroups: const [excelFileType],
    confirmButtonText: 'Guardar Excel',
  );
  if (destination == null) return;
  final path = destination.path.toLowerCase().endsWith('.xlsx')
      ? destination.path
      : '${destination.path}.xlsx';
  // The native picker only confirms the path it returned. If we append the
  // extension, check that distinct final destination before replacing it.
  if (path != destination.path && await File(path).exists()) {
    if (!context.mounted) return;
    final replace = await confirmAction(
      context,
      'Reemplazar archivo de Excel',
      'Ya existe $path. ¿Quieres reemplazarlo?',
      action: 'Reemplazar',
    );
    if (!replace) return;
  }
  final bytes = await build();
  await XFile.fromData(
    Uint8List.fromList(bytes),
    mimeType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ).saveTo(path);
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Excel guardado en $path')));
  }
}

Future<void> saveTableExcel(
  BuildContext context, {
  required String title,
  required List<String> headers,
  required List<List<Object?>> rows,
  List<String> notes = const [],
}) => saveExcelFile(
  context,
  name: title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '-'),
  build: () => compute(_tableBytes, (title, headers, rows, notes)),
);

List<int> _tableBytes(
  (String, List<String>, List<List<Object?>>, List<String>) data,
) => CapcSpreadsheets.exportTable(
  title: data.$1,
  headers: data.$2,
  rows: data.$3,
  notes: data.$4,
);

/// PDF reports already format COP for display. Convert only declared numeric
/// and date columns, keeping document numbers, names and warnings as text.
List<List<Object?>> reportExcelRows(String report, List<List<String>> rows) {
  final numericColumns = switch (report) {
    'Ventas y utilidad' => {3, 4},
    'Productos más vendidos' => {1, 2},
    'Cobros' => {3},
    'Compras y proveedores' || 'Cuentas por pagar' => {2, 3, 4},
    'Gastos' || 'Gastos y flujo de caja' => {3},
    'Caja' => {2, 3, 4},
    'Cartera' => {3},
    _ => <int>{},
  };
  final dateColumns = switch (report) {
    'Ventas y utilidad' ||
    'Compras y proveedores' ||
    'Cuentas por pagar' => {1},
    'Cobros' || 'Gastos' || 'Gastos y flujo de caja' => {0},
    'Caja' => {0, 1},
    'Cartera' => {2},
    _ => <int>{},
  };
  Object convert(String value, int column) {
    if (numericColumns.contains(column)) {
      final digits = value.replaceAll(RegExp(r'[\$\s.]'), '');
      final number = int.tryParse(digits);
      // Excel preserves 15 significant digits. Keep larger totals exact as text.
      if (number != null && number.abs() <= 999999999999999) return number;
    }
    if (dateColumns.contains(column)) {
      final date = RegExp(
        r'^(\d{2})/(\d{2})/(\d{4}) (\d{2}):(\d{2})$',
      ).firstMatch(value);
      if (date != null) {
        return DateTime(
          int.parse(date[3]!),
          int.parse(date[2]!),
          int.parse(date[1]!),
          int.parse(date[4]!),
          int.parse(date[5]!),
        );
      }
    }
    return value;
  }

  return [
    for (final row in rows)
      [for (var i = 0; i < row.length; i++) convert(row[i], i)],
  ];
}

/// Returns the number created, or null when cancelled. Database writes happen
/// only after the user has reviewed and confirmed the complete workbook.
Future<int?> showProductImport(
  BuildContext context,
  CapcRepository repository,
) => showDialog<int>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ProductImportDialog(repository: repository),
);

class ProductImportDialog extends StatefulWidget {
  const ProductImportDialog({super.key, required this.repository});
  final CapcRepository repository;

  @override
  State<ProductImportDialog> createState() => _ProductImportDialogState();
}

class _ProductImportDialogState extends State<ProductImportDialog> {
  ProductImportPreview? _preview;
  List<String> _errors = [];
  String? _filename;
  bool _busy = false;

  Future<void> _choose() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await openFile(acceptedTypeGroups: const [excelFileType]);
      if (file == null) return;
      if (mounted) {
        setState(() {
          _preview = null;
          _errors = [];
          _filename = file.name;
        });
      }
      if (!file.name.toLowerCase().endsWith('.xlsx')) {
        throw const CapcException('Selecciona un archivo de Excel .xlsx.');
      }
      if (await file.length() > CapcSpreadsheets.maxImportBytes) {
        throw const CapcException('El archivo supera el límite de 10 MB.');
      }
      final preview = await compute(
        CapcSpreadsheets.parseProducts,
        await file.readAsBytes(),
      );
      final existing = {
        for (final product in await widget.repository.listProducts())
          product.code.trim().toUpperCase(),
      };
      final errors = [
        ...preview.errors,
        for (var i = 0; i < preview.products.length; i++)
          if (existing.contains(preview.products[i].code.trim().toUpperCase()))
            'Fila ${preview.sourceRows[i]}: el código '
                '"${preview.products[i].code}" ya existe en el catálogo.',
      ];
      if (mounted) {
        setState(() {
          _preview = preview;
          _errors = errors;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _errors = [error.toString()]);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy || _preview == null || _errors.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      final count = await widget.repository.importProducts(
        _preview!.products,
        sourceRows: _preview!.sourceRows,
      );
      if (mounted) Navigator.pop(context, count);
    } catch (error) {
      if (mounted) {
        setState(() {
          _errors = [error.toString()];
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = _preview?.products ?? <Product>[];
    final services = products.where((p) => p.isService).length;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Importar productos y servicios'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Completa la hoja Productos de la plantilla y selecciona '
                  'el archivo .xlsx. Máximo 5.000 filas y 10 MB por archivo. '
                  'Se crearán registros nuevos. Los códigos existentes no se '
                  'reemplazan ni se modifican sus existencias.',
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _choose,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: Text(
                    _filename == null ? 'Seleccionar Excel' : 'Cambiar archivo',
                  ),
                ),
                if (_filename != null) ...[
                  const SizedBox(height: 12),
                  Text(_filename!),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text('Procesando archivo…'),
                ],
                if (_errors.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Corrige los errores y vuelve a seleccionar el archivo. '
                    'No se ha importado ningún registro.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_errors.take(100).join('\n')),
                  if (_errors.length > 100)
                    Text(
                      'Se muestran los primeros 100 de ${_errors.length} errores.',
                    ),
                ] else if (_preview != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Productos: ${products.length - services}. Servicios: $services. '
                    'Listos para importar.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Los productos registrarán un movimiento de stock inicial. '
                    'Configura los materiales consumidos por cada servicio después de importar.',
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Código')),
                        DataColumn(label: Text('Nombre')),
                        DataColumn(label: Text('Tipo')),
                        DataColumn(label: Text('Precio COP'), numeric: true),
                        DataColumn(label: Text('Stock inicial'), numeric: true),
                      ],
                      rows: [
                        for (final product in products.take(20))
                          DataRow(
                            cells: [
                              DataCell(Text(product.code)),
                              DataCell(
                                SizedBox(width: 220, child: Text(product.name)),
                              ),
                              DataCell(
                                Text(
                                  product.isService ? 'Servicio' : 'Producto',
                                ),
                              ),
                              DataCell(Text('${product.salePrice}')),
                              DataCell(Text('${product.stock}')),
                            ],
                          ),
                      ],
                    ),
                  ),
                  if (products.length > 20)
                    Text(
                      'Vista previa de 20 de ${products.length} registros. '
                      'Se importará el archivo completo.',
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: _busy || products.isEmpty || _errors.isNotEmpty
                ? null
                : _import,
            icon: const Icon(Icons.file_download_outlined),
            label: Text(
              'Importar ${products.length} '
              '${products.length == 1 ? 'registro' : 'registros'}',
            ),
          ),
        ],
      ),
    );
  }
}
