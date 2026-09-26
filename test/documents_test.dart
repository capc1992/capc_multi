import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:capc_multiservicio/data/models.dart';
import 'package:capc_multiservicio/services/documents.dart';

Sale _sale({
  String id = 'sale-1',
  DateTime? at,
  int total = 10000,
  int paid = 2500,
  List<SaleLine>? lines,
}) => Sale(
  id: id,
  number: 'V-2026-0001-$id',
  createdAt: at ?? DateTime.utc(2026, 9, 25, 1, 32, 15),
  lines:
      lines ??
      [
        SaleLine(
          productId: 'product-1',
          code: 'IMP-01',
          name: 'Impresión a color tamaño carta',
          unit: 'hoja',
          isService: true,
          quantity: 10,
          unitPrice: 1000,
          unitCost: 300,
        ),
      ],
  customerId: 'customer-1',
  customerName: 'María José Rodríguez',
  operatorName: 'Caja principal - Andrés',
  total: total,
  paid: paid,
  received: paid,
  paymentMethod: 'Efectivo',
);

Payment _payment(String id, String saleId, DateTime at, int amount) => Payment(
  id: id,
  saleId: saleId,
  amount: amount,
  createdAt: at,
  method: 'Efectivo',
);

int _pageCount(Uint8List bytes) =>
    RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length;

void _expectPdf(Uint8List bytes) {
  expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
  expect(bytes.length, greaterThan(1000));
  expect(_pageCount(bytes), greaterThan(0));
}

// An opt-in directory allows the developer to render these exact tested PDFs
// for visual QA without writing documents into a user's normal folders.
Future<void> _qaCopy(String name, Uint8List bytes) async {
  final directory = Platform.environment['CAPC_PDF_QA_DIR'];
  if (directory == null || directory.isEmpty) return;
  await Directory(directory).create(recursive: true);
  await File('$directory${Platform.pathSeparator}$name').writeAsBytes(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Report period in Bogotá', () {
    test(
      'includes both civil-day boundaries and excludes adjacent instants',
      () {
        final report = CapcReportData.forPeriod(
          [
            _sale(id: 'before', at: DateTime.utc(2026, 9, 24, 4, 59, 59, 999)),
            _sale(id: 'first', at: DateTime.utc(2026, 9, 24, 5)),
            _sale(id: 'last', at: DateTime.utc(2026, 9, 25, 4, 59, 59, 999)),
            _sale(id: 'after', at: DateTime.utc(2026, 9, 25, 5)),
          ],
          [],
          DateTime(2026, 9, 24),
          DateTime(2026, 9, 24),
        );

        expect(report.sales.map((sale) => sale.id), ['first', 'last']);
        expect(report.totalSales, 20000);
        expect(report.outstandingBalance, 15000);
      },
    );

    test(
      'counts initial payments and abonos by payment date, including older sales',
      () {
        final report = CapcReportData.forPeriod(
          [
            _sale(
              id: 'older',
              at: DateTime.utc(2026, 9, 23, 12),
              total: 20000,
              paid: 15000,
            ),
            _sale(
              id: 'today',
              at: DateTime.utc(2026, 9, 24, 12),
              total: 10000,
              paid: 8000,
            ),
          ],
          [
            _payment(
              'old-initial',
              'older',
              DateTime.utc(2026, 9, 23, 12),
              10000,
            ),
            _payment('old-abono', 'older', DateTime.utc(2026, 9, 24, 8), 5000),
            _payment('initial', 'today', DateTime.utc(2026, 9, 24, 12), 3000),
            _payment('abono', 'today', DateTime.utc(2026, 9, 24, 20), 2000),
            _payment('later', 'today', DateTime.utc(2026, 9, 25, 12), 3000),
          ],
          DateTime(2026, 9, 24),
          DateTime(2026, 9, 24),
        );

        expect(report.sales.single.id, 'today');
        expect(report.payments.map((payment) => payment.id), [
          'old-abono',
          'initial',
          'abono',
        ]);
        expect(report.totalSales, 10000);
        expect(report.totalCollected, 10000);
        // Current balance includes a later abono; it is not a historical balance.
        expect(report.outstandingBalance, 2000);
      },
    );

    test('uses inclusive civil dates across month boundaries', () {
      final report = CapcReportData.forPeriod(
        [
          _sale(
            id: 'last-month',
            at: DateTime.parse('2026-09-30T23:59:59-05:00'),
          ),
          _sale(
            id: 'first-month',
            at: DateTime.parse('2026-10-01T00:00:00-05:00'),
          ),
        ],
        [],
        DateTime(2026, 9, 30),
        DateTime(2026, 10, 1),
      );
      expect(report.sales.length, 2);
    });

    test('rejects an inverted date range', () {
      expect(
        () => CapcReportData.forPeriod(
          [],
          [],
          DateTime(2026, 9, 25),
          DateTime(2026, 9, 24),
        ),
        throwsArgumentError,
      );
    });
  });

  group('Offline PDF generation without a printer', () {
    test(
      'creates a Carta sale with accented text and outstanding balance',
      () async {
        final bytes = await CapcDocuments.buildSale(_sale());
        _expectPdf(bytes);
        expect(_pageCount(bytes), 1);
        expect(
          latin1.decode(bytes),
          matches(
            RegExp(
              r'/MediaBox\s*\[\s*0\s+0\s+612(?:\.0+)?\s+792(?:\.0+)?\s*\]',
            ),
          ),
        );
        await _qaCopy('venta-carta.pdf', bytes);
      },
    );

    test('paginates a long 80 mm ticket', () async {
      final lines = List.generate(
        120,
        (index) => SaleLine(
          productId: 'product-$index',
          code: 'P-${index + 1}',
          name: 'Impresión y encuadernación de trabajo académico ${index + 1}',
          unit: 'unidad',
          isService: true,
          quantity: 2,
          unitPrice: 12500,
          unitCost: 5000,
        ),
      );
      final bytes = await CapcDocuments.buildSale(
        _sale(lines: lines, total: 3000000, paid: 1000000),
        ticket: true,
      );
      _expectPdf(bytes);
      expect(_pageCount(bytes), greaterThan(1));
      final mediaBox = RegExp(
        r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]',
      ).firstMatch(latin1.decode(bytes));
      expect(mediaBox, isNotNull);
      expect(double.parse(mediaBox!.group(1)!), closeTo(80 * 72 / 25.4, 0.01));
      await _qaCopy('venta-tirilla-larga.pdf', bytes);
    });

    test('creates a one-page 80 mm ticket for a normal sale', () async {
      final bytes = await CapcDocuments.buildSale(_sale(), ticket: true);
      _expectPdf(bytes);
      expect(_pageCount(bytes), 1);
      await _qaCopy('venta-tirilla.pdf', bytes);
    });

    test('creates an empty report', () async {
      final bytes = await CapcDocuments.buildReport(
        [],
        [],
        DateTime(2026, 9, 24),
        DateTime(2026, 9, 24),
      );
      _expectPdf(bytes);
      expect(_pageCount(bytes), 1);
      await _qaCopy('reporte-vacio.pdf', bytes);
    });

    test('paginates long sales and collection tables', () async {
      final sales = List.generate(100, (index) => _sale(id: 'venta-$index'));
      final payments = List.generate(
        100,
        (index) => _payment(
          'payment-$index',
          'venta-$index',
          DateTime.utc(2026, 9, 25, 1, 32, 15),
          2500,
        ),
      );
      final bytes = await CapcDocuments.buildReport(
        sales,
        payments,
        DateTime(2026, 9, 24),
        DateTime(2026, 9, 24),
      );
      _expectPdf(bytes);
      expect(_pageCount(bytes), greaterThan(2));
      await _qaCopy('reporte-largo.pdf', bytes);
    });

    test(
      'account statements include documents and a long payment history',
      () async {
        const customer = Customer(
          id: 'customer-1',
          name: 'María José Rodríguez',
          phone: '300 123 4567',
        );
        final sales = List.generate(40, (i) => _sale(id: 'cuenta-$i'));
        final payments = [
          for (final sale in sales)
            _payment('p-${sale.id}', sale.id, sale.createdAt, sale.paid),
        ];
        final bytes = await CapcDocuments.buildStatement(
          customer,
          sales,
          payments,
        );
        _expectPdf(bytes);
        expect(_pageCount(bytes), greaterThan(1));
        await _qaCopy('estado-cuenta-largo.pdf', bytes);
      },
    );

    test(
      'generic quote/report tables paginate long descriptions and conditions',
      () async {
        final bytes = await CapcDocuments.buildTableDocument(
          title: 'Cotización de trabajo personalizado',
          headers: ['Descripción', 'Cantidad', 'Precio', 'Total'],
          rows: List.generate(
            50,
            (i) => [
              'Trabajo ${i + 1}: impresión, encuadernación y entrega de documentos para María José Rodríguez. Código ${'A' * 80}',
              '100',
              r'$ 1.000',
              r'$ 100.000',
            ],
          ),
          notes: [
            'Cliente: María José Rodríguez',
            'Vigencia: 30/09/2026',
            'Condiciones: cotización sin cobro ni descuento de inventario. Confirmar materiales y fecha de entrega antes de aceptar.',
          ],
        );
        _expectPdf(bytes);
        expect(_pageCount(bytes), greaterThan(1));
        await _qaCopy('cotizacion-larga.pdf', bytes);
      },
    );

    test(
      'a compensated receipt preserves original lines and current balances',
      () async {
        final sale = Sale(
          id: 'compensada',
          number: 'V-000099',
          createdAt: DateTime.utc(2026, 9, 24, 14),
          lines: _sale().lines,
          customerId: 'customer-1',
          customerName: 'María José Rodríguez',
          operatorName: 'Propietario',
          total: 10000,
          paid: 6000,
          paymentMethod: 'Efectivo',
          received: 20000,
          change: 10000,
          returnedTotal: 4000,
          refunded: 4000,
          dueAt: DateTime.utc(2026, 10, 1, 5),
        );
        final bytes = await CapcDocuments.buildSale(sale, ticket: true);
        _expectPdf(bytes);
        await _qaCopy('venta-devolucion-tirilla.pdf', bytes);
      },
    );
  });
}
