import 'package:capc_multiservicio/data/models.dart';
import 'package:capc_multiservicio/services/reporting.dart';
import 'package:flutter_test/flutter_test.dart';

Sale sample({String basis = 'weighted', bool known = true}) => Sale(
  id: 'sale',
  number: 'V-000001',
  createdAt: DateTime.utc(2026, 9, 20, 12),
  customerName: 'Cliente',
  operatorName: 'Responsable',
  total: 300,
  paid: 200,
  paymentMethod: 'Efectivo',
  returnedTotal: 100,
  refunded: 100,
  lines: [
    SaleLine(
      id: 'line',
      productId: 'product',
      code: 'P',
      name: 'Material',
      unit: 'Unidad',
      isService: false,
      quantity: 3,
      unitPrice: 100,
      unitCost: 33,
      costTotalMicros: 100000000,
      costKnown: known,
      costBasis: basis,
      returnedQuantity: 1,
      recoveredCostMicros: 33333333,
    ),
  ],
);

SaleReturnRecord returned({int cost = 33333333}) => SaleReturnRecord(
  id: 'return',
  saleId: 'sale',
  number: 'D-000001',
  createdAt: DateTime.utc(2026, 9, 25, 12),
  amount: 100,
  refund: 100,
  method: 'Efectivo',
  actorName: 'Responsable',
  reason: 'Material recuperado',
  costReversedMicros: cost,
  items: const [SaleReturnItem(saleLineId: 'line', quantity: 1)],
);

void main() {
  test('aggregating individually valid sales never overflows 64-bit costs', () {
    final sales = List.generate(
      2,
      (i) => Sale(
        id: 'large-$i',
        number: 'V-$i',
        createdAt: DateTime.utc(2026, 9, 25, 12),
        customerName: 'Cliente',
        operatorName: 'Propietario',
        total: 9000000,
        paid: 9000000,
        paymentMethod: 'Transferencia',
        lines: [
          SaleLine(
            id: 'line-$i',
            productId: 'product',
            code: 'P',
            name: 'Material',
            unit: 'Unidad',
            isService: false,
            quantity: 9000000,
            unitPrice: 1,
            unitCost: 1000000,
            costTotalMicros: 9000000000000000000,
            costBasis: 'weighted',
          ),
        ],
      ),
    );
    final report = SalesPeriodReport(
      sales: sales,
      payments: [],
      returns: [],
      from: DateTime(2026, 9, 25),
      to: DateTime(2026, 9, 25),
    );
    expect(report.netCostMicros, BigInt.parse('18000000000000000000'));
    expect(
      report.grossProfitMicros,
      BigInt.from(18000000) * BigInt.from(1000000) -
          BigInt.parse('18000000000000000000'),
    );
    expect(
      SalesPeriodReport.moneyMicros(report.grossProfitMicros!),
      r'-$ 17.999.982.000.000',
    );
  });
  test('a later return never rewrites the original period sales or costs', () {
    final report = SalesPeriodReport(
      sales: [sample()],
      payments: [],
      returns: [returned()],
      from: DateTime(2026, 9, 20),
      to: DateTime(2026, 9, 20),
    );
    expect(report.grossSales, BigInt.from(300));
    expect(report.netSales, BigInt.from(300));
    expect(report.netCostMicros, BigInt.from(100000000));
    expect(report.grossProfitMicros, BigInt.from(200000000));
    expect(report.bestSellerRows.single[1], '3');
  });

  test(
    'return period recognizes credit and recovered historical cost once',
    () {
      final report = SalesPeriodReport(
        sales: [sample()],
        payments: [
          Payment(
            id: 'refund',
            saleId: 'sale',
            amount: -100,
            createdAt: DateTime.utc(2026, 9, 25, 12),
            method: 'Efectivo',
            kind: 'Reintegro',
          ),
        ],
        returns: [returned()],
        from: DateTime(2026, 9, 25),
        to: DateTime(2026, 9, 25),
      );
      expect(report.grossSales, BigInt.from(0));
      expect(report.netSales, BigInt.from(-100));
      expect(report.netCollections, BigInt.from(-100));
      expect(report.netCostMicros, BigInt.from(-33333333));
      expect(report.grossProfitMicros, BigInt.from(-66666667));
      expect(report.bestSellerRows.single[1], '-1');
    },
  );

  test('unrecovered materials remain a cost when money is returned', () {
    final report = SalesPeriodReport(
      sales: [sample()],
      payments: [],
      returns: [returned(cost: 0)],
      from: DateTime(2026, 9, 20),
      to: DateTime(2026, 9, 25),
    );
    expect(report.netSales, BigInt.from(200));
    expect(report.netCostMicros, BigInt.from(100000000));
    expect(report.grossProfitMicros, BigInt.from(100000000));
  });

  test(
    'unknown or legacy cost also blocks profit in a later return period',
    () {
      for (final sale in [sample(known: false), sample(basis: 'legacy')]) {
        final report = SalesPeriodReport(
          sales: [sale],
          payments: [],
          returns: [returned()],
          from: DateTime(2026, 9, 25),
          to: DateTime(2026, 9, 25),
        );
        expect(report.costsComplete, false);
        expect(report.grossProfitMicros, isNull);
      }
    },
  );

  test('Bogota bounds do not depend on the Windows time zone', () {
    final period = BogotaPeriod(DateTime(2026, 9, 25), DateTime(2026, 9, 25));
    expect(period.contains(DateTime.utc(2026, 9, 25, 4, 59, 59)), false);
    expect(period.contains(DateTime.utc(2026, 9, 25, 5)), true);
    expect(period.contains(DateTime.utc(2026, 9, 26, 4, 59, 59)), true);
    expect(period.contains(DateTime.utc(2026, 9, 26, 5)), false);
  });

  test('money formatting uses integer rounding even near integer limits', () {
    expect(SalesPeriodReport.roundedPesos(1499999), 1);
    expect(SalesPeriodReport.roundedPesos(1500000), 2);
    expect(SalesPeriodReport.roundedPesos(-1500000), -2);
    expect(SalesPeriodReport.roundedPesos(8999999999999499999), 8999999999999);
  });
}
