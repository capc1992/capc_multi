import '../data/models.dart';

/// Inclusive Bogotá civil dates, independently of the computer's time zone.
class BogotaPeriod {
  BogotaPeriod(DateTime from, DateTime to)
    : from = DateTime.utc(from.year, from.month, from.day),
      to = DateTime.utc(to.year, to.month, to.day) {
    if (this.from.isAfter(this.to)) {
      throw const CapcException(
        'La fecha inicial debe ser anterior a la final.',
      );
    }
  }
  final DateTime from, to;
  bool contains(DateTime instant) {
    final local = instant.toUtc().subtract(const Duration(hours: 5));
    final day = DateTime.utc(local.year, local.month, local.day);
    return !day.isBefore(from) && !day.isAfter(to);
  }
}

class SalesPeriodReport {
  SalesPeriodReport({
    required List<Sale> sales,
    required List<Payment> payments,
    required List<SaleReturnRecord> returns,
    required DateTime from,
    required DateTime to,
  }) : allSales = List.unmodifiable(sales),
       period = BogotaPeriod(from, to) {
    periodSales = sales.where((s) => period.contains(s.createdAt)).toList();
    periodPayments = payments
        .where((p) => period.contains(p.createdAt))
        .toList();
    periodReturns = returns.where((r) => period.contains(r.createdAt)).toList();
  }

  final List<Sale> allSales;
  final BogotaPeriod period;
  late final List<Sale> periodSales;
  late final List<Payment> periodPayments;
  late final List<SaleReturnRecord> periodReturns;

  BigInt get grossSales =>
      periodSales.fold(BigInt.zero, (sum, s) => sum + BigInt.from(s.total));
  BigInt get returnedSales =>
      periodReturns.fold(BigInt.zero, (sum, r) => sum + BigInt.from(r.amount));
  BigInt get netSales => grossSales - returnedSales;
  BigInt get netCollections =>
      periodPayments.fold(BigInt.zero, (sum, p) => sum + BigInt.from(p.amount));
  BigInt get originalCostMicros => periodSales.fold(
    BigInt.zero,
    (sum, sale) =>
        sum +
        sale.lines.fold<BigInt>(
          BigInt.zero,
          (n, line) => n + BigInt.from(line.costTotalMicros),
        ),
  );
  BigInt get recoveredCostMicros => periodReturns.fold(
    BigInt.zero,
    (sum, r) => sum + BigInt.from(r.costReversedMicros),
  );
  BigInt get netCostMicros => originalCostMicros - recoveredCostMicros;
  bool get costsComplete {
    final relevantIds = {
      for (final s in periodSales) s.id,
      for (final r in periodReturns) r.saleId,
    };
    final relevant = allSales.where((s) => relevantIds.contains(s.id)).toList();
    return relevant.length == relevantIds.length &&
        relevant.every(
          (sale) => sale.lines.every(
            (line) =>
                line.costKnown &&
                line.costBasis != 'legacy' &&
                line.costBasis != 'declared',
          ),
        );
  }

  BigInt? get grossProfitMicros =>
      costsComplete ? netSales * BigInt.from(1000000) - netCostMicros : null;

  List<List<String>> get salesRows => [
    for (final sale in periodSales)
      [
        sale.number,
        instant(sale.createdAt),
        'Venta',
        money(sale.total),
        sale.lines.every(
              (l) =>
                  l.costKnown &&
                  l.costBasis != 'legacy' &&
                  l.costBasis != 'declared',
            )
            ? moneyMicros(
                sale.lines.fold<BigInt>(
                  BigInt.zero,
                  (n, l) => n + BigInt.from(l.costTotalMicros),
                ),
              )
            : 'Costo declarado / incompleto',
      ],
    for (final r in periodReturns)
      [
        r.number,
        instant(r.createdAt),
        r.cancelled ? 'Anulación' : 'Devolución',
        money(-r.amount),
        moneyMicros(-r.costReversedMicros),
      ],
  ];

  List<String> get notes => [
    'Ventas originales: ${money(grossSales)}. Devoluciones/anulaciones registradas en el período: ${money(returnedSales)}. Ventas netas: ${money(netSales)}.',
    'Cobros menos reintegros por fecha de pago: ${money(netCollections)}. Las ventas a crédito no son cobros.',
    costsComplete
        ? 'Costo neto registrado: ${moneyMicros(netCostMicros)}. Utilidad bruta: ${moneyMicros(grossProfitMicros!)}.'
        : 'Utilidad bruta no calculada: existen costos históricos declarados o incompletos.',
    'Cada compensación afecta su propia fecha. Solo se revierte el costo del material recuperado; devolver dinero por un servicio realizado no recupera sus insumos.',
    'La utilidad bruta no descuenta gastos, salarios ni impuestos. Los anticipos pertenecen al flujo de caja hasta aplicarse a una venta.',
  ];

  List<List<String>> get bestSellerRows {
    final quantities = <String, BigInt>{};
    final values = <String, BigInt>{};
    final names = <String, String>{};
    final linesById = {
      for (final sale in allSales)
        for (final line in sale.lines) line.id: line,
    };
    String key(SaleLine line) =>
        line.productId.isNotEmpty ? line.productId : 'custom:${line.name}';
    for (final sale in periodSales) {
      for (final line in sale.lines) {
        final id = key(line);
        names[id] = '${line.code} ${line.name}'.trim();
        quantities[id] =
            (quantities[id] ?? BigInt.zero) + BigInt.from(line.quantity);
        values[id] = (values[id] ?? BigInt.zero) + BigInt.from(line.total);
      }
    }
    for (final r in periodReturns) {
      for (final item in r.items) {
        final line = linesById[item.saleLineId];
        if (line == null) continue;
        final id = key(line);
        names[id] = '${line.code} ${line.name}'.trim();
        quantities[id] =
            (quantities[id] ?? BigInt.zero) - BigInt.from(item.quantity);
        values[id] =
            (values[id] ?? BigInt.zero) -
            BigInt.from(item.quantity) * BigInt.from(line.unitPrice);
      }
    }
    final ids = quantities.keys.toList()
      ..sort((a, b) {
        final byQuantity = quantities[b]!.compareTo(quantities[a]!);
        return byQuantity != 0 ? byQuantity : names[a]!.compareTo(names[b]!);
      });
    return [
      for (final id in ids)
        [names[id]!, '${quantities[id]}', money(values[id]!)],
    ];
  }

  static BigInt _big(Object value) =>
      value is BigInt ? value : BigInt.from(value as int);
  static String money(Object amount) {
    final value = _big(amount);
    final digits = value.abs().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]}.',
    );
    return '${value.isNegative ? '-' : ''}\$ $digits';
  }

  static int roundedPesos(int micros) => micros < 0
      ? -((-micros + 500000) ~/ 1000000)
      : (micros + 500000) ~/ 1000000;
  static String moneyMicros(Object micros) {
    final value = _big(micros);
    final rounded = (value.abs() + BigInt.from(500000)) ~/ BigInt.from(1000000);
    return money(value.isNegative ? -rounded : rounded);
  }

  static String instant(DateTime value) {
    final d = value.toUtc().subtract(const Duration(hours: 5));
    String pad(int n) => '$n'.padLeft(2, '0');
    return '${pad(d.day)}/${pad(d.month)}/${d.year} ${pad(d.hour)}:${pad(d.minute)}';
  }
}
