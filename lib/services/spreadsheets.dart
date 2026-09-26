import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel_community/excel_community.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../data/models.dart';

/// Parsing never writes to the catalog. The caller must validate existing codes
/// and explicitly confirm the whole batch before importing it.
class ProductImportPreview {
  ProductImportPreview({
    required List<Product> products,
    required List<String> errors,
    required this.rowCount,
    required List<int> sourceRows,
  }) : products = List.unmodifiable(products),
       errors = List.unmodifiable(errors),
       sourceRows = List.unmodifiable(sourceRows);

  final List<Product> products;
  final List<String> errors;
  final int rowCount;

  /// One-based Excel row numbers corresponding to [products].
  final List<int> sourceRows;
  bool get canImport => products.isNotEmpty && errors.isEmpty;
}

class CapcSpreadsheets {
  static const maxImportRows = 5000;
  static const maxImportBytes = 10 * 1024 * 1024;
  static const _maxExpandedBytes = 40 * 1024 * 1024;
  static const _maxMoney = 999999999999;
  static const _maxQuantity = 1000000000;
  static const productHeaders = <String>[
    'Código',
    'Nombre',
    'Tipo',
    'Categoría',
    'Unidad',
    'Costo de compra',
    'Precio de venta',
    'Stock inicial',
    'Stock mínimo',
  ];

  static const _instructions = <String>[
    'Complete únicamente la hoja Productos, desde la fila 2. '
        'La hoja Ejemplos no se importa.',
    'La importación crea registros NUEVOS. No actualiza productos, precios '
        'ni existencias de códigos que ya estén registrados.',
    'Conserve los nueve encabezados. Puede cambiar su orden. '
        'Las filas completamente vacías se ignoran.',
    'Código, Nombre, Tipo, Unidad y Precio de venta son obligatorios. '
        'Categoría puede quedar vacía.',
    'Tipo admite Producto, Material o Servicio. Los materiales se registran '
        'como productos con inventario.',
    'Escriba los códigos como texto para conservar ceros iniciales. '
        'La plantilla prepara la columna Código como texto hasta la fila 5001.',
    'Precios en pesos colombianos enteros, sin símbolos ni separadores. '
        'Ejemplo: 15000. No se admiten valores negativos ni fórmulas.',
    'Costo de compra, Stock inicial y Stock mínimo vacíos equivalen a cero. '
        'Las cantidades deben ser enteras. Los servicios deben tener stock '
        'inicial y mínimo en cero.',
    'Cada código debe ser único, incluso al comparar mayúsculas y minúsculas. '
        'Código: hasta 80 caracteres; Nombre: 160; Categoría: 80; Unidad: 40.',
    'Máximo 5000 registros por archivo y 10 MB. '
        'Guarde como Libro de Excel (.xlsx), sin contraseña.',
    'Las recetas de materiales de los servicios se configuran en la aplicación '
        'después de importar.',
  ];

  static List<int> productTemplate() {
    final book = _book('Productos');
    _writeTable(book['Productos'], productHeaders, const []);
    // Blank, text-formatted input cells preserve codes such as 000125 when
    // entered in Excel, without adding sample records to the import sheet.
    final codeStyle = CellStyle(numberFormat: NumFormat.standard_49);
    for (var row = 1; row <= maxImportRows; row++) {
      book['Productos']
              .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
              .cellStyle =
          codeStyle;
    }
    book['Productos'].setAutoFilterByString('A1:I5001');
    _writeNotes(book, 'Instrucciones', _instructions);
    _writeTable(book['Ejemplos'], productHeaders, const [
      [
        '000125',
        'Cuaderno cuadriculado',
        'Producto',
        'Papelería',
        'Unidad',
        3000,
        5000,
        25,
        5,
      ],
      [
        'MAT-001',
        'Papel carta',
        'Material',
        'Insumos',
        'Hoja',
        50,
        100,
        500,
        50,
      ],
      [
        'SER-001',
        'Impresión a color',
        'Servicio',
        'Impresiones',
        'Página',
        200,
        1000,
        0,
        0,
      ],
    ]);
    return _encode(book);
  }

  static List<int> exportProducts(List<Product> products) {
    final book = _book('Productos');
    _writeTable(book['Productos'], productHeaders, [
      for (final p in products)
        [
          p.code,
          p.name,
          p.isService ? 'Servicio' : 'Producto',
          p.category,
          p.unit,
          p.purchasePrice,
          p.salePrice,
          p.stock,
          p.minimumStock,
        ],
    ]);
    _writeNotes(book, 'Instrucciones', [
      'Catálogo exportado. Stock inicial contiene las existencias al exportar. '
          'Este archivo sirve para organizar los datos y preparar registros NUEVOS; '
          'reimportarlo no modifica registros existentes.',
      ..._instructions,
    ]);
    return _encode(book);
  }

  static List<int> exportTable({
    required String title,
    required List<String> headers,
    required List<List<Object?>> rows,
    List<String> notes = const [],
  }) {
    if (headers.isEmpty || rows.any((row) => row.length != headers.length)) {
      throw const CapcException(
        'Las columnas del Excel no coinciden con sus datos.',
      );
    }
    final name = _sheetName(title);
    final book = _book(name);
    _writeTable(book[name], headers, rows);
    final exportNotes = [
      ...notes,
      if (rows.any(
        (row) =>
            row.any((value) => value is int && value.abs() > 999999999999999),
      ))
        'Los enteros de más de 15 cifras se exportan como texto para conservar '
            'su valor exacto, debido al límite de precisión de Excel.',
    ];
    if (exportNotes.isNotEmpty) {
      _writeNotes(
        book,
        name.toLowerCase() == 'notas' ? 'Información' : 'Notas',
        exportNotes,
      );
    }
    return _encode(book);
  }

  static ProductImportPreview parseProducts(List<int> bytes) {
    final products = <Product>[];
    final errors = <String>[];
    final sourceRows = <int>[];
    var rowCount = 0;
    ProductImportPreview result() => ProductImportPreview(
      products: products,
      errors: errors,
      rowCount: rowCount,
      sourceRows: sourceRows,
    );
    try {
      if (bytes.length > maxImportBytes) {
        throw const CapcException(
          'El archivo supera 10 MB. Divídalo en archivos más pequeños.',
        );
      }
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4b ||
          bytes[2] != 3 ||
          bytes[3] != 4) {
        throw const CapcException(
          'Seleccione un libro de Excel .xlsx válido, sin contraseña.',
        );
      }
      // Check ZIP metadata before the workbook decoder allocates XML/cell data.
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      var expanded = 0;
      for (final file in directory.fileHeaders) {
        expanded += file.uncompressedSize;
        if (expanded > _maxExpandedBytes ||
            directory.fileHeaders.length > 250) {
          throw const CapcException(
            'El libro contiene demasiada información. '
            'Copie sus productos a la plantilla y divida el archivo.',
          );
        }
      }
      final preflight = _preflightWorkbook(bytes);
      errors.addAll(preflight.errors);
      if (errors.isNotEmpty) return result();
      final book = Excel.decodeBytes(bytes);
      final sheet = book.tables['Productos'];
      if (sheet == null) {
        throw const CapcException(
          'Falta la hoja "Productos". Use la plantilla descargable.',
        );
      }
      // Bound dimensions before materializing the rectangular row collection.
      if (sheet.maxRows > 100000 || sheet.maxColumns > 100) {
        throw const CapcException(
          'La hoja Productos tiene demasiadas filas o columnas. '
          'Copie hasta 5000 registros a una plantilla nueva.',
        );
      }
      if (sheet.maxRows == 0) {
        throw const CapcException(
          'La hoja Productos está vacía. Conserve los encabezados de la plantilla.',
        );
      }
      final columns = <String, int>{};
      final expected = {
        for (final header in productHeaders) _normalize(header): header,
      };
      final headerRow = sheet.row(0);
      for (var i = 0; i < headerRow.length; i++) {
        final cell = headerRow[i]?.value;
        if (_blank(cell)) continue;
        if (cell is! TextCellValue) {
          errors.add(
            'Fila 1, columna ${i + 1}: el encabezado debe ser texto sin fórmulas.',
          );
          continue;
        }
        final header = cell.value.toString().trim();
        final key = _normalize(header);
        if (!expected.containsKey(key)) {
          errors.add(
            'Columna desconocida "$header". Use los encabezados de la plantilla.',
          );
        } else if (columns.containsKey(key)) {
          errors.add('El encabezado "$header" está repetido.');
        } else {
          columns[key] = i;
        }
      }
      for (final entry in expected.entries) {
        if (!columns.containsKey(entry.key)) {
          errors.add('Falta la columna "${entry.value}".');
        }
      }
      if (errors.isNotEmpty) return result();

      final codes = <String, int>{};
      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        if (row.every((cell) => _blank(cell?.value))) continue;
        rowCount++;
        if (rowCount > maxImportRows) {
          errors.add(
            'El archivo supera 5000 registros. Divídalo en varios archivos.',
          );
          break;
        }
        final startErrors = errors.length;
        final line = r + 1;
        CellValue? value(String header) {
          final column = columns[_normalize(header)]!;
          return column < row.length ? row[column]?.value : null;
        }

        void error(String message) => errors.add('Fila $line: $message');
        for (var c = 0; c < row.length; c++) {
          if (_blank(row[c]?.value)) continue;
          if (!columns.containsValue(c)) {
            error('hay datos en la columna ${c + 1}, que no tiene encabezado.');
          } else if (row[c]?.value is FormulaCellValue) {
            error(
              'no se admiten fórmulas. Reemplace las fórmulas por sus valores.',
            );
          }
        }
        if (errors.length != startErrors) continue;
        String numericCode(Data cell, int value) {
          final code = _numericCode(
            cell,
            value,
            sourceFormat:
                preflight.formats[(cell.rowIndex + 1, cell.columnIndex + 1)],
          );
          if (code == null) {
            error(
              '"Código" usa un formato numérico que podría cambiar su valor. '
              'Convierta el código visible a texto antes de importar.',
            );
          }
          return code ?? '';
        }

        String text(
          String header,
          int max, {
          bool optional = false,
          bool code = false,
        }) {
          final cell = value(header);
          String data;
          if (_blank(cell)) {
            data = '';
          } else if (cell is TextCellValue) {
            data = cell.value.toString().trim();
          } else if (code &&
              cell is IntCellValue &&
              cell.value.abs() < 1000000000000000) {
            data = numericCode(row[columns[_normalize(header)]!]!, cell.value);
          } else if (code &&
              cell is DoubleCellValue &&
              cell.value.isFinite &&
              cell.value == cell.value.truncateToDouble() &&
              cell.value.abs() < 1e15) {
            data = numericCode(
              row[columns[_normalize(header)]!]!,
              cell.value.toInt(),
            );
          } else {
            error('"$header" debe ser texto.');
            return '';
          }
          if ((!optional && data.isEmpty) ||
              data.length > max ||
              data.contains('\u0000')) {
            error(
              '"$header" ${optional ? 'admite' : 'es obligatorio y admite'} hasta $max caracteres.',
            );
          }
          return data;
        }

        int number(String header, int max, {bool optional = false}) {
          final cell = value(header);
          num? parsed;
          if (optional && _blank(cell)) return 0;
          if (cell is IntCellValue) parsed = cell.value;
          if (cell is DoubleCellValue) parsed = cell.value;
          if (cell is TextCellValue &&
              RegExp(r'^\d+$').hasMatch(cell.value.toString().trim())) {
            parsed = int.tryParse(cell.value.toString().trim());
          }
          if (parsed == null ||
              !parsed.isFinite ||
              parsed < 0 ||
              parsed > max ||
              parsed != parsed.truncateToDouble()) {
            error(
              '"$header" debe ser un entero entre 0 y $max, sin símbolos ni separadores.',
            );
            return 0;
          }
          return parsed.toInt();
        }

        final code = text('Código', 80, code: true).toUpperCase();
        final name = text('Nombre', 160);
        final kind = _normalize(text('Tipo', 20));
        final category = text('Categoría', 80, optional: true);
        final unit = text('Unidad', 40);
        final cost = number('Costo de compra', _maxMoney, optional: true);
        final price = number('Precio de venta', _maxMoney);
        final stock = number('Stock inicial', _maxQuantity, optional: true);
        final minimum = number('Stock mínimo', _maxQuantity, optional: true);
        if (!{'producto', 'material', 'servicio'}.contains(kind)) {
          error('"Tipo" debe ser Producto, Material o Servicio.');
        }
        if (kind == 'servicio' && (stock != 0 || minimum != 0)) {
          error(
            'los servicios deben tener Stock inicial y Stock mínimo en cero.',
          );
        }
        if (BigInt.from(cost) * BigInt.from(stock) * BigInt.from(1000000) >
            BigInt.from(9000000000000000000)) {
          error('el costo del stock inicial supera el límite permitido.');
        }
        if (code.isNotEmpty) {
          final previous = codes[code];
          if (previous != null) {
            error(
              'el código "$code" está repetido; ya aparece en la fila $previous.',
            );
          } else {
            codes[code] = line;
          }
        }
        if (errors.length == startErrors) {
          products.add(
            Product(
              id: '',
              code: code,
              name: name,
              unit: unit,
              category: category,
              isService: kind == 'servicio',
              purchasePrice: cost,
              salePrice: price,
              stock: stock,
              minimumStock: minimum,
            ),
          );
          sourceRows.add(line);
        }
      }
    } on CapcException catch (error) {
      errors.add(error.message);
    } catch (_) {
      errors.add(
        'No se pudo leer el libro. Guárdelo como Excel .xlsx sin contraseña '
        'o copie sus datos en una plantilla nueva.',
      );
    }
    if (rowCount == 0 && errors.isEmpty) {
      errors.add(
        'La hoja Productos no contiene registros. Complete sus datos desde la fila 2.',
      );
    }
    return result();
  }

  static String? _numericCode(Data cell, int value, {String? sourceFormat}) {
    // A numeric code displayed with a zero-padding format still carries those
    // meaningful zeros; General-formatted numbers cannot recover lost zeros.
    final format =
        sourceFormat ?? cell.cellStyle?.numberFormat.formatCode ?? 'General';
    final sections = format.split(';');
    final activeSection = value == 0 && sections.length >= 3
        ? sections[2]
        : sections.first;
    if (value >= 0 && RegExp(r'^0{1,80}$').hasMatch(activeSection)) {
      return value.toString().padLeft(activeSection.length, '0');
    }
    if (format == 'General' || format == '@' || format == '0') {
      return value.toString();
    }
    return null;
  }

  /// Inspect original OOXML before the third-party decoder can discard a
  /// formula with an empty cache or expand an unexpectedly large merged range.
  static ({List<String> errors, Map<(int, int), String> formats})
  _preflightWorkbook(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documents = <String, XmlDocument>{};
    XmlDocument document(String name) => documents.putIfAbsent(name, () {
      final entry = archive.find(name);
      if (entry == null) throw const FormatException('Missing workbook part');
      return XmlDocument.parse(utf8.decode(entry.content));
    });
    Iterable<XmlElement> elements(XmlDocument doc, String name) => doc
        .descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == name);
    String target(String source, XmlElement relationship) {
      if (relationship.getAttribute('TargetMode') == 'External') {
        throw const CapcException(
          'La hoja Productos debe estar dentro del archivo Excel.',
        );
      }
      final uri = Uri.parse(relationship.getAttribute('Target') ?? '');
      if (uri.hasScheme ||
          uri.hasAuthority ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('Invalid workbook relationship');
      }
      final decoded = uri.pathSegments.join('/');
      if (decoded.isEmpty ||
          decoded.contains('\\') ||
          decoded.contains('\u0000')) {
        throw const FormatException('Invalid workbook part path');
      }
      final resolved = p.posix.normalize(
        uri.path.startsWith('/')
            ? decoded
            : p.posix.join(p.posix.dirname(source), decoded),
      );
      if (resolved.startsWith('../') ||
          resolved == '..' ||
          p.posix.isAbsolute(resolved)) {
        throw const FormatException('Workbook relationship outside package');
      }
      return resolved;
    }

    final workbookRelations = elements(document('_rels/.rels'), 'Relationship')
        .where(
          (e) => (e.getAttribute('Type') ?? '').endsWith('/officeDocument'),
        )
        .toList();
    if (workbookRelations.length != 1) {
      throw const FormatException('Ambiguous workbook relationship');
    }
    final workbookPath = target('', workbookRelations.single);
    final workbook = document(workbookPath);
    final products = elements(
      workbook,
      'sheet',
    ).where((e) => e.getAttribute('name') == 'Productos').toList();
    if (products.isEmpty) {
      throw const CapcException(
        'Falta la hoja "Productos". Use la plantilla descargable.',
      );
    }
    if (products.length != 1) {
      throw const FormatException('Duplicate product sheets');
    }
    final relationId = products.single.getAttribute('id', namespaceUri: '*');
    final relationsPath = p.posix.join(
      p.posix.dirname(workbookPath),
      '_rels',
      '${p.posix.basename(workbookPath)}.rels',
    );
    final relations = elements(
      document(relationsPath),
      'Relationship',
    ).toList();
    final productRelations = relations
        .where((e) => e.getAttribute('Id') == relationId)
        .toList();
    if (relationId == null ||
        productRelations.length != 1 ||
        !(productRelations.single.getAttribute('Type') ?? '').endsWith(
          '/worksheet',
        )) {
      throw const FormatException('Invalid product sheet relationship');
    }
    final productPath = target(workbookPath, productRelations.single);
    final productXml = document(productPath);
    if (productXml.rootElement.name.local != 'worksheet') {
      throw const FormatException('Invalid product sheet XML');
    }
    final errors = <String>[];
    for (final formula in elements(productXml, 'f')) {
      final cell = formula.ancestors
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'c')
          .firstOrNull;
      final reference = cell?.getAttribute('r') ?? '';
      final row = RegExp(r'\d+$').firstMatch(reference)?.group(0);
      errors.add(
        '${row == null ? 'Hoja Productos' : 'Fila $row ($reference)'}: '
        'no se admiten fórmulas. Reemplace las fórmulas por sus valores.',
      );
    }

    var totalCells = 0;
    var mergedArea = 0;
    const dimensionError = CapcException(
      'El libro contiene rangos demasiado grandes. '
      'Copie hasta 5000 registros a una plantilla nueva.',
    );
    (int, int) coordinates(String reference) {
      final match = RegExp(
        r'^\$?([A-Z]{1,3})\$?([1-9]\d{0,6})$',
      ).firstMatch(reference);
      if (match == null) throw dimensionError;
      var column = 0;
      for (final char in match.group(1)!.codeUnits) {
        column = column * 26 + char - 64;
      }
      final row = int.parse(match.group(2)!);
      if (column > 100 || row > 100000) throw dimensionError;
      return (column, row);
    }

    // The decoder reads auxiliary sheets too. Validate every worksheet XML,
    // including sheets whose names and relationships differ from the template.
    final worksheetPaths = {
      productPath,
      for (final relation in relations.where(
        (element) =>
            (element.getAttribute('Type') ?? '').endsWith('/worksheet'),
      ))
        target(workbookPath, relation),
    };
    for (final entry in archive.files.where(
      (entry) =>
          worksheetPaths.contains(entry.name) ||
          entry.name.toLowerCase().endsWith('.xml'),
    )) {
      final xml = document(entry.name);
      if (xml.rootElement.name.local != 'worksheet') continue;
      for (final element in xml.descendants.whereType<XmlElement>()) {
        final local = element.name.local;
        if (local == 'c') {
          totalCells++;
          if (totalCells > 250000) throw dimensionError;
          final reference = element.getAttribute('r');
          if (reference != null) coordinates(reference);
        } else if (local == 'row') {
          final row = int.tryParse(element.getAttribute('r') ?? '');
          if (row != null && (row < 1 || row > 100000)) throw dimensionError;
        } else if (local == 'col') {
          final min = int.tryParse(element.getAttribute('min') ?? '');
          final max = int.tryParse(element.getAttribute('max') ?? '');
          if (min == null || max == null || min < 1 || max < min || max > 100) {
            throw dimensionError;
          }
        } else if (local == 'dimension' || local == 'mergeCell') {
          final reference = element.getAttribute('ref');
          if (reference == null) throw dimensionError;
          final range = reference.split(':');
          if (range.length > 2) throw dimensionError;
          final start = coordinates(range.first);
          final end = coordinates(range.last);
          if (local == 'mergeCell') {
            if (entry.name == productPath) {
              throw const CapcException(
                'La hoja Productos contiene celdas combinadas. '
                'Sepárelas antes de importar.',
              );
            }
            mergedArea +=
                (end.$1 - start.$1 + 1).abs() * (end.$2 - start.$2 + 1).abs();
            if (mergedArea > 10000) throw dimensionError;
          }
        }
      }
    }
    // Some workbooks prefix all style elements with a namespace. Preserve the
    // original number formats even if the decoder falls back to format "0".
    final stylesRelations = relations
        .where((e) => (e.getAttribute('Type') ?? '').endsWith('/styles'))
        .toList();
    final styleFormats = <String>[];
    if (stylesRelations.length > 1) {
      throw const FormatException('Ambiguous styles');
    }
    if (stylesRelations.isNotEmpty) {
      final styles = document(target(workbookPath, stylesRelations.single));
      final formats = <int, String>{0: 'General', 1: '0', 49: '@'};
      for (final format in elements(styles, 'numFmt')) {
        final id = int.tryParse(format.getAttribute('numFmtId') ?? '');
        if (id != null) {
          formats[id] = format.getAttribute('formatCode') ?? '!unsupported';
        }
      }
      final xfs = elements(styles, 'cellXfs').firstOrNull;
      if (xfs != null) {
        for (final xf in xfs.childElements.where((e) => e.name.local == 'xf')) {
          final id = int.tryParse(xf.getAttribute('numFmtId') ?? '0');
          styleFormats.add(formats[id] ?? '!unsupported');
        }
      }
    }
    final formatsByCell = <(int, int), String>{};
    final columnStyles = elements(productXml, 'col').toList();
    for (final cell in elements(productXml, 'c')) {
      final ref = cell.getAttribute('r');
      if (ref == null) continue;
      final position = coordinates(ref);
      var style = cell.getAttribute('s');
      style ??= cell.ancestors
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'row')
          .firstOrNull
          ?.getAttribute('s');
      if (style == null) {
        for (final column in columnStyles) {
          if (position.$1 >= int.parse(column.getAttribute('min')!) &&
              position.$1 <= int.parse(column.getAttribute('max')!)) {
            style = column.getAttribute('style');
            if (style != null) break;
          }
        }
      }
      final index = int.tryParse(style ?? '0');
      formatsByCell[(
        position.$2,
        position.$1,
      )] = styleFormats.isEmpty && style == null
          ? 'General'
          : index != null && index >= 0 && index < styleFormats.length
          ? styleFormats[index]
          : '!unsupported';
    }
    return (errors: errors, formats: formatsByCell);
  }

  static bool _blank(CellValue? value) =>
      value == null ||
      (value is TextCellValue && value.value.toString().trim().isEmpty);

  static String _normalize(String value) {
    var normalized = value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    const accented = 'áéíóúü';
    const plain = 'aeiouu';
    for (var i = 0; i < accented.length; i++) {
      normalized = normalized.replaceAll(accented[i], plain[i]);
    }
    return normalized;
  }

  static Excel _book(String sheetName) {
    final book = Excel.createExcel();
    book.rename('Sheet1', sheetName);
    book.setDefaultSheet(sheetName);
    return book;
  }

  static String _sheetName(String title) {
    final clean = title.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    if (clean.isEmpty) return 'Datos';
    return clean.length <= 31 ? clean : clean.substring(0, 31);
  }

  static void _writeTable(
    Sheet sheet,
    List<String> headers,
    List<List<Object?>> rows,
  ) {
    final headerStyle = CellStyle(
      bold: true,
      fontSize: 11,
      backgroundColorHex: ExcelColor.fromHexString('#163D52'),
      fontColorHex: ExcelColor.white,
      verticalAlign: VerticalAlign.Center,
      textWrapping: TextWrapping.WrapText,
    );
    final textStyle = CellStyle(
      fontSize: 11,
      numberFormat: NumFormat.standard_49,
    );
    final numericStyle = CellStyle(
      fontSize: 11,
      numberFormat: CustomNumericNumFormat(formatCode: '#,##0'),
      horizontalAlign: HorizontalAlign.Right,
    );
    final decimalStyle = CellStyle(
      fontSize: 11,
      numberFormat: CustomNumericNumFormat(formatCode: '#,##0.00'),
      horizontalAlign: HorizontalAlign.Right,
    );
    final dateStyle = CellStyle(
      fontSize: 11,
      numberFormat: CustomDateTimeNumFormat(formatCode: 'dd/mm/yyyy hh:mm'),
    );
    sheet.setDefaultColumnWidth(20);
    sheet.setDefaultRowHeight(20);
    sheet.frozenRows = 1;
    sheet.setRowHeight(0, 32);
    if (headers.length > 1 && rows.isNotEmpty) {
      sheet.setAutoFilter(
        CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
        CellIndex.indexByColumnRow(
          columnIndex: headers.length - 1,
          rowIndex: rows.length,
        ),
      );
    }
    for (var c = 0; c < headers.length; c++) {
      sheet.setColumnWidth(
        c,
        headers[c] == 'Nombre' || headers[c].contains('Descripción')
            ? 40
            : (headers[c].length + 4).clamp(18, 32).toDouble(),
      );
      final cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
      );
      cell.value = TextCellValue(headers[c]);
      cell.cellStyle = headerStyle;
    }
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final value = rows[r][c];
        if (value == null) continue;
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1),
        );
        switch (value) {
          case int():
            if (value.abs() > 999999999999999) {
              cell.value = TextCellValue(value.toString());
              cell.cellStyle = textStyle;
            } else {
              cell.value = IntCellValue(value);
              cell.cellStyle = numericStyle;
            }
          case double():
            if (!value.isFinite) {
              throw const CapcException(
                'El Excel contiene un número no válido.',
              );
            }
            cell.value = DoubleCellValue(value);
            cell.cellStyle = value == value.truncateToDouble()
                ? numericStyle
                : decimalStyle;
          case DateTime():
            cell.value = DateTimeCellValue.fromDateTime(value);
            cell.cellStyle = dateStyle;
          default:
            // Explicit text cells never turn a user-supplied leading = into a formula.
            cell.value = TextCellValue(value.toString());
            cell.cellStyle = textStyle;
        }
      }
    }
  }

  static void _writeNotes(Excel book, String name, List<String> notes) {
    final sheet = book[name];
    _writeTable(
      sheet,
      ['CAPC MULTISERVICIO · $name'],
      [
        for (final note in notes) [note],
      ],
    );
    sheet.setColumnWidth(0, 105);
    for (var i = 1; i <= notes.length; i++) {
      sheet.setRowHeight(i, 42);
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: i))
          .cellStyle = CellStyle(
        fontSize: 11,
        textWrapping: TextWrapping.WrapText,
        verticalAlign: VerticalAlign.Center,
        numberFormat: NumFormat.standard_49,
      );
    }
  }

  static List<int> _encode(Excel book) {
    final bytes = book.encode();
    if (bytes == null) {
      throw const CapcException('No se pudo generar el archivo Excel.');
    }
    return bytes;
  }
}
