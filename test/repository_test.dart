import 'dart:convert';
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
    directory = await Directory.systemTemp.createTemp('capc_repository_test_');
    databasePath = p.join(directory.path, 'capc.sqlite');
    repository = await CapcRepository.open(databasePath);
    if (await repository.needsSetup()) {
      await repository.setupOwner(
        name: 'Propietaria',
        username: 'owner',
        password: 'Una-clave-larga-2026',
      );
      await repository.openCash(0, operationId: 'opening');
    } else {
      await repository.login('owner', 'Una-clave-larga-2026');
    }
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Product product({
    String id = 'paper',
    String code = 'PAP-001',
    String name = 'Papel carta',
    int price = 200,
    int cost = 50,
    int stock = 10,
    bool service = false,
  }) => Product(
    id: id,
    code: code,
    name: name,
    unit: 'Unidad',
    isService: service,
    purchasePrice: cost,
    salePrice: price,
    stock: stock,
    minimumStock: 0,
  );

  Future<Sale> sell({
    int quantity = 1,
    int paid = 200,
    String? customerId,
    String? operationId,
    DateTime? dueAt,
  }) => repository.createSale(
    items: [CartLine(productId: 'paper', quantity: quantity)],
    paid: paid,
    customerId: customerId,
    paymentMethod: 'Efectivo',
    operationId: operationId,
    dueAt: dueAt,
  );

  Map<String, int> counts() {
    final db = sqlite3.open(databasePath);
    try {
      return {
        for (final table in [
          'sales',
          'sale_lines',
          'payments',
          'stock_movements',
          'operations',
          'outbox',
        ])
          table:
              db.select('SELECT COUNT(*) AS n FROM $table').single['n'] as int,
      };
    } finally {
      db.close();
    }
  }

  test(
    'starts empty and preserves sales, debt, stock and UTC time after reopening',
    () async {
      expect(await repository.listProducts(), isEmpty);
      expect(await repository.listCustomers(), isEmpty);
      expect(await repository.listSales(), isEmpty);
      await repository.saveProduct(product());
      await repository.saveCustomer(
        const Customer(id: 'ana', name: 'Ana', phone: '3001234567'),
      );
      final dueAt = DateTime.now().toUtc().add(const Duration(days: 30));
      final sale = await sell(
        quantity: 2,
        paid: 100,
        customerId: 'ana',
        dueAt: dueAt,
      );
      expect(sale.status, 'Abono parcial');
      expect(sale.createdAt.isUtc, isTrue);

      await repository.close();
      repository = await CapcRepository.open(databasePath);
      if (await repository.needsSetup()) {
        await repository.setupOwner(
          name: 'Propietaria',
          username: 'owner',
          password: 'Una-clave-larga-2026',
        );
        await repository.openCash(0, operationId: 'opening');
      } else {
        await repository.login('owner', 'Una-clave-larga-2026');
      }
      final saved = (await repository.listSales()).single;
      expect(saved.id, sale.id);
      expect(saved.createdAt, sale.createdAt);
      expect(saved.dueAt, dueAt);
      expect(saved.customerName, 'Ana');
      expect(saved.lines.single.quantity, 2);
      expect(saved.lines.single.unitCost, 50);
      expect(saved.total, 400);
      expect(saved.paid, 100);
      expect(saved.balance, 300);
      expect((await repository.listProducts()).single.stock, 8);
      expect((await repository.listPayments()).single.amount, 100);
      expect((await repository.listCustomers()).single.phone, '3001234567');
    },
  );

  test(
    'failed stock or missing customer creates no partial sale or movement',
    () async {
      await repository.saveProduct(product(stock: 1));
      final before = counts();
      await expectLater(
        sell(quantity: 2, paid: 400),
        throwsA(isA<CapcException>()),
      );
      await expectLater(sell(paid: 0), throwsA(isA<CapcException>()));
      await expectLater(
        sell(paid: 0, customerId: 'missing'),
        throwsA(isA<CapcException>()),
      );
      expect(counts(), before);
      expect((await repository.listProducts()).single.stock, 1);
      final sale = await sell();
      expect(sale.number, 'V-000001');
    },
  );

  test(
    'credit requires a due date and failed attempts leave every ledger unchanged',
    () async {
      await repository.saveProduct(product());
      await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana'));
      final before = counts();
      final cashBefore =
          (await repository.currentCashSession())!.expectedAmount;
      for (final paid in [0, 100]) {
        await expectLater(
          sell(paid: paid, customerId: 'ana', operationId: 'credit-due-$paid'),
          throwsA(
            isA<CapcException>().having(
              (error) => error.message,
              'message',
              contains('vencimiento'),
            ),
          ),
        );
      }
      expect(counts(), before);
      expect((await repository.listProducts()).single.stock, 10);
      expect(
        (await repository.currentCashSession())!.expectedAmount,
        cashBefore,
      );
      final dueAt = DateTime.now().toUtc().add(const Duration(days: 30));
      final sale = await sell(
        paid: 100,
        customerId: 'ana',
        operationId: 'credit-due-100',
        dueAt: dueAt,
      );
      expect(sale.number, 'V-000001');
      expect(sale.balance, 100);
      expect(sale.dueAt, dueAt);
      final after = counts();
      final retry = await sell(
        paid: 100,
        customerId: 'ana',
        operationId: 'credit-due-100',
        dueAt: dueAt,
      );
      expect(retry.id, sale.id);
      expect(counts(), after);
    },
  );

  test(
    'failure while writing outbox rolls back sale, stock, payment and numbering',
    () async {
      await repository.saveProduct(product());
      final before = counts();
      var db = sqlite3.open(databasePath);
      db.execute('''CREATE TRIGGER reject_sale_event BEFORE INSERT ON outbox
      WHEN NEW.kind = 'sale.created' BEGIN
        SELECT RAISE(ABORT, 'simulated outbox failure');
      END''');
      db.close();
      await expectLater(sell(), throwsA(isA<CapcException>()));
      expect(counts(), before);
      expect((await repository.listProducts()).single.stock, 10);
      db = sqlite3.open(databasePath);
      db.execute('DROP TRIGGER reject_sale_event');
      db.close();
      expect((await sell()).number, 'V-000001');
    },
  );

  test(
    'repeated products are aggregated and services do not consume stock',
    () async {
      await repository.saveProduct(product());
      await repository.saveProduct(
        product(
          id: 'internet',
          code: 'SER-001',
          name: 'Internet',
          price: 3000,
          cost: 0,
          stock: 0,
          service: true,
        ),
      );
      final sale = await repository.createSale(
        items: const [
          CartLine(productId: 'paper', quantity: 1),
          CartLine(productId: 'internet', quantity: 2),
          CartLine(productId: 'paper', quantity: 2),
        ],
        paid: 6600,
        paymentMethod: 'Transferencia',
      );
      expect(sale.lines.length, 2);
      expect(
        sale.lines.firstWhere((line) => line.productId == 'paper').quantity,
        3,
      );
      expect(sale.total, 6600);
      expect((await repository.listProducts(query: 'PAP-001')).single.stock, 7);
      expect((await repository.listProducts(query: 'SER-001')).single.stock, 0);
      expect(counts()['stock_movements'], 2); // Initial paper stock + the sale.
    },
  );

  test(
    'sale retry is idempotent after restart and ignores later catalog prices',
    () async {
      await repository.saveProduct(product());
      final first = await sell(
        quantity: 2,
        paid: 400,
        operationId: 'sale-retry',
      );
      await repository.saveProduct(product(price: 350, stock: 8));
      await repository.close();
      repository = await CapcRepository.open(databasePath);
      if (await repository.needsSetup()) {
        await repository.setupOwner(
          name: 'Propietaria',
          username: 'owner',
          password: 'Una-clave-larga-2026',
        );
        await repository.openCash(0, operationId: 'opening');
      } else {
        await repository.login('owner', 'Una-clave-larga-2026');
      }
      final before = counts();
      final retry = await repository.createSale(
        items: const [
          CartLine(productId: 'paper', quantity: 1),
          CartLine(productId: 'paper', quantity: 1),
        ],
        paid: 400,
        paymentMethod: 'Efectivo',
        operationId: 'sale-retry',
      );
      expect(retry.id, first.id);
      expect(retry.total, 400);
      expect(retry.lines.single.unitPrice, 200);
      expect(counts(), before);
      await expectLater(
        sell(quantity: 1, paid: 200, operationId: 'sale-retry'),
        throwsA(isA<CapcException>()),
      );
      expect(counts(), before);
      expect((await repository.listProducts()).single.stock, 8);
    },
  );

  test(
    'credit payments settle once, reject overpayment, and persist retry IDs',
    () async {
      await repository.saveProduct(product());
      await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana'));
      final sale = await sell(
        customerId: 'ana',
        paid: 0,
        operationId: 'credit-sale',
        dueAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      );
      expect(sale.status, 'Debe');
      expect(await repository.listPayments(), isEmpty);
      await repository.addPayment(
        sale.id,
        75,
        'Efectivo',
        operationId: 'payment-1',
      );
      expect((await repository.listSales()).single.status, 'Abono parcial');
      await repository.close();
      repository = await CapcRepository.open(databasePath);
      if (await repository.needsSetup()) {
        await repository.setupOwner(
          name: 'Propietaria',
          username: 'owner',
          password: 'Una-clave-larga-2026',
        );
        await repository.openCash(0, operationId: 'opening');
      } else {
        await repository.login('owner', 'Una-clave-larga-2026');
      }
      final before = counts();
      await repository.addPayment(
        sale.id,
        75,
        'Efectivo',
        operationId: 'payment-1',
      );
      expect(counts(), before);
      await expectLater(
        repository.addPayment(
          sale.id,
          76,
          'Efectivo',
          operationId: 'payment-1',
        ),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.addPayment(sale.id, 126, 'Efectivo'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.addPayment(sale.id, 0, 'Efectivo'),
        throwsA(isA<CapcException>()),
      );
      expect(counts(), before);
      await repository.addPayment(
        sale.id,
        125,
        'Transferencia',
        operationId: 'payment-2',
      );
      final settled = (await repository.listSales()).single;
      expect(settled.paid, 200);
      expect(settled.balance, 0);
      expect(settled.status, 'Pagada');
      expect((await repository.listPayments(saleId: sale.id)).length, 2);
      expect((await repository.listProducts()).single.stock, 9);
      await expectLater(
        repository.addPayment(sale.id, 1, 'Efectivo'),
        throwsA(isA<CapcException>()),
      );
    },
  );

  test(
    'transaction rejects an operation ID reused for another operation type',
    () async {
      await repository.saveProduct(product());
      await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana'));
      final sale = await sell(
        customerId: 'ana',
        paid: 0,
        operationId: 'shared-id',
        dueAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      );
      final before = counts();
      await expectLater(
        repository.addPayment(
          sale.id,
          200,
          'Efectivo',
          operationId: 'shared-id',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(counts(), before);
      expect((await repository.listSales()).single.balance, 200);
    },
  );

  test(
    'concurrent attempts to sell the last unit only commit one sale',
    () async {
      await repository.saveProduct(product(stock: 1));
      Future<Object> attempt(String id) async {
        try {
          return await sell(operationId: id);
        } on CapcException catch (error) {
          return error;
        }
      }

      final results = await Future.wait([attempt('one'), attempt('two')]);
      expect(results.whereType<Sale>().length, 1);
      expect(results.whereType<CapcException>().length, 1);
      expect((await repository.listProducts()).single.stock, 0);
      expect((await repository.listSales()).length, 1);
      expect((await repository.listPayments()).length, 1);
    },
  );

  test(
    'catalog edits preserve receipt snapshots and require explicit stock adjustments',
    () async {
      await repository.saveProduct(product());
      await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana'));
      await sell(customerId: 'ana');
      await expectLater(
        repository.saveProduct(product(stock: 30)),
        throwsA(isA<CapcException>()),
      );
      await repository.saveProduct(
        product(name: 'Papel premium', price: 500, cost: 100, stock: 9),
      );
      await repository.saveCustomer(
        const Customer(id: 'ana', name: 'Ana María'),
      );
      final oldSale = (await repository.listSales(query: 'Papel carta')).single;
      expect(oldSale.customerName, 'Ana');
      expect(oldSale.lines.single.name, 'Papel carta');
      expect(oldSale.lines.single.unitPrice, 200);
      expect(oldSale.lines.single.unitCost, 50);
      await expectLater(
        repository.adjustStock('paper', -10, 'Merma'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.adjustStock('paper', 1, '  '),
        throwsA(isA<CapcException>()),
      );
      await repository.adjustStock('paper', 5, 'Compra recibida');
      await repository.adjustStock('paper', -2, 'Hojas dañadas');
      expect((await repository.listProducts()).single.stock, 12);
      final db = sqlite3.open(databasePath);
      try {
        expect(
          db
              .select('SELECT SUM(delta) AS stock FROM stock_movements')
              .single['stock'],
          12,
        );
        expect(
          db
              .select("SELECT reason FROM stock_movements WHERE delta = -2")
              .single['reason'],
          'Hojas dañadas',
        );
      } finally {
        db.close();
      }
    },
  );

  test(
    'codes are case-insensitively unique and searches treat wildcards literally',
    () async {
      await repository.saveProduct(product(code: 'pap-001'));
      await expectLater(
        repository.saveProduct(product(id: 'duplicate', code: 'PAP-001')),
        throwsA(isA<CapcException>()),
      );
      await repository.saveProduct(
        product(id: 'percent', code: 'PCT_50', name: 'Descuento 50%'),
      );
      expect(
        (await repository.listProducts(query: 'pap-001')).single.code,
        'PAP-001',
      );
      expect(
        (await repository.listProducts(query: 'carta')).single.id,
        'paper',
      );
      expect((await repository.listProducts(query: '%')).single.id, 'percent');
      expect((await repository.listProducts(query: '_')).single.id, 'percent');
      expect(await repository.listProducts(query: "' OR 1=1 --"), isEmpty);
    },
  );

  test(
    'invalid amounts, quantities and service stocks are rejected without mutations',
    () async {
      await expectLater(
        repository.saveProduct(product(price: -1)),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.saveProduct(product(stock: -1)),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.saveProduct(product(service: true)),
        throwsA(isA<CapcException>()),
      );
      await repository.saveProduct(
        product(stock: 1000000000, price: 999999999999),
      );
      final before = counts();
      await expectLater(sell(quantity: 0), throwsA(isA<CapcException>()));
      await expectLater(sell(quantity: 2), throwsA(isA<CapcException>()));
      await expectLater(sell(paid: -1), throwsA(isA<CapcException>()));
      expect(counts(), before);
    },
  );

  test(
    'initial payments and event payload are captured atomically with unique IDs',
    () async {
      await repository.saveProduct(product());
      final sale = await sell(operationId: 'event-op');
      final payment = (await repository.listPayments()).single;
      final db = sqlite3.open(databasePath);
      try {
        final event = db.select('SELECT * FROM outbox WHERE operation_id = ?', [
          'event-op',
        ]).single;
        final payload =
            jsonDecode(event['payload'] as String) as Map<String, dynamic>;
        expect(event['id'], isNotEmpty);
        expect(event['state'], 'pending');
        expect(event['schema_version'], 1);
        expect(payload['saleId'], sale.id);
        expect(payload['paymentId'], payment.id);
        expect(payload['paid'], 200);
        expect(payload['lines'], hasLength(1));
        expect(payload['lines'][0]['unit_cost'], 50);
      } finally {
        db.close();
      }
    },
  );

  test(
    'example catalog is explicit, atomic and cannot duplicate or add sales',
    () async {
      await repository.loadExampleCatalog();
      expect((await repository.listProducts()).length, 6);
      expect(await repository.listCustomers(), isEmpty);
      expect(await repository.listSales(), isEmpty);
      expect(await repository.listPayments(), isEmpty);
      final before = counts();
      await expectLater(
        repository.loadExampleCatalog(),
        throwsA(isA<CapcException>()),
      );
      expect(counts(), before);
      expect((await repository.listProducts()).length, 6);
    },
  );

  test(
    'backup includes committed WAL data and refuses source or existing files',
    () async {
      await repository.saveProduct(product());
      final sale = await sell(operationId: 'saved-sale');
      final backupPath = p.join(directory.path, 'respaldo.sqlite');
      await repository.backupTo(backupPath);
      final backup = await CapcRepository.open(backupPath);
      await backup.login('owner', 'Una-clave-larga-2026');
      try {
        expect((await backup.listSales()).single.id, sale.id);
        expect((await backup.listProducts()).single.stock, 9);
        expect((await backup.listPayments()).single.amount, 200);
        final retry = await backup.createSale(
          items: const [CartLine(productId: 'paper', quantity: 1)],
          paid: 200,
          paymentMethod: 'Efectivo',
          operationId: 'saved-sale',
        );
        expect(retry.id, sale.id);
      } finally {
        await backup.close();
      }
      await expectLater(
        repository.backupTo(databasePath),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.backupTo(backupPath),
        throwsA(isA<CapcException>()),
      );
      final emptyPath = p.join(directory.path, 'existing-empty.sqlite');
      await File(emptyPath).create();
      await expectLater(
        repository.backupTo(emptyPath),
        throwsA(isA<CapcException>()),
      );
      expect(await File(emptyPath).length(), 0);
      final db = sqlite3.open(backupPath);
      try {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      } finally {
        db.close();
      }
    },
  );
}
