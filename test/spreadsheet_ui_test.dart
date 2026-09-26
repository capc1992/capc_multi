import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/services/spreadsheets.dart';
import 'package:capc_multiservicio/ui/spreadsheet_actions.dart';
import 'package:excel_community/excel_community.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ui_flow_test.dart'
    show capture, databaseFrames, dialogFrames, navigateTo, openTestApp;

class TestFileSelector extends FileSelectorPlatform {
  XFile? selectedFile;
  FileSaveLocation? saveLocation;
  List<XTypeGroup>? acceptedTypes;
  SaveDialogOptions? saveOptions;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    acceptedTypes = acceptedTypeGroups;
    return selectedFile;
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    acceptedTypes = acceptedTypeGroups;
    saveOptions = options;
    return saveLocation;
  }
}

Product importProduct({String code = '000491', bool service = false}) =>
    Product(
      id: '',
      code: code,
      name: service ? 'Digitalización de planos' : 'Cuaderno importado',
      unit: service ? 'Página' : 'Unidad',
      isService: service,
      purchasePrice: service ? 200 : 1200,
      salePrice: service ? 1500 : 3000,
      stock: service ? 0 : 20,
      minimumStock: service ? 0 : 3,
      category: service ? 'Servicios' : 'Papelería',
    );

Future<File> workbookFile(WidgetTester tester, List<Product> products) async {
  late File file;
  late Directory directory;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('capc_excel_ui_');
    file = File(p.join(directory.path, 'catalogo.xlsx'));
    await file.writeAsBytes(CapcSpreadsheets.exportProducts(products));
  });
  addTearDown(() async {
    if (await file.exists()) await file.delete();
    if (await directory.exists()) await directory.delete();
  });
  return file;
}

Future<void> importFrames(WidgetTester tester) async {
  final progress = find.descendant(
    of: find.byType(ProductImportDialog),
    matching: find.byType(LinearProgressIndicator),
  );
  await tester.pump();
  for (var i = 0; i < 100; i++) {
    if (progress.evaluate().isEmpty) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(progress, findsNothing);
  await dialogFrames(tester);
}

Future<CapcRepository> openImport(
  WidgetTester tester,
  TestFileSelector selector,
  List<Product> products,
) async {
  final repository = await openTestApp(tester, const Size(1440, 1100));
  addTearDown(repository.close);
  selector.selectedFile = XFile((await workbookFile(tester, products)).path);
  await navigateTo(tester, 'Inventario');
  await tester.tap(find.widgetWithText(OutlinedButton, 'Importar Excel'));
  await dialogFrames(tester);
  await tester.tap(find.text('Seleccionar Excel'));
  await importFrames(tester);
  expect(selector.acceptedTypes!.single.extensions, ['xlsx']);
  return repository;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late TestFileSelector selector;
  late FileSelectorPlatform originalSelector;

  setUp(() {
    originalSelector = FileSelectorPlatform.instance;
    selector = TestFileSelector();
    FileSelectorPlatform.instance = selector;
  });

  tearDown(() {
    FileSelectorPlatform.instance = originalSelector;
  });

  testWidgets(
    'Vista previa no escribe y confirmar importa productos y servicios',
    (tester) async {
      final repository = await openImport(tester, selector, [
        importProduct(),
        importProduct(code: 'SER-IMPORT', service: true),
      ]);
      expect(
        find.text('Productos: 1. Servicios: 1. Listos para importar.'),
        findsOneWidget,
      );
      await capture(tester, '13-excel-vista-previa');
      late int initialCount;
      await tester.runAsync(() async {
        final products = await repository.listProducts();
        initialCount = products.length;
        expect(products.where((p) => p.code == '000491'), isEmpty);
        expect(products.where((p) => p.code == 'SER-IMPORT'), isEmpty);
      });
      final confirm = find.widgetWithText(FilledButton, 'Importar 2 registros');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await importFrames(tester);
      await databaseFrames(tester);
      expect(find.byType(ProductImportDialog), findsNothing);
      await tester.runAsync(() async {
        final products = await repository.listProducts();
        expect(products, hasLength(initialCount + 2));
        final material = products.singleWhere((p) => p.code == '000491');
        final service = products.singleWhere((p) => p.code == 'SER-IMPORT');
        expect(material.stock, 20);
        expect(material.salePrice, 3000);
        expect(material.minimumStock, 3);
        expect(service.isService, isTrue);
        expect(service.stock, 0);
        expect(
          await repository.listStockMovements(productId: material.id),
          hasLength(1),
        );
      });
      await tester.enterText(
        find.widgetWithText(TextField, 'Buscar producto, servicio o código'),
        '000491',
      );
      await tester.pumpAndSettle();
      expect(find.text('Cuaderno importado'), findsOneWidget);
      await capture(tester, '14-excel-producto-importado');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Código existente bloquea todo el archivo y permite corregirlo', (
    tester,
  ) async {
    final repository = await openImport(tester, selector, [
      importProduct(),
      importProduct(code: 'MAT-003'),
    ]);
    expect(
      find.textContaining('No se ha importado ningún registro.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('"MAT-003" ya existe en el catálogo.'),
      findsOneWidget,
    );
    final confirm = find.widgetWithText(FilledButton, 'Importar 2 registros');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.runAsync(() async {
      final products = await repository.listProducts();
      expect(products.where((p) => p.code == '000491'), isEmpty);
      final original = products.singleWhere((p) => p.code == 'MAT-003');
      expect(original.name, 'Memoria USB 32 GB');
      expect(original.stock, 8);
    });
    selector.selectedFile = XFile(
      (await workbookFile(tester, [importProduct()])).path,
    );
    await tester.tap(find.text('Cambiar archivo'));
    await importFrames(tester);
    expect(
      find.textContaining('No se ha importado ningún registro.'),
      findsNothing,
    );
    expect(
      find.text('Productos: 1. Servicios: 0. Listos para importar.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Importar 1 registro'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(
        (await repository.listProducts()).where((p) => p.code == '000491'),
        isEmpty,
      );
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Cancelar después de revisar un Excel no guarda registros', (
    tester,
  ) async {
    final repository = await openImport(tester, selector, [importProduct()]);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductImportDialog), findsNothing);
    await tester.runAsync(() async {
      expect(
        (await repository.listProducts()).where((p) => p.code == '000491'),
        isEmpty,
      );
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Cancelar guardar Excel no construye el archivo', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => saveExcelFile(
                context,
                name: 'Catalogo',
                build: () async {
                  builds++;
                  return CapcSpreadsheets.productTemplate();
                },
              ),
              child: const Text('Guardar'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(builds, 0);
    expect(selector.saveOptions!.suggestedName, 'Catalogo.xlsx');
    expect(selector.acceptedTypes!.single.extensions, ['xlsx']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Cancelar reemplazo conserva el Excel existente y no genera otro',
    (tester) async {
      final existing = await workbookFile(tester, [importProduct()]);
      late List<int> originalBytes;
      await tester.runAsync(() async {
        originalBytes = await existing.readAsBytes();
      });
      selector.saveLocation = FileSaveLocation(
        p.withoutExtension(existing.path),
      );
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => saveExcelFile(
                  context,
                  name: 'Catalogo',
                  build: () async {
                    builds++;
                    return CapcSpreadsheets.exportProducts([]);
                  },
                ),
                child: const Text('Guardar'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Guardar'));
      await databaseFrames(tester);
      expect(find.text('Reemplazar archivo de Excel'), findsOneWidget);
      expect(builds, 0);
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();
      expect(builds, 0);
      await tester.runAsync(() async {
        expect(await existing.readAsBytes(), originalBytes);
        expect(await File(p.withoutExtension(existing.path)).exists(), isFalse);
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Inventario pagina 50 ítems y exporta todos los resultados filtrados',
    (tester) async {
      final repository = await openTestApp(tester, const Size(1440, 1100));
      addTearDown(repository.close);
      await tester.runAsync(() async {
        await repository.importProducts([
          for (var i = 1; i <= 51; i++)
            Product(
              id: '',
              code: 'PAGE-${i.toString().padLeft(3, '0')}',
              name: 'Prueba página ${i.toString().padLeft(3, '0')}',
              unit: 'Unidad',
              isService: false,
              purchasePrice: 500,
              salePrice: 1000,
              stock: 20,
              minimumStock: 2,
            ),
        ]);
      });
      await tester.tap(find.byTooltip('Actualizar datos'));
      await databaseFrames(tester);
      await navigateTo(tester, 'Inventario');
      final search = find.widgetWithText(
        TextField,
        'Buscar producto, servicio o código',
      );
      await tester.enterText(search, 'PAGE-');
      await tester.pumpAndSettle();
      expect(find.text('1–50 de 51'), findsOneWidget);
      expect(find.text('Prueba página 001'), findsOneWidget);
      expect(find.text('Prueba página 051'), findsNothing);
      await tester.tap(find.byKey(const Key('inventory-next-page')));
      await tester.pumpAndSettle();
      expect(find.text('51–51 de 51'), findsOneWidget);
      expect(find.text('Prueba página 051'), findsOneWidget);
      expect(find.text('Prueba página 001'), findsNothing);

      final source = await workbookFile(tester, []);
      final exported = File(p.join(source.parent.path, 'exportado.xlsx'));
      addTearDown(() async {
        if (await exported.exists()) await exported.delete();
      });
      selector.saveLocation = FileSaveLocation(exported.path);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Exportar Excel'));
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !await exported.exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
      await databaseFrames(tester);
      await tester.runAsync(() async {
        final preview = CapcSpreadsheets.parseProducts(
          await exported.readAsBytes(),
        );
        expect(preview.errors, isEmpty);
        expect(preview.products, hasLength(51));
        expect(preview.products.first.code, 'PAGE-001');
        expect(preview.products.last.code, 'PAGE-051');
      });

      await tester.enterText(search, 'PAGE-001');
      await tester.pumpAndSettle();
      expect(find.text('1–1 de 1'), findsOneWidget);
      expect(find.text('Prueba página 001'), findsOneWidget);
      await tester.tap(find.byTooltip('Limpiar búsqueda'));
      await tester.pumpAndSettle();
      await tester.enterText(search, 'PAGE-');
      await tester.pumpAndSettle();
      expect(find.text('1–50 de 51'), findsOneWidget);
      await tester.tap(find.byKey(const Key('inventory-next-page')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final last = (await repository.listProducts()).singleWhere(
          (product) => product.code == 'PAGE-051',
        );
        await repository.saveProduct(
          Product(
            id: last.id,
            code: 'OTHER-051',
            name: last.name,
            unit: last.unit,
            isService: last.isService,
            purchasePrice: last.purchasePrice,
            salePrice: last.salePrice,
            stock: last.stock,
            minimumStock: last.minimumStock,
          ),
        );
      });
      await tester.tap(find.byTooltip('Actualizar datos'));
      await databaseFrames(tester);
      expect(find.text('1–50 de 50'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('inventory-next-page')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('Exportar tabla conserva cantidades numéricas y códigos como texto', () {
    final book = Excel.decodeBytes(
      CapcSpreadsheets.exportTable(
        title: 'Resumen',
        headers: ['Código', 'Cantidad', 'Precio COP'],
        rows: [
          ['000491', 20, 3000],
        ],
      ),
    );
    final row = book.tables['Resumen']!.row(1);
    expect(row[0]!.value, isA<TextCellValue>());
    expect(row[0]!.value.toString(), '000491');
    expect(row[1]!.value, isA<IntCellValue>());
    expect((row[1]!.value! as IntCellValue).value, 20);
    expect(row[2]!.value, isA<IntCellValue>());
    expect((row[2]!.value! as IntCellValue).value, 3000);
  });
}
