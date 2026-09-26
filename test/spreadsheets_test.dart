import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:capc_multiservicio/data/models.dart';
import 'package:capc_multiservicio/services/spreadsheets.dart';
import 'package:excel_community/excel_community.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

List<int> rewriteParts(
  List<int> bytes,
  Map<String, String Function(String)> edits,
) {
  final output = Archive();
  for (final entry in ZipDecoder().decodeBytes(bytes).files) {
    final edit = edits[entry.name];
    final data = edit == null
        ? entry.content
        : utf8.encode(edit(utf8.decode(entry.content)));
    output.add(ArchiveFile(entry.name, data.length, data));
  }
  return ZipEncoder().encode(output);
}

String replaceCell(
  String source,
  String ref,
  String contents, {
  String? type,
  String? style,
}) {
  final xml = XmlDocument.parse(source);
  final cell = xml.descendants.whereType<XmlElement>().singleWhere(
    (element) => element.name.local == 'c' && element.getAttribute('r') == ref,
  );
  cell.setAttribute('t', type);
  if (style != null) cell.setAttribute('s', style);
  cell.children
    ..clear()
    ..addAll(
      XmlDocument.parse(
        '<cell>$contents</cell>',
      ).rootElement.children.map((node) => node.copy()),
    );
  return xml.toXmlString();
}

void main() {
  Product product({String code = '000123', bool service = false}) => Product(
    id: 'original-id',
    code: code,
    name: '=Nombre literal',
    unit: 'Unidad',
    category: 'Papelería',
    isService: service,
    purchasePrice: 200,
    salePrice: 500,
    stock: service ? 0 : 10,
    minimumStock: service ? 0 : 2,
  );

  List<Object?> row({String code = '000001', String type = 'Producto'}) => [
    code,
    'Papel carta',
    type,
    'Papelería',
    'Hoja',
    50,
    200,
    10,
    2,
  ];

  List<int> workbook(List<List<Object?>> rows, {List<String>? headers}) =>
      CapcSpreadsheets.exportTable(
        title: 'Productos',
        headers: headers ?? CapcSpreadsheets.productHeaders,
        rows: rows,
      );

  ProductImportPreview parse(List<List<Object?>> rows) =>
      CapcSpreadsheets.parseProducts(workbook(rows));

  test(
    'template separates examples, keeps input blank and codes formatted as text',
    () {
      final bytes = CapcSpreadsheets.productTemplate();
      final book = Excel.decodeBytes(bytes);
      expect(book.getDefaultSheet(), 'Productos');
      expect(
        book.tables.keys,
        containsAll(['Productos', 'Instrucciones', 'Ejemplos']),
      );
      expect(book['Ejemplos'].maxRows, 4);
      final codeInput = book['Productos'].cell(CellIndex.indexByString('A2'));
      expect(codeInput.value, isNull);
      expect(codeInput.cellStyle?.numberFormat.formatCode, '@');
      final preview = CapcSpreadsheets.parseProducts(bytes);
      expect(preview.products, isEmpty);
      expect(preview.rowCount, 0);
      expect(preview.canImport, isFalse);
      expect(preview.errors.single, contains('no contiene registros'));
    },
  );

  test(
    'catalog roundtrip preserves leading zeros, prices, services and literal text',
    () {
      final bytes = CapcSpreadsheets.exportProducts([
        product(),
        product(code: 'SERV-001', service: true),
      ]);
      final book = Excel.decodeBytes(bytes);
      expect(book['Productos'].row(1)[0]?.value, isA<TextCellValue>());
      expect(book['Productos'].row(1)[1]?.value, isA<TextCellValue>());
      expect(book['Productos'].row(1)[5]?.value, isA<IntCellValue>());
      expect(
        book['Instrucciones'].row(1)[0]?.value.toString(),
        contains('NUEVOS'),
      );
      final preview = CapcSpreadsheets.parseProducts(bytes);
      expect(preview.errors, isEmpty);
      expect(preview.canImport, isTrue);
      expect(preview.rowCount, 2);
      expect(preview.sourceRows, [2, 3]);
      expect(preview.products.map((p) => p.id), everyElement(isEmpty));
      final first = preview.products.first;
      expect(first.code, '000123');
      expect(first.name, '=Nombre literal');
      expect(first.purchasePrice, 200);
      expect(first.salePrice, 500);
      expect(first.stock, 10);
      expect(first.minimumStock, 2);
      expect(first.category, 'Papelería');
      expect(preview.products.last.isService, isTrue);
      expect(preview.products.last.stock, 0);
    },
  );

  test(
    'materials and case insensitive types import; optional blanks become zero',
    () {
      final material = row(type: ' mAtErIaL ');
      material[3] = null;
      material[5] = '';
      material[6] = '200';
      material[7] = null;
      material[8] = '';
      final preview = parse([material]);
      expect(preview.errors, isEmpty);
      expect(preview.products.single.isService, isFalse);
      expect(preview.products.single.purchasePrice, 0);
      expect(preview.products.single.stock, 0);
      expect(preview.products.single.category, '');
    },
  );

  test('services reject own stock and invalid types are reported', () {
    final preview = parse([
      row(type: 'Servicio'),
      row(code: 'OTHER', type: 'Otro'),
    ]);
    expect(preview.canImport, isFalse);
    expect(preview.errors.join(' '), contains('Fila 2: los servicios'));
    expect(preview.errors.join(' '), contains('Fila 3: "Tipo"'));
    expect(preview.products, isEmpty);
  });

  test(
    'duplicate codes compare trimmed uppercase and report both source rows',
    () {
      final preview = parse([row(code: ' ab-001 '), row(code: 'AB-001')]);
      expect(preview.canImport, isFalse);
      expect(preview.errors.single, contains('Fila 3:'));
      expect(preview.errors.single, contains('fila 2'));
      expect(preview.products.first.code, 'AB-001');
    },
  );

  test('blank rows are skipped without losing actual Excel row numbers', () {
    final preview = parse([
      List.filled(9, null),
      row(),
      List.filled(9, ''),
      row(code: '002'),
    ]);
    expect(preview.errors, isEmpty);
    expect(preview.rowCount, 2);
    expect(preview.sourceRows, [3, 5]);
  });

  test('headers may be reordered and accents or case normalized', () {
    final headers = CapcSpreadsheets.productHeaders.reversed
        .map((h) => h.toUpperCase().replaceAll('Ó', 'O').replaceAll('Í', 'I'))
        .toList();
    final preview = CapcSpreadsheets.parseProducts(
      workbook([row().reversed.toList()], headers: headers),
    );
    expect(preview.errors, isEmpty);
    expect(preview.products.single.code, '000001');
    expect(preview.products.single.salePrice, 200);
  });

  test('missing, unknown and duplicate columns are explicit errors', () {
    final headers = [...CapcSpreadsheets.productHeaders];
    headers[0] = 'Referencia';
    headers[1] = 'Tipo';
    final preview = CapcSpreadsheets.parseProducts(
      workbook([row()], headers: headers),
    );
    expect(preview.canImport, isFalse);
    expect(
      preview.errors.join(' '),
      contains('Columna desconocida "Referencia"'),
    );
    expect(preview.errors.join(' '), contains('Falta la columna "Código"'));
    expect(
      preview.errors.join(' '),
      contains('encabezado "Tipo" está repetido'),
    );
  });

  test('values in columns without a header cannot be silently discarded', () {
    final book = Excel.decodeBytes(workbook([row()]));
    book['Productos'].cell(CellIndex.indexByString('J2')).value = TextCellValue(
      'Dato adicional',
    );
    final preview = CapcSpreadsheets.parseProducts(book.encode()!);
    expect(preview.canImport, isFalse);
    expect(preview.errors.single, contains('no tiene encabezado'));
  });

  test('formulas reject the row even when a numeric result is cached', () {
    final book = Excel.decodeBytes(workbook([row()]));
    book['Productos'].cell(CellIndex.indexByString('G2')).value =
        FormulaCellValue('100+100', cachedValue: IntCellValue(200));
    final preview = CapcSpreadsheets.parseProducts(book.encode()!);
    expect(preview.canImport, isFalse);
    expect(preview.products, isEmpty);
    expect(preview.errors.single, contains('no se admiten fórmulas'));
  });

  test('numeric code with zero padding retains the visible leading zeros', () {
    final book = Excel.decodeBytes(workbook([row()]));
    final cell = book['Productos'].cell(CellIndex.indexByString('A2'));
    cell.value = IntCellValue(123);
    cell.cellStyle = CellStyle(
      numberFormat: CustomNumericNumFormat(formatCode: '000000'),
    );
    final preview = CapcSpreadsheets.parseProducts(book.encode()!);
    expect(preview.errors, isEmpty);
    expect(preview.products.single.code, '000123');
  });

  test('raw OOXML formulas with empty caches are rejected before decoding', () {
    for (final formula in [
      '<f>IF(TRUE,&quot;&quot;,100)</f><v/>',
      '<f t="shared" si="0"/><v/>',
    ]) {
      final bytes = rewriteParts(workbook([row()]), {
        'xl/worksheets/sheet1.xml': (xml) =>
            replaceCell(xml, 'F2', formula, type: 'str'),
      });
      final preview = CapcSpreadsheets.parseProducts(bytes);
      expect(preview.canImport, isFalse);
      expect(preview.products, isEmpty);
      expect(
        preview.errors.single,
        contains('Fila 2 (F2): no se admiten fórmulas'),
      );
    }
  });

  test(
    'raw formulas on an auxiliary worksheet do not block product import',
    () {
      final source = CapcSpreadsheets.exportProducts([product()]);
      final bytes = rewriteParts(source, {
        'xl/worksheets/sheet2.xml': (xml) =>
            replaceCell(xml, 'A2', '<f>1+1</f><v>2</v>'),
      });
      final preview = CapcSpreadsheets.parseProducts(bytes);
      expect(preview.errors, isEmpty);
      expect(preview.products.single.code, '000123');
    },
  );

  test('original namespace-prefixed styles preserve sectional numeric codes', () {
    for (final format in ['000000;000000', '000000;000000;&quot;CERO&quot;']) {
      var styleIndex = 0;
      final source = workbook([row()]);
      // Discover style count directly from OOXML, independently of Excel's decoder.
      final archive = ZipDecoder().decodeBytes(source);
      final styles = XmlDocument.parse(
        utf8.decode(archive.find('xl/styles.xml')!.content),
      );
      final xfs = styles.descendants.whereType<XmlElement>().singleWhere(
        (e) => e.name.local == 'cellXfs',
      );
      styleIndex = xfs.childElements.length;
      final bytes = rewriteParts(source, {
        'xl/styles.xml': (xml) {
          final doc = XmlDocument.parse(xml);
          final formats = doc.descendants.whereType<XmlElement>().singleWhere(
            (e) => e.name.local == 'numFmts',
          );
          formats.children.add(
            XmlDocument.parse(
              '<numFmt numFmtId="180" formatCode="$format"/>',
            ).rootElement.copy(),
          );
          formats.setAttribute('count', '${formats.childElements.length}');
          final cells = doc.descendants.whereType<XmlElement>().singleWhere(
            (e) => e.name.local == 'cellXfs',
          );
          cells.children.add(
            XmlDocument.parse(
              '<xf numFmtId="180" fontId="0" fillId="0" borderId="0" xfId="0"/>',
            ).rootElement.copy(),
          );
          cells.setAttribute('count', '${cells.childElements.length}');
          return doc
              .toXmlString()
              .replaceAllMapped(
                RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)'),
                (m) => '<${m[1]}raw:${m[2]}',
              )
              .replaceFirst(
                '<raw:styleSheet',
                '<raw:styleSheet xmlns:raw="http://schemas.openxmlformats.org/spreadsheetml/2006/main"',
              );
        },
        'xl/worksheets/sheet1.xml': (xml) => replaceCell(
          xml,
          'A2',
          '<v>123</v>',
          type: 'n',
          style: '$styleIndex',
        ),
      });
      final preview = CapcSpreadsheets.parseProducts(bytes);
      expect(preview.errors, isEmpty);
      expect(preview.products.single.code, '000123');
    }
  });

  test('ambiguous numeric code formatting asks for explicit text', () {
    final book = Excel.decodeBytes(workbook([row()]));
    final cell = book['Productos'].cell(CellIndex.indexByString('A2'));
    cell.value = IntCellValue(123);
    cell.cellStyle = CellStyle(
      numberFormat: CustomNumericNumFormat(formatCode: '"COD-"000000'),
    );
    final preview = CapcSpreadsheets.parseProducts(book.encode()!);
    expect(preview.canImport, isFalse);
    expect(
      preview.errors.join(' '),
      contains('Convierta el código visible a texto'),
    );
  });

  test(
    'large raw merges and column ranges are bounded before workbook decoding',
    () {
      final source = CapcSpreadsheets.exportProducts([product()]);
      for (final sheet in [
        'xl/worksheets/sheet1.xml',
        'xl/worksheets/sheet2.xml',
      ]) {
        final bytes = rewriteParts(source, {
          sheet: (xml) => xml.replaceFirst(
            '</worksheet>',
            '<mergeCells count="1"><mergeCell ref="A1:XFD1048576"/></mergeCells></worksheet>',
          ),
        });
        final preview = CapcSpreadsheets.parseProducts(bytes);
        expect(preview.canImport, isFalse);
        expect(preview.errors.single, contains('rangos demasiado grandes'));
      }
      final columns = rewriteParts(source, {
        'xl/worksheets/sheet2.xml': (xml) =>
            xml.replaceFirst('min="1" max="1"', 'min="1" max="1000000000"'),
      });
      expect(
        CapcSpreadsheets.parseProducts(columns).errors.single,
        contains('rangos demasiado grandes'),
      );
    },
  );

  test(
    'raw Products merges and external sheet relationships fail explicitly',
    () {
      final merged = rewriteParts(workbook([row()]), {
        'xl/worksheets/sheet1.xml': (xml) => xml.replaceFirst(
          '</worksheet>',
          '<mergeCells count="1"><mergeCell ref="A2:B2"/></mergeCells></worksheet>',
        ),
      });
      expect(
        CapcSpreadsheets.parseProducts(merged).errors.single,
        contains('celdas combinadas'),
      );
      final external = rewriteParts(workbook([row()]), {
        'xl/_rels/workbook.xml.rels': (xml) => xml.replaceFirst(
          'Target="worksheets/sheet1.xml"',
          'Target="https://example.com/sheet.xml" TargetMode="External"',
        ),
      });
      expect(
        CapcSpreadsheets.parseProducts(external).errors.single,
        contains('dentro del archivo'),
      );
    },
  );

  test(
    'rejects fractions, negatives, symbols and values outside repository ranges',
    () {
      final invalid = <Object?>[1.5, -1, '1.000', r'$500', 1000000000000, null];
      for (final price in invalid) {
        final data = row()..[6] = price;
        final preview = parse([data]);
        expect(preview.canImport, isFalse, reason: '$price must be rejected');
        expect(preview.errors.join(' '), contains('Precio de venta'));
      }
      final stock = row()..[7] = 1000000001;
      expect(parse([stock]).errors.join(' '), contains('Stock inicial'));
      final overflow = row()
        ..[5] = 999999999999
        ..[7] = 1000000000;
      expect(
        parse([overflow]).errors.join(' '),
        contains('costo del stock inicial'),
      );
    },
  );

  test('rejects missing names and dates in numeric fields', () {
    final blankName = row()..[1] = '   ';
    expect(parse([blankName]).errors.join(' '), contains('Nombre'));
    final date = row()..[6] = DateTime(2026, 9, 25);
    expect(parse([date]).errors.join(' '), contains('Precio de venta'));
  });

  test(
    'generic exports keep numbers and dates typed and formulas as literal text',
    () {
      final bytes = CapcSpreadsheets.exportTable(
        title: 'Ventas',
        headers: ['Fecha', 'Total', 'Margen', 'Cliente'],
        rows: [
          [
            DateTime(2026, 9, 25, 14, 30),
            15000,
            12.5,
            '=HYPERLINK("https://example.com")',
          ],
        ],
        notes: ['Resumen de ventas'],
      );
      final book = Excel.decodeBytes(bytes);
      final cells = book['Ventas'].row(1);
      expect(cells[0]?.value, isA<DateTimeCellValue>());
      expect(cells[1]?.value, isA<IntCellValue>());
      expect(cells[2]?.value, isA<DoubleCellValue>());
      expect(cells[3]?.value, isA<TextCellValue>());
      expect(book.tables.keys, contains('Notas'));
    },
  );

  test('malformed, oversized and wrong-sheet files show actionable errors', () {
    expect(
      CapcSpreadsheets.parseProducts([1, 2, 3]).errors.single,
      contains('.xlsx'),
    );
    expect(
      CapcSpreadsheets.parseProducts(
        Uint8List(CapcSpreadsheets.maxImportBytes + 1),
      ).errors.single,
      contains('10 MB'),
    );
    final other = CapcSpreadsheets.exportTable(
      title: 'Hoja1',
      headers: ['Código'],
      rows: const [],
    );
    expect(
      CapcSpreadsheets.parseProducts(other).errors.single,
      contains('Falta la hoja'),
    );
  });

  test('integers above Excel precision are exact text with an explanation', () {
    final bytes = CapcSpreadsheets.exportTable(
      title: 'Saldos',
      headers: ['Cliente', 'Saldo'],
      rows: [
        ['Cliente A', 12345678901234567],
      ],
    );
    final book = Excel.decodeBytes(bytes);
    expect(book['Saldos'].row(1)[1]?.value, isA<TextCellValue>());
    expect(book['Saldos'].row(1)[1]?.value.toString(), '12345678901234567');
    expect(book['Notas'].row(1)[0]?.value.toString(), contains('15 cifras'));
  });

  test('more than 5000 records blocks the whole import', () {
    final rows = List.generate(
      CapcSpreadsheets.maxImportRows + 1,
      (i) => row(code: 'P$i'),
    );
    final preview = parse(rows);
    expect(preview.canImport, isFalse);
    expect(preview.errors.single, contains('supera 5000'));
  });
}
