import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late CapcRepository repository;
  late String databasePath;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_ledger_');
    databasePath = p.join(directory.path, 'data.sqlite');
    repository = await CapcRepository.open(databasePath);
    await repository.setupOwner(
      name: 'Propietaria',
      username: 'owner',
      password: 'una-clave-segura',
    );
    await repository.openCash(1000, operationId: 'opening');
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });
  Product product({
    String id = 'paper',
    String name = 'Papel',
    int cost = 0,
    int price = 200,
    int stock = 0,
    bool service = false,
  }) => Product(
    id: id,
    code: id.toUpperCase(),
    name: name,
    unit: 'Unidad',
    isService: service,
    purchasePrice: cost,
    salePrice: price,
    stock: stock,
    minimumStock: 1 * (service ? 0 : 1),
  );
  Future<void> lot({int quantity = 3, int cost = 100}) async {
    await repository.saveProduct(product());
    await repository.adjustStock(
      'paper',
      quantity,
      'Lote con costo total',
      totalCost: cost,
      operationId: 'lot',
    );
  }

  Future<Sale> sell({
    int quantity = 1,
    int? paid,
    int? received,
    String? operationId,
  }) => repository.createSale(
    items: [CartLine(productId: 'paper', quantity: quantity)],
    paid: paid ?? quantity * 200,
    paymentMethod: 'Efectivo',
    received: received,
    operationId: operationId,
  );

  test(
    '100 pesos over three units preserves every micro and historical costs',
    () async {
      await lot();
      final first = await sell();
      final second = await sell();
      final third = await sell();
      expect(
        [first, second, third].map((s) => s.lines.single.costTotalMicros),
        [33333333, 33333333, 33333334],
      );
      expect((await repository.listProducts()).single.inventoryValueMicros, 0);
      expect((await repository.listProducts()).single.stock, 0);
      expect(
        [first, second, third].fold<int>(0, (sum, s) => sum + s.netCostMicros),
        100000000,
      );
      await repository.saveProduct(
        product(name: 'Nuevo nombre', cost: 400, price: 500),
      );
      final history = await repository.listSales();
      expect(history.every((s) => s.lines.single.name == 'Papel'), isTrue);
      expect(history.every((s) => s.lines.single.unitPrice == 200), isTrue);
    },
  );

  test(
    'weighted incoming cost and user chosen markup never rewrite sale price',
    () async {
      await lot(quantity: 2, cost: 100);
      await repository.adjustStock('paper', 2, 'Segundo lote', totalCost: 300);
      final before = (await repository.listProducts()).single;
      expect(before.stock, 4);
      expect(before.averageCostMicros, 100000000);
      expect(before.suggestedPrice(2500), 125);
      expect(before.salePrice, 200);
      expect((await sell()).lines.single.costTotalMicros, 100000000);
      expect(
        (await repository.listProducts()).single.inventoryValueMicros,
        300000000,
      );
    },
  );

  test(
    'service recipe and direct product demand are checked together atomically',
    () async {
      await lot();
      await repository.saveProduct(
        product(
          id: 'copy',
          name: 'Fotocopia',
          cost: 5,
          price: 300,
          service: true,
        ),
      );
      await repository.setServiceRecipe('copy', [
        const ServiceMaterial(productId: 'paper', quantity: 2),
      ]);
      await expectLater(
        repository.createSale(
          items: const [
            CartLine(productId: 'paper', quantity: 2),
            CartLine(productId: 'copy', quantity: 1),
          ],
          paid: 700,
          paymentMethod: 'Efectivo',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listSales(), isEmpty);
      expect((await repository.listProducts(query: 'paper')).single.stock, 3);
      final sale = await repository.createSale(
        items: const [CartLine(productId: 'copy', quantity: 1)],
        paid: 300,
        paymentMethod: 'Efectivo',
      );
      expect(sale.lines.single.costTotalMicros, 71666666);
      expect(
        (await repository.listProducts(
          query: 'paper',
        )).single.inventoryValueMicros,
        33333334,
      );
      expect(sale.lines.single.costBasis, 'service');
      await repository.setServiceRecipe('copy', [
        const ServiceMaterial(productId: 'paper', quantity: 1),
      ]);
      await repository.cancelSale(
        sale.id,
        reason: 'No se realizó',
        operationId: 'cancel-service',
      );
      expect((await repository.listProducts(query: 'paper')).single.stock, 3);
      expect(
        (await repository.listProducts(
          query: 'paper',
        )).single.inventoryValueMicros,
        100000000,
      );
    },
  );

  test(
    'partial returns allocate original costs and refunds once after restart',
    () async {
      await lot();
      final sale = await sell(quantity: 3, operationId: 'sale');
      await repository.returnSale(
        sale.id,
        [SaleReturnItem(saleLineId: sale.lines.single.id, quantity: 1)],
        reason: 'Devuelve una unidad',
        operationId: 'return-1',
      );
      expect(
        (await repository.listProducts()).single.inventoryValueMicros,
        33333333,
      );
      await repository.close();
      repository = await CapcRepository.open(databasePath);
      await repository.login('owner', 'una-clave-segura');
      await repository.returnSale(
        sale.id,
        [SaleReturnItem(saleLineId: sale.lines.single.id, quantity: 1)],
        reason: 'Devuelve una unidad',
        operationId: 'return-1',
      );
      expect((await repository.listProducts()).single.stock, 1);
      await repository.returnSale(
        sale.id,
        [SaleReturnItem(saleLineId: sale.lines.single.id, quantity: 1)],
        reason: 'Segunda',
        operationId: 'return-2',
      );
      await repository.returnSale(
        sale.id,
        [SaleReturnItem(saleLineId: sale.lines.single.id, quantity: 1)],
        reason: 'Tercera',
        operationId: 'return-3',
      );
      expect((await repository.listProducts()).single.stock, 3);
      expect(
        (await repository.listProducts()).single.inventoryValueMicros,
        100000000,
      );
      final updated = (await repository.listSales()).single;
      expect(updated.total, 600);
      expect(updated.netTotal, 0);
      expect(updated.paid, 0);
      expect(updated.refunded, 600);
      expect(updated.netCostMicros, 0);
      expect(
        (await repository.listPayments()).fold<int>(
          0,
          (sum, payment) => sum + payment.amount,
        ),
        0,
      );
      expect(
        (await repository.listSaleReturns()).fold<int>(
          0,
          (sum, r) => sum + r.costReversedMicros,
        ),
        100000000,
      );
      expect(
        (await repository.listSaleReturns()).every(
          (r) => r.items.single.quantity == 1,
        ),
        isTrue,
      );
      await expectLater(
        repository.returnSale(sale.id, [
          SaleReturnItem(saleLineId: sale.lines.single.id, quantity: 1),
        ], reason: 'Exceso'),
        throwsA(isA<CapcException>()),
      );
    },
  );

  test(
    'service refund leaves consumed materials and their cost when unrecoverable',
    () async {
      await lot();
      await repository.saveProduct(
        product(id: 'service', price: 100, service: true, cost: 10),
      );
      await repository.setServiceRecipe('service', [
        const ServiceMaterial(productId: 'paper', quantity: 1),
      ]);
      final sale = await repository.createSale(
        items: const [CartLine(productId: 'service', quantity: 1)],
        paid: 100,
        paymentMethod: 'Efectivo',
      );
      final cancelled = await repository.cancelSale(
        sale.id,
        reason: 'Servicio ya realizado, reintegro comercial',
        restoreMaterials: false,
      );
      expect(cancelled.status, 'Anulada');
      expect(cancelled.netCostMicros, 43333333);
      expect((await repository.listProducts(query: 'paper')).single.stock, 2);
      expect((await repository.listSaleReturns()).single.costReversedMicros, 0);
    },
  );

  test(
    'cash uses applied amount, rejects impossible exits and persists closing difference',
    () async {
      await lot();
      final sale = await sell(received: 500);
      expect(sale.received, 500);
      expect(sale.change, 300);
      expect((await repository.currentCashSession())!.expectedAmount, 1200);
      await repository.addExpense(100, 'Mensajería', operationId: 'expense');
      await repository.addExpense(100, 'Mensajería', operationId: 'expense');
      await repository.addExpense(
        300,
        'Pago bancario',
        method: 'Transferencia',
      );
      expect((await repository.currentCashSession())!.expectedAmount, 1100);
      await expectLater(
        repository.addExpense(1101, 'Excede efectivo'),
        throwsA(isA<CapcException>()),
      );
      final closed = await repository.closeCash(
        1090,
        note: 'Faltante por revisar',
        operationId: 'closing',
      );
      expect(closed.difference, -10);
      expect(
        (await repository.closeCash(
          1090,
          note: 'Faltante por revisar',
          operationId: 'closing',
        )).id,
        closed.id,
      );
      await expectLater(sell(), throwsA(isA<CapcException>()));
      await repository.close();
      repository = await CapcRepository.open(databasePath);
      await repository.login('owner', 'una-clave-segura');
      expect(await repository.currentCashSession(), isNull);
      expect((await repository.listCashSessions()).single.difference, -10);
      await repository.openCash(1090);
      expect((await repository.currentCashSession())!.openingAmount, 1090);
    },
  );

  test(
    'unknown custom cost stays unknown and inventory valuation cannot overflow',
    () async {
      final sale = await repository.createSale(
        items: const [],
        customItems: const [
          CustomSaleItem(
            description: 'Trabajo especial',
            quantity: 1,
            unitPrice: 200,
          ),
        ],
        paid: 200,
        paymentMethod: 'Efectivo',
      );
      expect(sale.costKnown, isFalse);
      await expectLater(
        repository.saveProduct(product(stock: 1000000000, cost: 999999999999)),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listProducts(), isEmpty);
      final db = sqlite3.open(databasePath);
      try {
        expect(
          db
              .select(
                "SELECT COUNT(*) AS n FROM products WHERE typeof(inventory_value_micros) != 'integer'",
              )
              .single['n'],
          0,
        );
      } finally {
        db.close();
      }
    },
  );

  test(
    'adjustment retries do not duplicate stock and changed payload is rejected',
    () async {
      await lot();
      await repository.adjustStock(
        'paper',
        3,
        'Lote con costo total',
        totalCost: 100,
        operationId: 'lot',
      );
      expect((await repository.listProducts()).single.stock, 3);
      await expectLater(
        repository.adjustStock(
          'paper',
          4,
          'Lote con costo total',
          totalCost: 100,
          operationId: 'lot',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(
        (await repository.listStockMovements()).single.actorName,
        'Propietaria',
      );
    },
  );

  test(
    'cancelling damaged products does not manufacture recovered inventory',
    () async {
      await lot();
      final sale = await sell();
      final cancelled = await repository.cancelSale(
        sale.id,
        reason: 'Producto dañado',
        restoreMaterials: false,
      );
      expect((await repository.listProducts()).single.stock, 2);
      expect(cancelled.netCostMicros, sale.netCostMicros);
      expect((await repository.listSaleReturns()).single.costReversedMicros, 0);
    },
  );

  test(
    'total cost overflow across individually valid lines rolls back all stock',
    () async {
      for (final id in ['one', 'two']) {
        await repository.saveProduct(
          product(id: id, stock: 9000000, cost: 1000000, price: 1),
        );
      }
      await expectLater(
        repository.createSale(
          items: const [
            CartLine(productId: 'one', quantity: 9000000),
            CartLine(productId: 'two', quantity: 9000000),
          ],
          paid: 18000000,
          paymentMethod: 'Efectivo',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listSales(), isEmpty);
      expect(
        (await repository.listProducts()).every((p) => p.stock == 9000000),
        isTrue,
      );
    },
  );

  test('a pending read cannot resurrect a logged out session', () async {
    final pending = repository.listProducts();
    repository.logout();
    await expectLater(pending, throwsA(isA<CapcException>()));
    expect(repository.currentUser, isNull);
    expect(repository.isAuthenticated, isFalse);
  });
}
