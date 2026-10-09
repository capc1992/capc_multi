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
        expect(migrated.select('PRAGMA user_version').single.values.single, 3);
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
}
