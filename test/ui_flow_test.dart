import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/ui/capc_app.dart';
import 'package:capc_multiservicio/ui/line_editor.dart';
import 'package:capc_multiservicio/ui/ui_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<void> databaseFrames(WidgetTester tester) async {
  // SQLite runs on another isolate, so allow real time outside fake async.
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> dialogFrames(WidgetTester tester) async {
  // Management keeps its progress indicator active while a dialog is open.
  // Advance route animations without waiting for that indicator to stop.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> navigateTo(WidgetTester tester, String page) async {
  final target = find.byKey(ValueKey('navigation-$page'));
  await tester.ensureVisible(target);
  // ensureVisible changes the scroll offset; render/hit-test geometry is only
  // updated on the following frame, especially when returning up the sidebar.
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget, reason: 'Acceso visible: $page');
  await tester.tap(target);
  await databaseFrames(tester);
  expect(
    tester.widget<Text>(find.byKey(const Key('page-title'))).data,
    page,
    reason: 'La navegación debe abrir efectivamente $page',
  );
}

Future<void> capture(WidgetTester tester, String name) async {
  final output =
      Platform.environment['CAPC_UI_QA_DIR'] ??
      const String.fromEnvironment('CAPC_UI_QA_DIR');
  if (output.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('qa-root')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File(
      p.join(output, '$name.png'),
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<CapcRepository> openTestApp(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late CapcRepository repository;
  await tester.runAsync(() async {
    repository = await CapcRepository.open(':memory:');
    await repository.setupOwner(
      name: 'Ana Administradora',
      username: 'propietario',
      password: 'ClavePrueba2026!',
    );
    await repository.openCash(100000);
    await repository.loadExampleCatalog();
    await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana Pérez'));
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await roboto.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('qa-root'),
      child: CapcApp(repository: repository),
    ),
  );
  await databaseFrames(tester);
  return repository;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('Formulario bloquea doble guardado antes de reconstruirse', (
    tester,
  ) async {
    var saves = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => entryDialog(
                context,
                title: 'Formulario',
                fields: const [EntryField('name', 'Nombre', value: 'Ana')],
                onSave: (_) async {
                  saves++;
                  await pending.future;
                },
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Guardar');
    await tester.tap(save);
    await tester.tap(save);
    expect(saves, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Formulario'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Actualizar datos recarga movimientos de Caja abierta', (
    tester,
  ) async {
    final repository = await openTestApp(tester, const Size(1200, 900));
    addTearDown(repository.close);
    await navigateTo(tester, 'Caja');
    await tester.runAsync(() async {
      await repository.addExpense(
        2500,
        'Gasto posterior a la carga',
        operationId: 'refresh-cash-ui',
      );
    });
    expect(find.text('Gasto posterior a la carga'), findsNothing);
    await tester.tap(find.byTooltip('Actualizar datos'));
    await databaseFrames(tester);
    expect(find.text('Gasto posterior a la carga'), findsOneWidget);
    expect(find.text('Efectivo esperado: \$ 97.500'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Borrador permite editar conceptos y conserva documento', (
    tester,
  ) async {
    final repository = await openTestApp(tester, const Size(1200, 1000));
    addTearDown(repository.close);
    late Quote original;
    await tester.runAsync(() async {
      final product = (await repository.listProducts()).singleWhere(
        (p) => p.code == 'MAT-003',
      );
      original = await repository.createQuote(
        customerId: 'ana',
        description: 'Memorias para entrega',
        items: [
          QuoteLineInput(
            productId: product.id,
            description: product.name,
            quantity: 1,
            unitPrice: product.salePrice,
          ),
        ],
        validUntil: DateTime.now().toUtc().add(const Duration(days: 7)),
        conditions: 'Entrega en tienda',
        operationId: 'editable-quote-ui',
      );
    });
    await navigateTo(tester, 'Cotizaciones y trabajos');
    await tester.tap(find.text('Editar borrador'));
    await dialogFrames(tester);
    await tester.tap(find.text('Editar concepto'));
    await dialogFrames(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Cantidad'), '3');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Precio unitario (COP)'),
      '26000',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar concepto'));
    await dialogFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
    await dialogFrames(tester);
    final description = find.widgetWithText(
      TextFormField,
      'Descripción del trabajo',
    );
    expect(
      tester.widget<TextFormField>(description).controller!.text,
      'Memorias para entrega',
    );
    await tester.enterText(description, 'Tres memorias para entrega');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Condiciones'),
      'Retiro al día siguiente',
    );
    await capture(tester, '06-editar-cotizacion');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await databaseFrames(tester);
    await tester.runAsync(() async {
      final saved = (await repository.listQuotes()).single;
      expect(saved.id, original.id);
      expect(saved.number, original.number);
      expect(saved.total, 78000);
      expect(saved.lines.single.quantity, 3);
      expect(saved.description, 'Tres memorias para entrega');
      expect(saved.conditions, 'Retiro al día siguiente');
      expect(await repository.listSales(), isEmpty);
    });
    await tester.tap(find.text('Cambiar estado'));
    await dialogFrames(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await dialogFrames(tester);
    expect(find.text('Borrador'), findsNothing);
    expect(find.text('Vencida'), findsNothing);
    await tester.tap(find.text('Aceptada').last);
    await dialogFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await databaseFrames(tester);
    expect(find.text('Editar borrador'), findsNothing);
    expect(find.text('Convertir en venta'), findsOneWidget);
    await tester.tap(find.text('Cambiar estado'));
    await dialogFrames(tester);
    final status = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(status.initialValue, QuoteStatus.rejected.name);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await dialogFrames(tester);
    expect(find.text('Enviada'), findsNothing);
    expect(find.text('Aceptada'), findsNothing);
    expect(find.text('Vencida'), findsNothing);
    await tester.tap(find.text('Rechazada').last);
    await dialogFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await databaseFrames(tester);
    expect(find.text('Cambiar estado'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Anticipo vinculado orienta a convertir su cotización', (
    tester,
  ) async {
    final repository = await openTestApp(tester, const Size(1200, 1000));
    addTearDown(repository.close);
    late Quote quote;
    await tester.runAsync(() async {
      quote = await repository.createQuote(
        customerId: 'ana',
        description: 'Trabajo autorizado',
        items: const [
          QuoteLineInput(
            description: 'Servicio personalizado',
            quantity: 1,
            unitPrice: 10000,
            directCost: 2000,
          ),
        ],
        validUntil: DateTime.now().toUtc().add(const Duration(days: 7)),
        operationId: 'advance-quote-ui',
      );
      await repository.updateQuoteStatus(quote.id, QuoteStatus.accepted);
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Preparar servicio',
        responsible: 'Ana Administradora',
        deliveryAt: DateTime.now().toUtc().add(const Duration(days: 2)),
        quoteId: quote.id,
        operationId: 'advance-work-ui',
      );
      await repository.addWorkAdvance(
        work.id,
        3000,
        'Efectivo',
        operationId: 'linked-advance-ui',
      );
    });
    await navigateTo(tester, 'Cotizaciones y trabajos');
    expect(find.text('Aplicar a una venta'), findsNothing);
    expect(find.text('Cambiar estado'), findsNothing);
    expect(find.text('Convertir en venta'), findsOneWidget);
    expect(
      find.text(
        'Los anticipos se aplicarán al convertir ${quote.number} en venta.',
      ),
      findsOneWidget,
    );
    await capture(tester, '07-trabajo-con-anticipo');
    for (final next in ['En proceso', 'Listo']) {
      await tester.ensureVisible(find.text('Actualizar trabajo'));
      await tester.tap(find.text('Actualizar trabajo'));
      await dialogFrames(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await dialogFrames(tester);
      expect(find.text('Entregado'), findsNothing);
      if (next == 'En proceso') expect(find.text('Listo'), findsNothing);
      await tester.tap(find.text(next).last);
      await dialogFrames(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await databaseFrames(tester);
    }
    await tester.ensureVisible(find.text('Actualizar trabajo'));
    await tester.tap(find.text('Actualizar trabajo'));
    await dialogFrames(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await dialogFrames(tester);
    expect(find.text('Entregado'), findsNothing);
    expect(find.text('En proceso'), findsNothing);
    expect(find.text('Recibido'), findsNothing);
    await tester.tap(find.text('Listo').last);
    await dialogFrames(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await databaseFrames(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final lot in [false, true]) {
    testWidgets(
      lot
          ? 'Compra conserva costo total exacto del lote'
          : 'Compra calcula costo unitario por cantidad',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        List<DraftLine>? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    selected = await editDocumentLines(context, [
                      const Product(
                        id: 'paper',
                        code: 'P1',
                        name: 'Papel carta',
                        unit: 'Hoja',
                        isService: false,
                        purchasePrice: 50,
                        salePrice: 100,
                        stock: 10,
                        minimumStock: 2,
                      ),
                    ], purchase: true);
                  },
                  child: const Text('Abrir compra'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Abrir compra'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agregar concepto'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('P1 · Papel carta').last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Continuar').last);
        await tester.pumpAndSettle();
        final cost = find.widgetWithText(
          TextFormField,
          'Costo de compra (COP)',
        );
        expect(tester.widget<TextFormField>(cost).controller!.text, isEmpty);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Cantidad'),
          '3',
        );
        if (lot) {
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Total del lote').last);
          await tester.pumpAndSettle();
        }
        await tester.enterText(cost, lot ? '301' : '100');
        await tester.tap(find.widgetWithText(FilledButton, 'Agregar concepto'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
        await tester.pumpAndSettle();
        expect(selected, hasLength(1));
        expect(selected!.single.quantity, 3);
        expect(selected!.single.price, lot ? 301 : 300);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Sugerencia usa materiales y solo cambia el precio al aplicarla',
    (tester) async {
      final repository = await openTestApp(tester, const Size(1200, 900));
      addTearDown(repository.close);
      await tester.runAsync(() async {
        final products = await repository.listProducts();
        final service = products.firstWhere((p) => p.code == 'SER-002');
        final paper = products.firstWhere((p) => p.code == 'MAT-001');
        await repository.setServiceRecipe(service.id, [
          ServiceMaterial(productId: paper.id, quantity: 2),
        ]);
      });
      await tester.tap(find.byTooltip('Inventario'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Buscar producto, servicio o código'),
        'SER-002',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Editar'));
      await tester.tap(find.widgetWithText(TextButton, 'Editar'));
      await databaseFrames(tester);
      final markup = find.widgetWithText(
        TextFormField,
        'Recargo elegido sobre costo (%)',
      );
      expect(tester.widget<TextFormField>(markup).controller!.text, isEmpty);
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'Costo directo adicional del servicio (COP)',
        ),
        '100',
      );
      await tester.ensureVisible(markup);
      await tester.enterText(markup, '50');
      final price = find.widgetWithText(TextFormField, 'Precio de venta (COP)');
      expect(tester.widget<TextFormField>(price).controller!.text, '4000');
      final apply = find.text('Aplicar precio sugerido (puedes editarlo)');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(price).controller!.text, '300');
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar ítem'));
      await databaseFrames(tester);
      await tester.runAsync(() async {
        final saved = (await repository.listProducts()).firstWhere(
          (p) => p.code == 'SER-002',
        );
        expect(saved.salePrice, 300);
        expect(saved.purchasePrice, 100);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Venta desde buscador se guarda una sola vez y descuenta stock', (
    tester,
  ) async {
    final repository = await openTestApp(tester, const Size(1440, 1000));
    addTearDown(repository.close);
    expect(tester.takeException(), isNull);
    await capture(tester, '01-resumen');
    await tester.tap(find.byTooltip('Nueva venta'));
    await tester.pumpAndSettle();
    final search = find.widgetWithText(TextField, 'Buscar por código o nombre');
    await tester.enterText(search, 'MAT-003');
    await tester.pumpAndSettle();
    expect(find.text('Memoria USB 32 GB'), findsOneWidget);
    await tester.tap(find.byTooltip('Agregar Memoria USB 32 GB'));
    await tester.pumpAndSettle();
    await capture(tester, '02-nueva-venta');
    final save = find.widgetWithText(FilledButton, 'Registrar venta');
    await tester.ensureVisible(save);
    await tester.tap(save);
    // The second tap is intentionally before the next frame: the state guard
    // must protect inventory and payment even before the button rebuilds.
    await tester.tap(save);
    await databaseFrames(tester);
    expect(find.text('Comprobante V-000001'), findsOneWidget);
    expect(
      find.text('Comprobante interno · Sin validez fiscal'),
      findsOneWidget,
    );
    await capture(tester, '03-comprobante');
    await tester.runAsync(() async {
      final sales = await repository.listSales();
      expect(sales, hasLength(1));
      expect(sales.single.total, 25000);
      expect(sales.single.paid, 25000);
      expect(sales.single.balance, 0);
      final usb = (await repository.listProducts()).singleWhere(
        (p) => p.code == 'MAT-003',
      );
      expect(usb.stock, 7);
      expect(await repository.listPayments(), hasLength(1));
    });
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(TextButton, 'Cerrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reportes'));
    await tester.pumpAndSettle();
    await capture(tester, '04-reportes');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Ventana compacta permite recorrer pantallas sin desbordar', (
    tester,
  ) async {
    final repository = await openTestApp(tester, const Size(1000, 700));
    addTearDown(repository.close);
    for (final page in [
      'Inventario',
      'Clientes y deudas',
      'Historial',
      'Reportes',
      'Configuración',
      'Caja',
      'Compras y proveedores',
      'Cotizaciones y trabajos',
      'Usuarios y auditoría',
      'Nueva venta',
    ]) {
      await navigateTo(tester, page);
      expect(tester.takeException(), isNull, reason: page);
    }
    await capture(tester, '05-venta-compacta');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Alta inicial sin contraseña predeterminada y cierre de sesión', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late CapcRepository repository;
    await tester.runAsync(() async {
      repository = await CapcRepository.open(':memory:');
    });
    addTearDown(repository.close);
    await tester.pumpWidget(CapcApp(repository: repository));
    await databaseFrames(tester);
    expect(find.text('Crea el primer propietario'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre del propietario'),
      'María Propietaria',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Usuario'),
      'maria',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Contraseña'),
      'MiClaveSegura2026!',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Repetir contraseña'),
      'MiClaveSegura2026!',
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Crear propietario'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Crear propietario'));
    final recoveryCode = find.byKey(const Key('recovery-code'));
    final recoveryError = find.textContaining(
      'No se pudo generar el código de recuperación.',
    );
    // Authentication is established before the second Argon2 operation creates
    // the recovery code. Wait for that operation's visible result as well.
    for (
      var i = 0;
      i < 400 &&
          recoveryCode.evaluate().isEmpty &&
          recoveryError.evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(repository.isAuthenticated, isTrue);
    expect(recoveryError, findsNothing);
    expect(recoveryCode, findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Guarda tu código de recuperación'), findsOneWidget);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Continuar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
    await databaseFrames(tester);
    expect(find.text('Tu negocio, al día'), findsOneWidget);
    await tester.tap(find.byTooltip('Cerrar sesión'));
    await databaseFrames(tester);
    expect(find.text('Ingresar a tu negocio'), findsOneWidget);
    expect(repository.isAuthenticated, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Abono en pantalla actualiza saldo y registra recibido y cambio',
    (tester) async {
      final repository = await openTestApp(tester, const Size(1200, 900));
      addTearDown(repository.close);
      await tester.runAsync(() async {
        final item = (await repository.listProducts()).firstWhere(
          (p) => p.code == 'MAT-003',
        );
        await repository.createSale(
          items: [CartLine(productId: item.id, quantity: 1)],
          customerId: 'ana',
          paid: 0,
          paymentMethod: 'Crédito',
          dueAt: DateTime.now().toUtc().add(const Duration(days: 7)),
          operationId: 'credit-ui',
        );
      });
      await tester.tap(find.byTooltip('Actualizar datos'));
      await databaseFrames(tester);
      await tester.tap(find.byTooltip('Clientes y deudas'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(OutlinedButton, 'Registrar abono'),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Registrar abono'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Valor del abono (COP)'),
        '10000',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Dinero recibido (COP)'),
        '20000',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Registrar abono'));
      await databaseFrames(tester);
      await tester.runAsync(() async {
        final sale = (await repository.listSales()).single;
        expect(sale.balance, 15000);
        final payment = (await repository.listPayments()).single;
        expect(payment.amount, 10000);
        expect(payment.received, 20000);
        expect(payment.change, 10000);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Cajero no ve acciones administrativas', (tester) async {
    final repository = await openTestApp(tester, const Size(1000, 700));
    addTearDown(repository.close);
    await tester.runAsync(() async {
      await repository.saveUser(
        name: 'Cajera',
        username: 'cajera',
        role: UserRole.cashier,
        password: 'ClaveCajera2026!',
      );
      repository.logout();
      await repository.login('cajera', 'ClaveCajera2026!');
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(CapcApp(repository: repository));
    await databaseFrames(tester);
    expect(find.byTooltip('Nueva venta'), findsOneWidget);
    expect(find.byTooltip('Inventario'), findsNothing);
    expect(find.byTooltip('Compras y proveedores'), findsNothing);
    expect(find.byTooltip('Usuarios y auditoría'), findsNothing);
    expect(find.text('Registrar producto'), findsNothing);
    await navigateTo(tester, 'Cotizaciones y trabajos');
    await tester.tap(find.text('Nueva cotización'));
    await dialogFrames(tester);
    await tester.tap(find.text('Agregar concepto'));
    await dialogFrames(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await dialogFrames(tester);
    expect(find.text('Trabajo personalizado'), findsNothing);
    await tester.tap(find.text('MAT-001 · Papel carta (hoja)').last);
    await dialogFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Continuar').last);
    await dialogFrames(tester);
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.widgetWithText(TextFormField, 'Precio unitario (COP)'),
              matching: find.byType(TextField),
            ),
          )
          .readOnly,
      isTrue,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar').last);
    await dialogFrames(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await databaseFrames(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Ventana 1000x700 y texto al 200% conserva navegación y formularios',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = await openTestApp(tester, const Size(1000, 700));
      addTearDown(repository.close);
      for (final page in [
        'Inventario',
        'Clientes y deudas',
        'Reportes',
        'Configuración',
        'Caja',
        'Compras y proveedores',
        'Cotizaciones y trabajos',
        'Usuarios y auditoría',
        'Nueva venta',
      ]) {
        await navigateTo(tester, page);
        expect(tester.takeException(), isNull, reason: 'Texto 200% en $page');
        await capture(tester, 'texto200-${page.replaceAll(' ', '-')}');
      }
      await navigateTo(tester, 'Inventario');
      await tester.tap(find.text('Nuevo producto o servicio'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'texto200-formulario-producto');
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
