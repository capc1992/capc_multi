import 'dart:convert';
import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/sync/sync_engine.dart';
import 'package:capc_multiservicio/sync/sync_models.dart';
import 'package:capc_multiservicio/sync/sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as native;

const ownerPassword = 'Clave-local-segura-2026';

Product material({String id = '55555555-5555-4555-8555-555555555555'}) =>
    Product(
      id: id,
      code: 'PAP-001',
      name: 'Papel carta',
      unit: 'Hoja',
      isService: false,
      purchasePrice: 50,
      salePrice: 200,
      stock: 0,
      minimumStock: 1,
    );

class MemoryTransport implements SyncTransport {
  int _cursor = 0;
  bool loseNextResponse = false;
  bool reverseNextPull = false;
  final List<SyncOperation> operations = [];

  @override
  Future<List<SyncPushAck>> push(List<SyncOperation> outgoing) async {
    final acknowledgements = <SyncPushAck>[];
    for (final operation in outgoing) {
      final existing = operations.where(
        (candidate) =>
            candidate.businessId == operation.businessId &&
            candidate.operationId == operation.operationId,
      );
      if (existing.isNotEmpty) {
        final saved = existing.single;
        if (jsonEncode(saved.toJson()) !=
            jsonEncode({
              ...operation.toJson(),
              'server_cursor': saved.serverCursor,
            })) {
          throw const SyncTransportException(
            'El identificador se reutilizó con otro contenido.',
          );
        }
        acknowledgements.add(
          SyncPushAck(
            operationId: operation.operationId,
            serverCursor: saved.serverCursor!,
            duplicate: true,
          ),
        );
      } else {
        final stored = SyncOperation(
          businessId: operation.businessId,
          deviceId: operation.deviceId,
          operationId: operation.operationId,
          type: operation.type,
          schemaVersion: operation.schemaVersion,
          occurredAt: operation.occurredAt,
          content: operation.content,
          serverCursor: ++_cursor,
        );
        operations.add(stored);
        acknowledgements.add(
          SyncPushAck(
            operationId: operation.operationId,
            serverCursor: stored.serverCursor!,
            duplicate: false,
          ),
        );
      }
    }
    if (loseNextResponse) {
      loseNextResponse = false;
      throw const SyncTransportException(
        'Respuesta perdida después de confirmar.',
      );
    }
    return acknowledgements;
  }

  @override
  Future<SyncPullPage> pull({
    required String businessId,
    required String deviceId,
    required int afterCursor,
    int limit = 200,
  }) async {
    var selected = operations
        .where(
          (operation) =>
              operation.businessId == businessId &&
              operation.serverCursor! > afterCursor,
        )
        .take(limit)
        .toList(growable: false);
    if (reverseNextPull) {
      reverseNextPull = false;
      selected = selected.reversed.toList(growable: false);
    }
    final next = selected.fold<int>(
      afterCursor,
      (value, operation) =>
          operation.serverCursor! > value ? operation.serverCursor! : value,
    );
    return SyncPullPage(
      operations: selected,
      nextCursor: next,
      hasMore: operations
          .where(
            (operation) =>
                operation.businessId == businessId &&
                operation.serverCursor! > next,
          )
          .isNotEmpty,
    );
  }
}

Future<CapcRepository> openOwned(String path) async {
  final repository = await CapcRepository.open(path);
  if (await repository.needsSetup()) {
    await repository.setupOwner(
      name: 'Propietaria',
      username: 'owner',
      password: ownerPassword,
    );
  } else {
    await repository.login('owner', ownerPassword);
  }
  return repository;
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_sync_foundation_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'esquema 2 migra a inbox, cursor e intentos sin perder outbox',
    () async {
      final path = p.join(directory.path, 'schema2.sqlite3');
      var repository = await openOwned(path);
      await repository.saveProduct(material());
      await repository.close();

      final db = native.sqlite3.open(path);
      try {
        db.execute('ALTER TABLE outbox RENAME TO outbox_v3');
        db.execute('''CREATE TABLE outbox(
        id TEXT PRIMARY KEY NOT NULL,business_id TEXT NOT NULL,device_id TEXT NOT NULL,
        operation_id TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,schema_version INTEGER NOT NULL,
        payload TEXT NOT NULL,created_at TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending'
        CHECK(state='pending'))''');
        db.execute('''INSERT INTO outbox
        (id,business_id,device_id,operation_id,kind,schema_version,payload,created_at,state)
        SELECT id,business_id,device_id,operation_id,kind,schema_version,payload,created_at,'pending'
        FROM outbox_v3''');
        db.execute('DROP TABLE outbox_v3');
        db.execute('DROP TABLE inbox');
        db.execute('DROP TABLE sync_state');
        db.execute('DROP TABLE sync_conflicts');
        db.execute('PRAGMA user_version=2');
      } finally {
        db.close();
      }

      repository = await openOwned(path);
      expect(await repository.pendingSyncOperations(), 1);
      await repository.close();
      final migrated = native.sqlite3.open(
        path,
        mode: native.OpenMode.readOnly,
      );
      try {
        expect(migrated.select('PRAGMA user_version').single.values.single, 8);
        expect(
          migrated
              .select('SELECT retry_count,state FROM outbox')
              .single['retry_count'],
          0,
        );
        expect(migrated.select('SELECT * FROM inbox'), isEmpty);
        expect(
          migrated.select('SELECT cursor FROM sync_state').single['cursor'],
          0,
        );
      } finally {
        migrated.close();
      }
    },
  );

  test('sin URL conserva operación local y no intenta conectarse', () async {
    final repository = await openOwned(
      p.join(directory.path, 'offline.sqlite3'),
    );
    await repository.saveProduct(material());
    final engine = SyncEngine(
      repository: repository,
      configuration: const SyncConfiguration(),
    );
    final result = await engine.runOnce();
    expect(result.enabled, isFalse);
    expect(await repository.pendingSyncOperations(), 1);
    expect((await repository.syncStatus()).status, SyncStatus.localOnly);
    await repository.close();
  });

  test('acuse remoto conserva conflictos y deja una revisión durable', () async {
    final path = p.join(directory.path, 'ack-conflict.sqlite3');
    final repository = await openOwned(path);
    await repository.saveProduct(material());
    final outgoing = await repository.prepareSyncPush();
    expect(outgoing, hasLength(1));
    await repository.acknowledgeSyncPush([
      SyncPushAck(
        operationId: outgoing.single.operationId,
        serverCursor: 41,
        duplicate: false,
        conflicts: 1,
      ),
    ]);
    expect(await repository.pendingSyncOperations(), 0);
    final conflicts = await repository.listSyncConflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.kind, 'server.conflict');
    await repository.markSyncConflictReviewed(conflicts.single.id);
    expect(await repository.listSyncConflicts(), isEmpty);
    expect(
      await repository.listSyncConflicts(includeResolved: true),
      hasLength(1),
    );
    await repository.close();

    final db = native.sqlite3.open(path, mode: native.OpenMode.readOnly);
    try {
      final outbox = db.select('SELECT state,server_cursor FROM outbox').single;
      expect(outbox['state'], 'acknowledged');
      expect(outbox['server_cursor'], 41);
      final conflict = db
          .select(
            "SELECT kind,entity_id,details,resolved_at FROM sync_conflicts WHERE kind='server.conflict'",
          )
          .single;
      expect(conflict['entity_id'], material().id);
      expect(conflict['resolved_at'], isNotNull);
      expect(
        jsonDecode(conflict['details'] as String),
        containsPair('count', 1),
      );
    } finally {
      db.close();
    }
  });

  test(
    'errores transitorios esperan y el reintento manual los libera',
    () async {
      final repository = await openOwned(
        p.join(directory.path, 'retryable.sqlite3'),
      );
      await repository.saveProduct(material());
      final outgoing = await repository.prepareSyncPush();
      await repository.failSyncPush(
        [outgoing.single.operationId],
        'Servicio temporalmente no disponible.',
        code: 'http_503',
      );
      expect(await repository.prepareSyncPush(), isEmpty);
      await repository.retryFailedSyncNow();
      expect(await repository.prepareSyncPush(), hasLength(1));
      await repository.close();
    },
  );

  test(
    'errores permanentes no se reenvían automáticamente ni manualmente',
    () async {
      final repository = await openOwned(
        p.join(directory.path, 'permanent.sqlite3'),
      );
      await repository.saveProduct(material());
      final outgoing = await repository.prepareSyncPush();
      await repository.failSyncPush(
        [outgoing.single.operationId],
        'La operación fue rechazada.',
        retryable: false,
        code: 'operation_id_conflict',
      );
      await repository.retryFailedSyncNow();
      expect(await repository.prepareSyncPush(), isEmpty);
      expect(await repository.pendingSyncOperations(), 1);
      await repository.close();
    },
  );

  test('transporte conserva exactamente enteros monetarios grandes', () {
    final original = SyncOperation(
      businessId: '11111111-1111-4111-8111-111111111111',
      deviceId: '22222222-2222-4222-8222-222222222222',
      operationId: '33333333-3333-4333-8333-333333333333',
      type: 'stock.adjusted',
      schemaVersion: 1,
      occurredAt: DateTime.utc(2026, 9, 27),
      content: const {'cost_micros': 9000000000000000000},
    );
    final wire =
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
    expect((wire['content'] as Map)['cost_micros'], '9000000000000000000');
    final decoded = SyncOperation.fromJson(wire);
    expect(decoded.content['cost_micros'], 9000000000000000000);
  });

  test(
    'Windows y Android temporales convergen producto, cliente, venta, pago y movimiento',
    () async {
      final windowsPath = p.join(directory.path, 'windows.sqlite3');
      final androidPath = p.join(directory.path, 'android.sqlite3');
      final windows = await openOwned(windowsPath);
      addTearDown(windows.close);
      await windows.backupTo(androidPath);
      final cloned = native.sqlite3.open(androidPath);
      try {
        cloned.execute("UPDATE settings SET value=? WHERE key='device_id'", [
          '66666666-6666-4666-8666-666666666666',
        ]);
      } finally {
        cloned.close();
      }
      final android = await openOwned(androidPath);
      addTearDown(android.close);
      final transport = MemoryTransport();
      final configuration = SyncConfiguration(
        baseUri: Uri(scheme: 'http', host: 'localhost', port: 3100),
      );

      await windows.saveProduct(material());
      await windows.saveCustomer(
        const Customer(
          id: '77777777-7777-4777-8777-777777777777',
          name: 'Ana',
          phone: '3000000000',
        ),
      );
      await windows.adjustStock(
        '55555555-5555-4555-8555-555555555555',
        3,
        'Entrada inicial',
        totalCost: 150,
        operationId: '88888888-8888-4888-8888-888888888888',
      );
      await windows.openCash(
        0,
        operationId: '99999999-9999-4999-8999-999999999999',
      );
      final sale = await windows.createSale(
        items: const [
          CartLine(
            productId: '55555555-5555-4555-8555-555555555555',
            quantity: 1,
          ),
        ],
        customerId: '77777777-7777-4777-8777-777777777777',
        paid: 0,
        paymentMethod: 'Efectivo',
        dueAt: DateTime.utc(2026, 10, 30),
        operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      await windows.addPayment(
        sale.id,
        200,
        'Efectivo',
        operationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      );

      final windowsEngine = SyncEngine(
        repository: windows,
        configuration: configuration,
        transport: transport,
      );
      await windowsEngine.runOnce();
      transport.reverseNextPull = true;
      final androidEngine = SyncEngine(
        repository: android,
        configuration: configuration,
        transport: transport,
      );
      final received = await androidEngine.runOnce();

      expect(received.received, greaterThanOrEqualTo(5));
      expect((await android.listProducts()).single.stock, 2);
      expect((await android.listCustomers()).single.name, 'Ana');
      final remoteSale = (await android.listSales()).single;
      expect(remoteSale.id, sale.id);
      expect(remoteSale.paid, 200);
      expect(await android.listPayments(saleId: sale.id), hasLength(1));
      expect(
        (await android.listStockMovements()).where((item) => item.delta < 0),
        hasLength(1),
      );

      final before = transport.operations.length;
      transport.loseNextResponse = true;
      await windows.saveCustomer(
        const Customer(
          id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          name: 'Beatriz',
        ),
      );
      await expectLater(
        windowsEngine.runOnce(),
        throwsA(isA<SyncTransportException>()),
      );
      final afterLostResponse = transport.operations.length;
      expect(afterLostResponse, before + 1);
      await windowsEngine.runOnce();
      expect(transport.operations.length, afterLostResponse);

      await androidEngine.runOnce();
      expect(await android.listSales(), hasLength(1));
      expect(await android.listCustomers(), hasLength(2));
      expect((await android.syncStatus()).status, SyncStatus.synced);

      await android.close();
      await windows.close();
    },
  );

  test('movimiento remoto negativo se conserva y crea conflicto', () async {
    final path = p.join(directory.path, 'conflict.sqlite3');
    final repository = await openOwned(path);
    await repository.saveProduct(material());
    final operation = SyncOperation(
      businessId: repository.businessId,
      deviceId: '66666666-6666-4666-8666-666666666666',
      operationId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      type: 'stock.adjusted',
      schemaVersion: 1,
      occurredAt: DateTime.utc(2026, 9, 27),
      serverCursor: 1,
      content: const {
        'movement': {
          'id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          'product_id': '55555555-5555-4555-8555-555555555555',
          'product_name': 'Papel carta',
          'delta': -1,
          'cost_micros': 50000000,
          'reason': 'Venta offline remota',
          'kind': 'Venta',
          'created_at': '2026-09-27T00:00:00.000Z',
          'reference_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
          'actor_id': null,
          'actor_name': 'Remoto',
        },
      },
    );
    final result = await repository.receiveSyncOperations([
      operation,
    ], nextCursor: 1);
    expect(result.conflicts, 1);
    expect((await repository.listProducts()).single.stock, 0);
    await repository.close();
    final db = native.sqlite3.open(path, mode: native.OpenMode.readOnly);
    try {
      expect(db.select('SELECT * FROM stock_movements'), hasLength(1));
      expect(
        db.select(
          "SELECT * FROM sync_conflicts WHERE kind='inventory.negative'",
        ),
        hasLength(1),
      );
    } finally {
      db.close();
    }
  });

  test(
    'dos SQLite materializan compras, devoluciones, caja, cotizaciones y trabajos',
    () async {
      final sourcePath = p.join(directory.path, 'source-stage2.sqlite3');
      final targetPath = p.join(directory.path, 'target-stage2.sqlite3');
      final source = await openOwned(sourcePath);
      addTearDown(source.close);
      await source.backupTo(targetPath);
      final cloned = native.sqlite3.open(targetPath);
      try {
        cloned.execute("UPDATE settings SET value=? WHERE key='device_id'", [
          '66666666-6666-4666-8666-666666666666',
        ]);
      } finally {
        cloned.close();
      }
      final target = await openOwned(targetPath);
      addTearDown(target.close);

      const productId = '55555555-5555-4555-8555-555555555555';
      const customerId = '77777777-7777-4777-8777-777777777777';
      const supplierId = '88888888-8888-4888-8888-888888888888';
      await source.saveProduct(material());
      await source.saveCustomer(const Customer(id: customerId, name: 'Ana'));
      await source.saveSupplier(
        const Supplier(id: supplierId, name: 'Proveedor etapa 2'),
      );
      await source.openCash(
        1000,
        operationId: '99999999-9999-4999-8999-999999999999',
      );
      final purchase = await source.createPurchase(
        supplierId: supplierId,
        reference: 'Compra sincronizada',
        items: const [
          PurchaseItemInput(productId: productId, quantity: 3, totalCost: 150),
        ],
        dueAt: DateTime.utc(2026, 11, 1),
        operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      await source.receivePurchase(
        purchase.id,
        operationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      );
      await source.addSupplierPayment(
        purchase.id,
        50,
        'Efectivo',
        operationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      final sale = await source.createSale(
        items: const [CartLine(productId: productId, quantity: 1)],
        customerId: customerId,
        paid: 200,
        paymentMethod: 'Efectivo',
        operationId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      );
      await source.returnSale(
        sale.id,
        [SaleReturnItem(saleLineId: sale.lines.single.id, quantity: 1)],
        reason: 'Devolución sincronizada',
        operationId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      );
      await source.addExpense(
        25,
        'Mensajería',
        operationId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      );
      final quote = await source.createQuote(
        customerId: customerId,
        description: 'Cotización sincronizada',
        items: const [
          QuoteLineInput(
            productId: productId,
            description: 'Papel',
            quantity: 1,
            unitPrice: 200,
          ),
        ],
        validUntil: DateTime.utc(2026, 12, 1),
        operationId: '12345678-1234-4234-8234-123456789012',
      );
      await source.updateQuoteStatus(quote.id, QuoteStatus.accepted);
      final work = await source.createWorkOrder(
        customerId: customerId,
        description: 'Trabajo sincronizado',
        responsible: 'Operaria',
        deliveryAt: DateTime.utc(2026, 11, 15),
        quoteId: quote.id,
        operationId: '23456789-1234-4234-8234-123456789012',
      );
      await source.addWorkAdvance(
        work.id,
        50,
        'Efectivo',
        operationId: '34567890-1234-4234-8234-123456789012',
      );

      final transport = MemoryTransport();
      final configuration = SyncConfiguration(
        baseUri: Uri(scheme: 'http', host: 'localhost', port: 3100),
      );
      await SyncEngine(
        repository: source,
        configuration: configuration,
        transport: transport,
      ).runOnce();
      final received = await SyncEngine(
        repository: target,
        configuration: configuration,
        transport: transport,
      ).runOnce();

      expect(received.conflicts, 0);
      expect(await target.listSuppliers(), hasLength(1));
      final remotePurchase = (await target.listPurchases()).single;
      expect(remotePurchase.received, isTrue);
      expect(remotePurchase.paid, 50);
      expect(await target.listSaleReturns(), hasLength(1));
      final targetDatabase = native.sqlite3.open(
        targetPath,
        mode: native.OpenMode.readOnly,
      );
      try {
        expect(targetDatabase.select('SELECT * FROM expenses'), hasLength(1));
      } finally {
        targetDatabase.close();
      }
      expect((await target.listQuotes()).single.status, QuoteStatus.accepted);
      expect(await target.listWorkOrders(), hasLength(1));
      expect(await target.listWorkAdvances(), hasLength(1));
      expect((await target.listProducts()).single.stock, 3);
      expect(await target.listCashMovements(), isNotEmpty);

      await target.close();
      await source.close();
    },
  );

  test(
    'dos ventas offline con el mismo consecutivo convergen sin perder documentos',
    () async {
      final firstPath = p.join(directory.path, 'number-first.sqlite3');
      final secondPath = p.join(directory.path, 'number-second.sqlite3');
      final first = await openOwned(firstPath);
      addTearDown(first.close);
      await first.saveProduct(
        const Product(
          id: '55555555-5555-4555-8555-555555555555',
          code: 'SERV-001',
          name: 'Servicio',
          unit: 'Unidad',
          isService: true,
          purchasePrice: 0,
          salePrice: 100,
          stock: 0,
          minimumStock: 0,
        ),
      );
      await first.backupTo(secondPath);
      final cloned = native.sqlite3.open(secondPath);
      try {
        cloned.execute("UPDATE settings SET value=? WHERE key='device_id'", [
          '66666666-6666-4666-8666-666666666666',
        ]);
      } finally {
        cloned.close();
      }
      final second = await openOwned(secondPath);
      addTearDown(second.close);

      await first.openCash(
        0,
        operationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      await second.openCash(
        0,
        operationId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      );

      final firstSale = await first.createSale(
        items: const [
          CartLine(
            productId: '55555555-5555-4555-8555-555555555555',
            quantity: 1,
          ),
        ],
        paid: 100,
        paymentMethod: 'Efectivo',
        operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      final secondSale = await second.createSale(
        items: const [
          CartLine(
            productId: '55555555-5555-4555-8555-555555555555',
            quantity: 1,
          ),
        ],
        paid: 100,
        paymentMethod: 'Efectivo',
        operationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      );
      expect(firstSale.number, secondSale.number);
      expect(firstSale.id, isNot(secondSale.id));

      final transport = MemoryTransport();
      final configuration = SyncConfiguration(
        baseUri: Uri.parse('http://localhost'),
      );
      SyncEngine engine(CapcRepository repository) => SyncEngine(
        repository: repository,
        configuration: configuration,
        transport: transport,
      );
      await engine(first).runOnce();
      await engine(second).runOnce();
      await engine(first).runOnce();

      final firstSales = await first.listSales();
      final secondSales = await second.listSales();
      expect(firstSales, hasLength(2));
      expect(secondSales, hasLength(2));
      expect(firstSales.map((sale) => sale.id).toSet(), {
        firstSale.id,
        secondSale.id,
      });
      expect(secondSales.map((sale) => sale.id).toSet(), {
        firstSale.id,
        secondSale.id,
      });
      expect(firstSales.map((sale) => sale.number).toSet(), hasLength(2));
      expect(secondSales.map((sale) => sale.number).toSet(), hasLength(2));
    },
  );

  test(
    'configuración del negocio se conserva y llega al segundo equipo',
    () async {
      final sourcePath = p.join(directory.path, 'business-source.sqlite3');
      final targetPath = p.join(directory.path, 'business-target.sqlite3');
      final source = await openOwned(sourcePath);
      final target = await openOwned(targetPath);
      await target.adoptRemoteBusinessId(source.businessId);
      await source.saveBusinessProfile(
        BusinessProfile(
          id: source.businessId,
          name: 'Papelería Central',
          phone: '3001234567',
          address: 'Calle 1',
          email: 'negocio@example.test',
        ),
      );
      final transport = MemoryTransport();
      final configuration = SyncConfiguration(
        baseUri: Uri.parse('http://localhost'),
      );
      await SyncEngine(
        repository: source,
        configuration: configuration,
        transport: transport,
      ).runOnce();
      await SyncEngine(
        repository: target,
        configuration: configuration,
        transport: transport,
      ).runOnce();
      final remote = await target.getBusinessProfile();
      expect(remote.name, 'Papelería Central');
      expect(remote.phone, '3001234567');
      expect(remote.address, 'Calle 1');
      expect(remote.email, 'negocio@example.test');
      await target.close();
      await source.close();
    },
  );

  test('tombstones de maestros convergen sin borrar registros', () async {
    final source = await openOwned(
      p.join(directory.path, 'delete-source.sqlite3'),
    );
    final target = await openOwned(
      p.join(directory.path, 'delete-target.sqlite3'),
    );
    await target.adoptRemoteBusinessId(source.businessId);
    const productId = '55555555-5555-4555-8555-555555555555';
    const customerId = '66666666-6666-4666-8666-666666666666';
    const supplierId = '77777777-7777-4777-8777-777777777777';
    await source.saveProduct(material(id: productId));
    await source.saveCustomer(
      const Customer(id: customerId, name: 'Cliente eliminable'),
    );
    await source.saveSupplier(
      const Supplier(id: supplierId, name: 'Proveedor eliminable'),
    );
    final transport = MemoryTransport();
    final configuration = SyncConfiguration(
      baseUri: Uri.parse('http://localhost'),
    );
    SyncEngine engine(CapcRepository repository) => SyncEngine(
      repository: repository,
      configuration: configuration,
      transport: transport,
    );
    await engine(source).runOnce();
    await engine(target).runOnce();
    await source.deleteProduct(productId);
    await source.deleteCustomer(customerId);
    await source.deleteSupplier(supplierId);
    await engine(source).runOnce();
    await engine(target).runOnce();
    expect(await target.listProducts(), isEmpty);
    expect(await target.listCustomers(), isEmpty);
    expect(await target.listSuppliers(), isEmpty);
    await target.close();
    await source.close();
  });
}
