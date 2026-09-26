import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late CapcRepository repository;
  late String databasePath;
  final futureDate = DateTime.now().toUtc().add(const Duration(days: 30));

  Product material({
    String id = 'paper',
    int stock = 0,
    int price = 100,
    int cost = 0,
  }) => Product(
    id: id,
    code: id.toUpperCase(),
    name: 'Material $id',
    unit: 'Unidad',
    isService: false,
    purchasePrice: cost,
    salePrice: price,
    stock: stock,
    minimumStock: 1,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_operations_');
    databasePath = p.join(directory.path, 'operations.sqlite');
    repository = await CapcRepository.open(databasePath);
    await repository.setupOwner(
      name: 'Propietaria',
      username: 'owner',
      password: 'Una-clave-larga-2026',
    );
    await repository.openCash(1000000, operationId: 'opening');
    await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana Pérez'));
    await repository.saveSupplier(
      const Supplier(
        id: 'supply',
        name: 'Distribuciones Bogotá',
        document: 'REF 001',
        phone: '3001234567',
      ),
    );
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<Purchase> buy({
    int quantity = 3,
    int totalCost = 100,
    int paid = 0,
    String operationId = 'buy',
  }) => repository.createPurchase(
    supplierId: 'supply',
    reference: 'Factura proveedor 123',
    items: [
      PurchaseItemInput(
        productId: 'paper',
        quantity: quantity,
        totalCost: totalCost,
      ),
    ],
    paid: paid,
    dueAt: futureDate,
    operationId: operationId,
  );

  Future<Quote> quote({
    List<QuoteLineInput>? items,
    String operationId = 'quote',
  }) => repository.createQuote(
    customerId: 'ana',
    description: 'Trabajo de impresión',
    validUntil: futureDate,
    conditions: 'Retirar en el establecimiento.',
    operationId: operationId,
    items:
        items ??
        const [
          QuoteLineInput(
            productId: 'paper',
            description: 'Papel cotizado',
            quantity: 2,
            unitPrice: 80,
          ),
        ],
  );

  void expireFixtureQuote(String quoteId) {
    // Simulate a document whose deadline has elapsed since its acceptance.
    final db = sqlite3.open(databasePath);
    try {
      db.execute('UPDATE quotes SET valid_until = ? WHERE id = ?', [
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 2))
            .toIso8601String(),
        quoteId,
      ]);
    } finally {
      db.close();
    }
  }

  test(
    'purchase receiving is unique and preserves the exact lot value, supplier balances and reopen',
    () async {
      await repository.saveProduct(material());
      final purchase = await buy();
      expect(purchase.status, 'Debe');
      expect(purchase.received, isFalse);
      expect((await repository.listProducts()).single.stock, 0);
      final duplicate = await buy();
      expect(duplicate.id, purchase.id);
      await repository.receivePurchase(purchase.id, operationId: 'receive');
      await repository.receivePurchase(purchase.id, operationId: 'receive');
      await repository.receivePurchase(
        purchase.id,
        operationId: 'receive-again',
      );
      final product = (await repository.listProducts()).single;
      expect(product.stock, 3);
      expect(product.inventoryValueMicros, 100000000);
      expect(product.averageCostMicros, 33333333);
      expect(
        product.salePrice,
        100,
        reason: 'Receiving never changes the accepted sale price.',
      );
      await repository.addSupplierPayment(
        purchase.id,
        40,
        'Efectivo',
        operationId: 'supplier-partial',
      );
      await repository.addSupplierPayment(
        purchase.id,
        40,
        'Efectivo',
        operationId: 'supplier-partial',
      );
      await expectLater(
        repository.addSupplierPayment(
          purchase.id,
          61,
          'Efectivo',
          operationId: 'overpayment',
        ),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.addSupplierPayment(
          purchase.id,
          41,
          'Efectivo',
          operationId: 'supplier-partial',
        ),
        throwsA(isA<CapcException>()),
      );
      expect((await repository.listPurchases()).single.balance, 60);
      expect(await repository.listSupplierPayments(), hasLength(1));
      await repository.close();
      repository = await CapcRepository.open(databasePath);
      await repository.login('owner', 'Una-clave-larga-2026');
      final restored = (await repository.listPurchases()).single;
      expect(restored.received, isTrue);
      expect(restored.balance, 60);
      expect(restored.supplierName, 'Distribuciones Bogotá');
      expect(
        (await repository.listProducts()).single.inventoryValueMicros,
        100000000,
      );
      expect(
        (await repository.listSupplierPayments()).single.operatorName,
        'Propietaria',
      );
    },
  );

  test('weighted costs retain remainder through three unit sales', () async {
    await repository.saveProduct(material());
    final purchase = await buy(paid: 100);
    await repository.receivePurchase(purchase.id, operationId: 'receive');
    var costMicros = 0;
    for (var index = 0; index < 3; index++) {
      final sale = await repository.createSale(
        items: const [CartLine(productId: 'paper', quantity: 1)],
        paid: 100,
        paymentMethod: 'Efectivo',
        operationId: 'sale-$index',
      );
      costMicros += sale.lines.single.costTotalMicros;
    }
    expect(costMicros, 100000000);
    final product = (await repository.listProducts()).single;
    expect(product.stock, 0);
    expect(product.inventoryValueMicros, 0);
  });

  test(
    'purchase with multiple materials receives all lines and costs, never before receipt',
    () async {
      await repository.saveProduct(material(stock: 2, cost: 50));
      await repository.saveProduct(material(id: 'envelope'));
      final purchase = await repository.createPurchase(
        supplierId: 'supply',
        reference: 'Lote dos materiales',
        items: const [
          PurchaseItemInput(productId: 'paper', quantity: 2, totalCost: 300),
          PurchaseItemInput(productId: 'envelope', quantity: 5, totalCost: 250),
        ],
        paid: 200,
        dueAt: futureDate,
        operationId: 'multi',
      );
      expect(purchase.total, 550);
      expect(purchase.balance, 350);
      expect(
        (await repository.listProducts())
            .firstWhere((p) => p.id == 'paper')
            .stock,
        2,
      );
      await repository.receivePurchase(
        purchase.id,
        operationId: 'receive-multi',
      );
      final products = await repository.listProducts();
      expect(
        products.firstWhere((p) => p.id == 'paper').inventoryValueMicros,
        400000000,
      );
      expect(products.firstWhere((p) => p.id == 'paper').stock, 4);
      expect(products.firstWhere((p) => p.id == 'envelope').stock, 5);
      await repository.addSupplierPayment(
        purchase.id,
        350,
        'Transferencia',
        operationId: 'settle',
      );
      expect((await repository.listPurchases()).single.status, 'Pagada');
    },
  );

  test(
    'supplier search and snapshots survive supplier and product edits',
    () async {
      await repository.saveProduct(material());
      final purchase = await buy();
      await repository.saveSupplier(
        const Supplier(id: 'supply', name: 'Nuevo nombre', phone: '999'),
      );
      await repository.saveProduct(
        const Product(
          id: 'paper',
          code: 'PAPER-NEW',
          name: 'Material renombrado',
          unit: 'Hoja',
          isService: false,
          purchasePrice: 0,
          salePrice: 900,
          stock: 0,
          minimumStock: 0,
        ),
      );
      expect(await repository.listSuppliers(query: 'nuevo'), hasLength(1));
      expect(await repository.listSuppliers(query: '999'), hasLength(1));
      final document = (await repository.listPurchases(
        query: purchase.number,
      )).single;
      expect(document.supplierName, 'Distribuciones Bogotá');
      expect(document.lines.single.name, 'Material paper');
      expect(document.lines.single.code, 'PAPER');
    },
  );

  test(
    'quotes do not collect or reserve and convert once at their historical prices',
    () async {
      await repository.saveProduct(material(stock: 3));
      final cashBefore = await repository.listCashMovements();
      final document = await quote();
      expect((await repository.listProducts()).single.stock, 3);
      expect(await repository.listSales(), isEmpty);
      expect(await repository.listPayments(), isEmpty);
      expect(
        await repository.listCashMovements(),
        hasLength(cashBefore.length),
      );
      await expectLater(
        repository.convertQuote(
          document.id,
          paid: 160,
          paymentMethod: 'Efectivo',
          operationId: 'not-accepted',
        ),
        throwsA(isA<CapcException>()),
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await repository.saveProduct(material(stock: 3, price: 1000));
      final sale = await repository.convertQuote(
        document.id,
        paid: 160,
        paymentMethod: 'Efectivo',
        operationId: 'convert',
      );
      expect(sale.total, 160);
      expect(sale.lines.single.name, 'Papel cotizado');
      expect(sale.lines.single.unitPrice, 80);
      expect((await repository.listProducts()).single.stock, 1);
      expect(
        (await repository.convertQuote(
          document.id,
          paid: 160,
          paymentMethod: 'Efectivo',
          operationId: 'convert',
        )).id,
        sale.id,
      );
      expect(
        (await repository.convertQuote(
          document.id,
          paid: 160,
          paymentMethod: 'Efectivo',
          operationId: 'convert-fresh-id',
        )).id,
        sale.id,
      );
      await expectLater(
        repository.convertQuote(
          document.id,
          paid: 100,
          paymentMethod: 'Efectivo',
          operationId: 'convert',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listSales(), hasLength(1));
      expect(await repository.listPayments(), hasLength(1));
      expect((await repository.listQuotes()).single.saleId, sale.id);
      expect(
        (await repository.listQuotes()).single.status,
        QuoteStatus.converted,
      );
    },
  );

  test(
    'insufficient shared materials roll back quote conversion and preserve advance',
    () async {
      await repository.saveProduct(material(stock: 4, cost: 10));
      await repository.saveProduct(
        const Product(
          id: 'print',
          code: 'PRINT',
          name: 'Impresión',
          unit: 'Servicio',
          isService: true,
          purchasePrice: 5,
          salePrice: 200,
          stock: 0,
          minimumStock: 0,
        ),
      );
      await repository.setServiceRecipe('print', const [
        ServiceMaterial(productId: 'paper', quantity: 2),
      ]);
      final document = await quote(
        items: const [
          QuoteLineInput(
            productId: 'paper',
            description: 'Papel',
            quantity: 1,
            unitPrice: 80,
          ),
          QuoteLineInput(
            productId: 'print',
            description: 'Impresión',
            quantity: 2,
            unitPrice: 200,
          ),
          QuoteLineInput(
            description: 'Diseño personalizado',
            quantity: 1,
            unitPrice: 300,
          ),
        ],
      );
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Diseño e impresión',
        responsible: 'Operario',
        deliveryAt: futureDate,
        quoteId: document.id,
        operationId: 'work',
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await repository.addWorkAdvance(
        work.id,
        100,
        'Efectivo',
        received: 200,
        operationId: 'advance',
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await expectLater(
        repository.convertQuote(
          document.id,
          paid: 680,
          paymentMethod: 'Efectivo',
          operationId: 'convert',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listSales(), isEmpty);
      expect((await repository.listWorkOrders()).single.unappliedAdvances, 100);
      expect(
        (await repository.listProducts())
            .firstWhere((p) => p.id == 'paper')
            .stock,
        4,
      );
      await repository.adjustStock(
        'paper',
        1,
        'Unidad recibida',
        operationId: 'adjust',
      );
      final sale = await repository.convertQuote(
        document.id,
        paid: 680,
        paymentMethod: 'Efectivo',
        operationId: 'convert',
      );
      expect(sale.total, 780);
      expect(sale.paid, 780);
      expect(sale.prepaid, 100);
      expect(
        sale.lines.last.costKnown,
        isFalse,
        reason: 'Unknown custom job cost cannot yield an invented profit.',
      );
      expect(
        (await repository.listProducts())
            .firstWhere((p) => p.id == 'paper')
            .stock,
        0,
      );
      expect((await repository.listWorkOrders()).single.unappliedAdvances, 0);
      expect((await repository.listWorkAdvances()).single.applied, isTrue);
      expect((await repository.listWorkAdvances()).single.change, 100);
      expect((await repository.listPayments()).single.amount, 680);
      final cash = await repository.listCashMovements();
      expect(cash.where((m) => m.kind == 'work.advance'), hasLength(1));
      expect(
        cash
            .where((m) => m.amount > 0)
            .fold<int>(0, (sum, m) => sum + m.amount),
        780,
      );
    },
  );

  test(
    'credit conversion requires a due date without applying advances or stock on failure',
    () async {
      await repository.saveProduct(material(stock: 3));
      final document = await quote();
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Pedido con anticipo',
        responsible: 'Operario',
        deliveryAt: futureDate,
        quoteId: document.id,
      );
      await repository.addWorkAdvance(
        work.id,
        40,
        'Efectivo',
        operationId: 'partial-advance',
      );
      final movementsBefore = (await repository.listCashMovements()).length;
      final stockBefore = (await repository.listStockMovements()).length;
      final auditBefore = (await repository.listAudit()).length;
      await expectLater(
        repository.convertQuote(
          document.id,
          paid: 20,
          paymentMethod: 'Efectivo',
          operationId: 'credit-convert',
        ),
        throwsA(
          isA<CapcException>().having(
            (error) => error.message,
            'message',
            contains('vencimiento'),
          ),
        ),
      );
      expect(await repository.listSales(), isEmpty);
      expect(await repository.listPayments(), isEmpty);
      expect((await repository.listProducts()).single.stock, 3);
      expect(await repository.listCashMovements(), hasLength(movementsBefore));
      expect(await repository.listStockMovements(), hasLength(stockBefore));
      expect(await repository.listAudit(), hasLength(auditBefore));
      final pending = (await repository.listQuotes()).single;
      expect(pending.status, QuoteStatus.accepted);
      expect(pending.saleId, isNull);
      expect((await repository.listWorkOrders()).single.unappliedAdvances, 40);
      expect((await repository.listWorkAdvances()).single.applied, isFalse);

      final sale = await repository.convertQuote(
        document.id,
        paid: 20,
        paymentMethod: 'Efectivo',
        dueAt: futureDate,
        operationId: 'credit-convert',
      );
      expect(sale.number, 'V-000001');
      expect(sale.prepaid, 40);
      expect(sale.paid, 60);
      expect(sale.balance, 100);
      expect(sale.dueAt, futureDate);
      expect((await repository.listProducts()).single.stock, 1);
      expect((await repository.listWorkOrders()).single.unappliedAdvances, 0);
      final retry = await repository.convertQuote(
        document.id,
        paid: 20,
        paymentMethod: 'Efectivo',
        dueAt: futureDate,
        operationId: 'credit-convert',
      );
      expect(retry.id, sale.id);
      expect(await repository.listPayments(), hasLength(1));
      expect(
        await repository.listCashMovements(),
        hasLength(movementsBefore + 1),
      );
    },
  );

  test(
    'work advances apply once to the correct customer without collecting again',
    () async {
      await repository.saveProduct(material(stock: 5));
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Trabajo sin cotización',
        responsible: 'Operario',
        deliveryAt: futureDate,
        operationId: 'work',
      );
      final advance = await repository.addWorkAdvance(
        work.id,
        60,
        'Transferencia',
        operationId: 'advance',
      );
      expect(
        (await repository.addWorkAdvance(
          work.id,
          60,
          'Transferencia',
          operationId: 'advance',
        )).id,
        advance.id,
      );
      await expectLater(
        repository.addWorkAdvance(
          work.id,
          61,
          'Transferencia',
          operationId: 'advance',
        ),
        throwsA(isA<CapcException>()),
      );
      final sale = await repository.createSale(
        items: const [CartLine(productId: 'paper', quantity: 1)],
        customerId: 'ana',
        paid: 0,
        paymentMethod: 'Efectivo',
        dueAt: futureDate,
        operationId: 'sale',
      );
      final before = (await repository.listCashMovements()).length;
      final applied = await repository.applyWorkAdvances(
        work.id,
        sale.id,
        operationId: 'apply',
      );
      expect(applied.paid, 60);
      expect(applied.balance, 40);
      expect(applied.prepaid, 60);
      await repository.applyWorkAdvances(
        work.id,
        sale.id,
        operationId: 'apply',
      );
      await repository.applyWorkAdvances(
        work.id,
        sale.id,
        operationId: 'apply-again',
      );
      expect((await repository.listCashMovements()).length, before);
      expect(await repository.listPayments(), isEmpty);
      await expectLater(
        repository.addWorkAdvance(
          work.id,
          10,
          'Efectivo',
          operationId: 'after-sale',
        ),
        throwsA(isA<CapcException>()),
      );
      await repository.addPayment(
        sale.id,
        40,
        'Tarjeta',
        operationId: 'balance',
      );
      expect((await repository.listSales()).single.status, 'Pagada');
    },
  );

  test(
    'advances cannot overpay quotes or another customer and work states are sequential',
    () async {
      await repository.saveProduct(material(stock: 5));
      final document = await quote();
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Trabajo',
        responsible: 'Operario',
        deliveryAt: futureDate,
        quoteId: document.id,
        operationId: 'work',
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await repository.addWorkAdvance(
        work.id,
        160,
        'Efectivo',
        operationId: 'advance',
      );
      await expectLater(
        repository.addWorkAdvance(work.id, 1, 'Efectivo', operationId: 'over'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.updateWorkOrder(
          work.id,
          status: WorkStatus.ready,
          responsible: 'Operario',
          deliveryAt: futureDate,
        ),
        throwsA(isA<CapcException>()),
      );
      await repository.updateWorkOrder(
        work.id,
        status: WorkStatus.inProgress,
        responsible: 'Operario',
        deliveryAt: futureDate,
      );
      await repository.updateWorkOrder(
        work.id,
        status: WorkStatus.ready,
        responsible: 'Operario',
        deliveryAt: futureDate,
      );
      await expectLater(
        repository.updateWorkOrder(
          work.id,
          status: WorkStatus.delivered,
          responsible: 'Operario',
          deliveryAt: futureDate,
        ),
        throwsA(isA<CapcException>()),
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await expectLater(
        repository.convertQuote(
          document.id,
          paid: 1,
          paymentMethod: 'Efectivo',
          operationId: 'excess-payment',
        ),
        throwsA(isA<CapcException>()),
      );
      final sale = await repository.convertQuote(
        document.id,
        paid: 0,
        paymentMethod: 'Efectivo',
        operationId: 'convert',
      );
      expect(sale.balance, 0);
      await repository.updateWorkOrder(
        work.id,
        status: WorkStatus.delivered,
        responsible: 'Operario',
        deliveryAt: futureDate,
      );
      expect(
        (await repository.listWorkOrders()).single.status,
        WorkStatus.delivered,
      );
    },
  );

  test('cashier permissions are enforced by purchasing methods', () async {
    await repository.saveProduct(material());
    await repository.saveUser(
      name: 'Cajera',
      username: 'cashier',
      password: 'Otra-clave-larga-2026',
      role: UserRole.cashier,
    );
    await repository.login('cashier', 'Otra-clave-larga-2026');
    await expectLater(buy(), throwsA(isA<CapcException>()));
    await expectLater(
      repository.saveSupplier(
        const Supplier(id: 'blocked', name: 'No permitido'),
      ),
      throwsA(isA<CapcException>()),
    );
    await expectLater(
      repository.listPurchases(),
      throwsA(isA<CapcException>()),
    );
    await expectLater(quote(), throwsA(isA<CapcException>()));
    final document = await quote(
      items: const [
        QuoteLineInput(
          productId: 'paper',
          description: 'Papel',
          quantity: 1,
          unitPrice: 100,
        ),
      ],
    );
    expect(document.operatorName, 'Cajera');
  });

  test(
    'custom quote prices require permission but cashiers can convert authorized terms',
    () async {
      const original = [
        QuoteLineInput(
          description: 'Diseño a medida',
          quantity: 1,
          unitPrice: 300,
          directCost: 100,
        ),
      ];
      const revised = [
        QuoteLineInput(
          description: 'Diseño revisado',
          quantity: 1,
          unitPrice: 400,
          directCost: 120,
        ),
      ];
      final document = await quote(items: original);
      await repository.saveUser(
        name: 'Cajera',
        username: 'cashier',
        password: 'Otra-clave-larga-2026',
        role: UserRole.cashier,
      );
      await repository.saveUser(
        name: 'Administradora',
        username: 'admin',
        password: 'Clave-administradora-2026',
        role: UserRole.admin,
      );
      await repository.login('cashier', 'Otra-clave-larga-2026');
      await expectLater(
        quote(items: original, operationId: 'custom-cashier-quote'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.updateQuote(
          document.id,
          description: 'Cambio no autorizado',
          items: revised,
          validUntil: futureDate,
        ),
        throwsA(isA<CapcException>()),
      );
      final unchanged = (await repository.listQuotes()).single;
      expect(unchanged.total, 300);
      expect(unchanged.description, document.description);
      expect(unchanged.lines.single.description, 'Diseño a medida');
      expect(unchanged.lines.single.directCost, 100);

      await repository.login('admin', 'Clave-administradora-2026');
      final authorized = await repository.updateQuote(
        document.id,
        description: 'Trabajo autorizado',
        items: revised,
        validUntil: futureDate,
        conditions: 'Condiciones autorizadas',
      );
      expect(authorized.total, 400);
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await repository.login('cashier', 'Otra-clave-larga-2026');
      final sale = await repository.convertQuote(
        document.id,
        paid: 400,
        paymentMethod: 'Efectivo',
        operationId: 'authorized-custom-convert',
      );
      expect(sale.operatorName, 'Cajera');
      expect(sale.lines.single.name, 'Diseño revisado');
      expect(sale.lines.single.unitPrice, 400);
      expect(sale.lines.single.costTotalMicros, 120000000);
      expect(sale.balance, 0);
      expect(
        (await repository.listQuotes()).single.conditions,
        'Condiciones autorizadas',
      );
      expect(await repository.listPayments(), hasLength(1));
    },
  );

  test(
    'a failed multi-material receipt rolls back every inventory entry',
    () async {
      await repository.saveProduct(material());
      await repository.saveProduct(material(id: 'full', stock: 1000000000));
      final purchase = await repository.createPurchase(
        supplierId: 'supply',
        reference: 'Recepción imposible',
        dueAt: futureDate,
        items: const [
          PurchaseItemInput(productId: 'paper', quantity: 3, totalCost: 100),
          PurchaseItemInput(productId: 'full', quantity: 1, totalCost: 100),
        ],
        operationId: 'overflow-purchase',
      );
      final before = (await repository.listStockMovements()).length;
      await expectLater(
        repository.receivePurchase(
          purchase.id,
          operationId: 'overflow-receipt',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(
        (await repository.listProducts())
            .firstWhere((p) => p.id == 'paper')
            .stock,
        0,
      );
      expect((await repository.listStockMovements()).length, before);
      expect((await repository.listPurchases()).single.received, isFalse);
    },
  );

  test(
    'closed cash prevents payments atomically but allows unpaid purchase and quote',
    () async {
      await repository.saveProduct(material());
      await repository.closeCash(1000000, operationId: 'close');
      await expectLater(buy(paid: 100), throwsA(isA<CapcException>()));
      expect(await repository.listPurchases(), isEmpty);
      expect(await repository.listSupplierPayments(), isEmpty);
      final purchase = await buy();
      expect(purchase.paid, 0);
      final document = await quote();
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Pendiente',
        responsible: 'Operario',
        deliveryAt: futureDate,
        quoteId: document.id,
        operationId: 'work',
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      await expectLater(
        repository.addWorkAdvance(
          work.id,
          20,
          'Efectivo',
          operationId: 'advance',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listWorkAdvances(), isEmpty);
      await repository.openCash(1000, operationId: 'reopen');
      await repository.addWorkAdvance(
        work.id,
        20,
        'Efectivo',
        operationId: 'advance',
      );
      expect(await repository.listWorkAdvances(), hasLength(1));
    },
  );

  test(
    'same material at two quoted prices preserves both accepted concepts',
    () async {
      await repository.saveProduct(material(stock: 5));
      final document = await quote(
        items: const [
          QuoteLineInput(
            productId: 'paper',
            description: 'Primer concepto',
            quantity: 1,
            unitPrice: 80,
          ),
          QuoteLineInput(
            productId: 'paper',
            description: 'Segundo concepto',
            quantity: 2,
            unitPrice: 70,
          ),
        ],
      );
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      final sale = await repository.convertQuote(
        document.id,
        paid: 220,
        paymentMethod: 'Efectivo',
        operationId: 'different-prices',
      );
      expect(sale.total, 220);
      expect(sale.lines, hasLength(2));
      expect(sale.lines.map((line) => line.name).toSet(), {
        'Primer concepto',
        'Segundo concepto',
      });
      expect(sale.lines.map((line) => line.unitPrice).toSet(), {70, 80});
      expect((await repository.listProducts()).single.stock, 2);
    },
  );

  test(
    'work advance rejects the wrong customer and overpayment without applying it',
    () async {
      await repository.saveProduct(material(stock: 5));
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Pedido',
        responsible: 'Operario',
        deliveryAt: futureDate,
        operationId: 'work',
      );
      await repository.addWorkAdvance(
        work.id,
        150,
        'Efectivo',
        operationId: 'advance',
      );
      await repository.saveCustomer(
        const Customer(id: 'other', name: 'Otro cliente'),
      );
      final otherSale = await repository.createSale(
        items: const [CartLine(productId: 'paper', quantity: 2)],
        customerId: 'other',
        paid: 0,
        dueAt: futureDate,
        paymentMethod: 'Efectivo',
        operationId: 'other-sale',
      );
      await expectLater(
        repository.applyWorkAdvances(
          work.id,
          otherSale.id,
          operationId: 'wrong-customer',
        ),
        throwsA(isA<CapcException>()),
      );
      final insufficientSale = await repository.createSale(
        items: const [CartLine(productId: 'paper', quantity: 1)],
        customerId: 'ana',
        paid: 0,
        dueAt: futureDate,
        paymentMethod: 'Efectivo',
        operationId: 'small-sale',
      );
      await expectLater(
        repository.applyWorkAdvances(
          work.id,
          insufficientSale.id,
          operationId: 'too-much',
        ),
        throwsA(isA<CapcException>()),
      );
      expect((await repository.listWorkOrders()).single.unappliedAdvances, 150);
      expect((await repository.listWorkAdvances()).single.applied, isFalse);
      expect(
        (await repository.listSales()).fold<int>(
          0,
          (sum, sale) => sum + sale.paid,
        ),
        0,
      );
    },
  );

  test(
    'accepted terms survive expiry and retain the advance until conversion',
    () async {
      await repository.saveProduct(material(stock: 5));
      final document = await quote();
      await repository.updateQuoteStatus(document.id, QuoteStatus.accepted);
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Trabajo aceptado',
        responsible: 'Operario',
        deliveryAt: futureDate,
        quoteId: document.id,
        operationId: 'work',
      );
      await repository.addWorkAdvance(
        work.id,
        100,
        'Efectivo',
        operationId: 'first-advance',
      );
      expireFixtureQuote(document.id);
      expect((await repository.listQuotes()).single.isExpired, isTrue);
      await expectLater(
        repository.updateQuoteStatus(document.id, QuoteStatus.expired),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.updateQuoteStatus(document.id, QuoteStatus.rejected),
        throwsA(isA<CapcException>()),
      );
      await repository.addWorkAdvance(
        work.id,
        60,
        'Tarjeta',
        operationId: 'second-advance',
      );
      final sale = await repository.convertQuote(
        document.id,
        paid: 0,
        paymentMethod: 'Efectivo',
        operationId: 'convert',
      );
      expect(sale.total, 160);
      expect(sale.prepaid, 160);
      expect(sale.balance, 0);
      expect(await repository.listPayments(), isEmpty);
      expect((await repository.listWorkOrders()).single.unappliedAdvances, 0);
    },
  );

  test(
    'unaccepted offers cannot collect linked advances or be accepted after expiry',
    () async {
      await repository.saveProduct(material(stock: 5));
      final document = await quote();
      final work = await repository.createWorkOrder(
        customerId: 'ana',
        description: 'Trabajo pendiente de aceptar',
        responsible: 'Operario',
        deliveryAt: futureDate,
        quoteId: document.id,
        operationId: 'work',
      );
      await expectLater(
        repository.addWorkAdvance(
          work.id,
          100,
          'Efectivo',
          operationId: 'advance',
        ),
        throwsA(isA<CapcException>()),
      );
      expireFixtureQuote(document.id);
      await expectLater(
        repository.updateQuoteStatus(document.id, QuoteStatus.accepted),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.convertQuote(
          document.id,
          paid: 160,
          paymentMethod: 'Efectivo',
          operationId: 'convert',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listWorkAdvances(), isEmpty);
      expect(await repository.listSales(), isEmpty);
      expect((await repository.listProducts()).single.stock, 5);
    },
  );
}
