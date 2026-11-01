import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/sync/sync_engine.dart';
import 'package:capc_multiservicio/sync/sync_models.dart';
import 'package:capc_multiservicio/sync/sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as native;

import 'sync_foundation_test.dart' show MemoryTransport, openOwned;

const productId = '55555555-5555-4555-8555-555555555555';

Product initialProduct({int stock = 20, bool service = false}) => Product(
  id: productId,
  code: 'INITIAL-001',
  name: 'Producto con existencias iniciales',
  unit: 'Unidad',
  isService: service,
  purchasePrice: 50,
  salePrice: 200,
  stock: stock,
  minimumStock: service ? 0 : 1,
);

bool isInitial(SyncOperation operation) =>
    operation.type == 'stock.adjusted' &&
    (operation.content['movement'] as Map?)?['kind'] == 'Inicial';

void main() {
  late Directory directory;
  late CapcRepository source;
  late CapcRepository target;
  late MemoryTransport transport;
  final configuration = SyncConfiguration(
    baseUri: Uri.parse('http://localhost'),
  );

  SyncEngine engine(CapcRepository repository) => SyncEngine(
    repository: repository,
    configuration: configuration,
    transport: transport,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_initial_stock_');
    source = await openOwned(p.join(directory.path, 'source.sqlite3'));
    target = await openOwned(p.join(directory.path, 'target.sqlite3'));
    await target.adoptRemoteBusinessId(source.businessId);
    transport = MemoryTransport();
  });

  tearDown(() async {
    await source.close();
    await target.close();
    await directory.delete(recursive: true);
  });

  Future<void> simulateOldVersion() async {
    // Only synthetic test data: old releases never queued the initial entry.
    final path = source.databasePath;
    await source.close();
    final db = native.sqlite3.open(path);
    try {
      db.execute(
        "DELETE FROM outbox WHERE kind='stock.adjusted' AND json_extract(payload,'\$.movement.kind')='Inicial'",
      );
    } finally {
      db.close();
    }
    source = await openOwned(path);
  }

  test(
    'stock inicial y costo llegan al segundo equipo sin duplicar al reintentar',
    () async {
      await source.saveProduct(initialProduct());
      final outgoing = await source.prepareSyncPush();
      expect(outgoing.where(isInitial), hasLength(1));
      final movement = (await source.listStockMovements()).single;
      expect(outgoing.singleWhere(isInitial).operationId, movement.id);
      transport.loseNextResponse = true;
      await expectLater(
        engine(source).runOnce(),
        throwsA(isA<SyncTransportException>()),
      );
      await engine(source).runOnce();
      transport.reverseNextPull = true;
      await engine(target).runOnce();
      await engine(source).runOnce();
      await engine(target).runOnce();
      for (final repository in [source, target]) {
        final product = (await repository.listProducts()).single;
        expect(product.stock, 20);
        expect(product.inventoryValueMicros, 1000000000);
        expect(await repository.listStockMovements(), hasLength(1));
        expect(await repository.pendingSyncOperations(), 0);
      }
      expect(transport.operations.where(isInitial), hasLength(1));
    },
  );

  test(
    'actualización recupera entradas omitidas aunque el catálogo ya fue confirmado',
    () async {
      await source.saveProduct(initialProduct());
      final catalog = (await source.prepareSyncPush())
          .where((event) => !isInitial(event))
          .toList();
      await source.acknowledgeSyncPush(await transport.push(catalog));
      await engine(target).runOnce();
      expect((await target.listProducts()).single.stock, 0);
      await simulateOldVersion();
      await engine(source).runOnce();
      await engine(target).runOnce();
      expect((await target.listProducts()).single.stock, 20);
      await engine(source).runOnce();
      await engine(target).runOnce();
      expect((await target.listProducts()).single.stock, 20);
      expect(transport.operations.where(isInitial), hasLength(1));
      expect(await target.prepareSyncPush(), isEmpty);
    },
  );

  test(
    'entrada recuperada incluye las salidas recibidas antes del stock inicial',
    () async {
      await source.saveProduct(initialProduct());
      await source.adjustStock(productId, -3, 'Salida antes de actualizar');
      final legacy = (await source.prepareSyncPush())
          .where((event) => !isInitial(event))
          .toList();
      await source.acknowledgeSyncPush(await transport.push(legacy));
      await engine(target).runOnce();
      expect((await target.listProducts()).single.stock, 0);
      await simulateOldVersion();
      await engine(source).runOnce();
      await engine(target).runOnce();
      final product = (await target.listProducts()).single;
      expect(product.stock, 17);
      expect(product.inventoryValueMicros, 850000000);
      expect((await source.listProducts()).single.stock, 17);
      expect(await target.listStockMovements(), hasLength(2));

      // Simulate the old receiver: it added the recovered 20 but left the earlier
      // -3 conflict unprojected. Updating that receiver must repair an empty pull.
      final path = target.databasePath;
      await target.close();
      final db = native.sqlite3.open(path);
      try {
        db.execute(
          'UPDATE products SET stock=20,inventory_value_micros=1000000000 WHERE id=?',
          [productId],
        );
        db.execute(
          "UPDATE sync_conflicts SET resolved_at=NULL WHERE kind='inventory.negative'",
        );
        db.execute(
          "UPDATE inbox SET state='conflict' WHERE operation_id IN (SELECT operation_id FROM sync_conflicts)",
        );
      } finally {
        db.close();
      }
      target = await openOwned(path);
      await engine(target).runOnce();
      expect((await target.listProducts()).single.stock, 17);
      expect(
        (await target.listProducts()).single.inventoryValueMicros,
        850000000,
      );
      final repaired = native.sqlite3.open(
        path,
        mode: native.OpenMode.readOnly,
      );
      try {
        expect(
          repaired.select(
            'SELECT 1 FROM sync_conflicts WHERE resolved_at IS NULL',
          ),
          isEmpty,
        );
        expect(
          repaired.select("SELECT 1 FROM inbox WHERE state='conflict'"),
          isEmpty,
        );
      } finally {
        repaired.close();
      }
    },
  );

  test('importación también publica sus entradas iniciales', () async {
    await source.importProducts([
      Product(
        id: '',
        code: 'IMPORT-1',
        name: 'Importado',
        unit: 'Unidad',
        isService: false,
        purchasePrice: 50,
        salePrice: 200,
        stock: 8,
        minimumStock: 1,
      ),
    ]);
    await engine(source).runOnce();
    await engine(target).runOnce();
    expect((await target.listProducts()).single.stock, 8);
  });

  test(
    'catálogo de ejemplo sincroniza existencias y servicios sin stock',
    () async {
      await source.loadExampleCatalog();
      while (await source.pendingSyncOperations() > 0) {
        await engine(source).runOnce(batchSize: 1);
        await engine(target).runOnce(batchSize: 1);
      }
      final expected = {
        for (final product in await source.listProducts()) product.id: product,
      };
      final received = await target.listProducts();
      expect(received, hasLength(expected.length));
      for (final product in received) {
        expect(product.stock, expected[product.id]!.stock);
        expect(
          product.inventoryValueMicros,
          expected[product.id]!.inventoryValueMicros,
        );
        if (product.isService) expect(product.stockStatus, 'Disponible');
      }
      expect(transport.operations.where(isInitial), hasLength(3));
    },
  );

  test(
    'producto sin existencias y servicio no generan movimientos iniciales',
    () async {
      await source.saveProduct(initialProduct(stock: 0));
      expect((await source.prepareSyncPush()).where(isInitial), isEmpty);
      await target.saveProduct(initialProduct(stock: 0, service: true));
      expect((await target.prepareSyncPush()).where(isInitial), isEmpty);
    },
  );
}
