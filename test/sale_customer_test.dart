import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_flow_test.dart'
    show capture, databaseFrames, navigateTo, openTestApp;

Finder dropdown(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is DropdownButtonFormField<String> &&
      widget.decoration.labelText == label,
);

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> selectOption(
  WidgetTester tester,
  String label,
  String option,
) async {
  await tapVisible(tester, dropdown(label));
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<CapcRepository> prepareSale(WidgetTester tester) async {
  final repository = await openTestApp(tester, const Size(1440, 1100));
  addTearDown(repository.close);
  await navigateTo(tester, 'Nueva venta');
  await tester.enterText(
    find.widgetWithText(TextField, 'Buscar por código o nombre'),
    'MAT-003',
  );
  await tester.pumpAndSettle();
  await tapVisible(tester, find.byTooltip('Agregar Memoria USB 32 GB'));
  await selectOption(tester, 'Cliente', 'Ana Pérez');
  return repository;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'Nuevo cliente se selecciona y conserva la venta y el abono al guardar',
    (tester) async {
      final repository = await prepareSale(tester);
      await tapVisible(
        tester,
        find.byTooltip('Aumentar cantidad de Memoria USB 32 GB'),
      );
      await selectOption(tester, 'Estado del pago', 'Abono parcial');
      await tester.enterText(
        find.widgetWithText(TextField, 'Abono inicial (COP)'),
        '10000',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Dinero recibido (COP)'),
        '15000',
      );
      await tapVisible(tester, find.text('Definir vencimiento'));
      final confirmDate = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      ).okButtonLabel;
      await tester.tap(find.text(confirmDate));
      await tester.pumpAndSettle();
      final dueDateLabel = tester
          .widget<Text>(
            find.byWidgetPredicate(
              (w) => w is Text && (w.data?.startsWith('Vence: ') ?? false),
            ),
          )
          .data;

      await tapVisible(
        tester,
        find.widgetWithText(TextButton, 'Nuevo cliente'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nombre del cliente'),
        'Beatriz Gómez',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Teléfono (opcional)'),
        '3001234567',
      );
      await capture(tester, '11-cliente-desde-venta');
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar cliente'));
      await databaseFrames(tester);

      late Customer created;
      await tester.runAsync(() async {
        final customers = await repository.listCustomers();
        expect(customers, hasLength(2));
        created = customers.singleWhere((c) => c.name == 'Beatriz Gómez');
        expect(created.phone, '3001234567');
      });
      expect(
        tester.state<FormFieldState<String>>(dropdown('Cliente')).value,
        created.id,
      );
      expect(
        tester.state<FormFieldState<String>>(dropdown('Estado del pago')).value,
        'Parcial',
      );
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Abono inicial (COP)'),
            )
            .controller!
            .text,
        '10000',
      );
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Dinero recibido (COP)'),
            )
            .controller!
            .text,
        '15000',
      );
      expect(find.text(dueDateLabel!), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('page-title'))).data,
        'Nueva venta',
      );
      await capture(tester, '12-cliente-seleccionado-en-venta');
      final save = find.widgetWithText(FilledButton, 'Registrar venta');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await databaseFrames(tester);

      expect(find.text('Comprobante V-000001'), findsOneWidget);
      await tester.runAsync(() async {
        final sale = (await repository.listSales()).single;
        expect(sale.customerId, created.id);
        expect(sale.customerName, 'Beatriz Gómez');
        expect(sale.lines.single.quantity, 2);
        expect(sale.total, 50000);
        expect(sale.paid, 10000);
        expect(sale.received, 15000);
        expect(sale.change, 5000);
        expect(sale.balance, 40000);
        expect(sale.dueAt, isNotNull);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Cancelar nuevo cliente conserva el cliente y el carrito', (
    tester,
  ) async {
    final repository = await prepareSale(tester);
    await tapVisible(tester, find.widgetWithText(TextButton, 'Nuevo cliente'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre del cliente'),
      'Cliente sin guardar',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(
      tester.state<FormFieldState<String>>(dropdown('Cliente')).value,
      'ana',
    );
    final save = find.widgetWithText(FilledButton, 'Registrar venta');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await databaseFrames(tester);
    await tester.runAsync(() async {
      expect(await repository.listCustomers(), hasLength(1));
      final sale = (await repository.listSales()).single;
      expect(sale.customerId, 'ana');
      expect(sale.lines.single.quantity, 1);
      expect(sale.total, 25000);
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Editar cliente existente conserva su identidad y selección', (
    tester,
  ) async {
    final repository = await prepareSale(tester);
    await navigateTo(tester, 'Clientes y deudas');
    await tapVisible(tester, find.byTooltip('Editar Ana Pérez'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre del cliente'),
      'Ana Pérez actualizada',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar cliente'));
    await databaseFrames(tester);
    await navigateTo(tester, 'Nueva venta');
    expect(
      tester.state<FormFieldState<String>>(dropdown('Cliente')).value,
      'ana',
    );
    expect(find.text('Ana Pérez actualizada'), findsOneWidget);
    await tester.runAsync(() async {
      final customers = await repository.listCustomers();
      expect(customers, hasLength(1));
      expect(customers.single.id, 'ana');
      expect(customers.single.name, 'Ana Pérez actualizada');
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
