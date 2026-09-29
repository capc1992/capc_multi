import 'dart:convert';
import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late CapcRepository repository;
  const password = 'Clave-importaciones-2026';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_catalog_import_');
    databasePath = p.join(directory.path, 'catalog.sqlite');
    repository = await CapcRepository.open(databasePath);
    await repository.setupOwner(
      name: 'Propietaria',
      username: 'owner',
      password: password,
    );
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Product product({
    String id = '',
    String code = 'PAP-001',
    String name = 'Papel carta',
    String unit = 'Hoja',
    bool service = false,
    int cost = 75,
    int price = 200,
    int stock = 10,
    int minimum = 2,
  }) => Product(
    id: id,
    code: code,
    name: name,
    unit: unit,
    category: 'Papelería',
    isService: service,
    purchasePrice: cost,
    salePrice: price,
    stock: stock,
    minimumStock: minimum,
  );

  Map<String, List<Map<String, Object?>>> snapshot() {
    final raw = sqlite3.open(databasePath);
    try {
      return {
        for (final table in ['products', 'stock_movements', 'audit', 'outbox'])
          table: raw
              .select('SELECT * FROM $table ORDER BY id')
              .map((row) => Map<String, Object?>.from(row))
              .toList(),
      };
    } finally {
      raw.close();
    }
  }

  Matcher rowError(int row, [String? message]) => throwsA(
    isA<CapcException>().having(
      (error) => error.message,
      'message',
      allOf([startsWith('Fila $row:'), if (message != null) contains(message)]),
    ),
  );

  test(
    'imports material and service with initial valuation and actor audit',
    () async {
      expect(
        await repository.importProducts([
          product(code: ' pap-001 ', name: ' Papel carta '),
          product(
            code: 'SERV-001',
            name: 'Digitación',
            service: true,
            stock: 0,
            minimum: 0,
            cost: 1000,
            price: 2000,
          ),
        ]),
        2,
      );
      final saved = await repository.listProducts();
      final material = saved.singleWhere((entry) => !entry.isService);
      final service = saved.singleWhere((entry) => entry.isService);
      expect(material.id, matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(material.code, 'PAP-001');
      expect(material.name, 'Papel carta');
      expect(material.category, 'Papelería');
      expect(material.stock, 10);
      expect(material.minimumStock, 2);
      expect(material.inventoryValueMicros, 750000000);
      expect(material.costBasis, 'weighted');
      expect(material.costKnown, isTrue);
      expect(service.stock, 0);
      expect(service.inventoryValueMicros, 0);
      expect(service.purchasePrice, 1000);
      final movement = (await repository.listStockMovements()).single;
      expect(movement.productId, material.id);
      expect(movement.delta, 10);
      expect(movement.costMicros, 750000000);
      expect(movement.reason, 'Stock inicial');
      expect(movement.actorName, 'Propietaria');
      final audit = (await repository.listAudit())
          .where((entry) => entry.action == 'product.saved')
          .toList();
      expect(audit, hasLength(2));
      expect(audit.every((entry) => entry.actorName == 'Propietaria'), isTrue);
      final importAudit = (await repository.listAudit()).singleWhere(
        (entry) => entry.action == 'catalog.imported',
      );
      expect(jsonDecode(importAudit.details), {'count': 2});
      final data = snapshot();
      final outbox = data['outbox']!;
      expect(outbox, hasLength(3));
      expect(
        outbox.where((row) => row['kind'] == 'product.saved'),
        hasLength(2),
      );
      expect(
        outbox.where((row) => row['kind'] == 'stock.adjusted'),
        hasLength(1),
      );
      for (final table in data.values) {
        expect(
          table.every((row) => row['business_id'] == repository.businessId),
          isTrue,
        );
        expect(
          table.every((row) => row['device_id'] == repository.deviceId),
          isTrue,
        );
      }
    },
  );

  test(
    'duplicate normalized codes roll back products, movements and events',
    () async {
      final before = snapshot();
      await expectLater(
        repository.importProducts([
          product(code: 'DUP'),
          product(code: ' dup ', stock: 30),
        ]),
        rowError(3, 'repetido'),
      );
      expect(snapshot(), before);
    },
  );

  test(
    'existing codes reject the whole batch without changing original stock',
    () async {
      await repository.saveProduct(product(id: 'original'));
      final before = snapshot();
      await expectLater(
        repository.importProducts([
          product(code: 'NEW'),
          product(code: 'pap-001', name: 'Sobrescrito', stock: 999),
        ]),
        rowError(3, 'ya existe'),
      );
      expect(snapshot(), before);
    },
  );

  test(
    'blank spreadsheet rows preserve source row errors and rollback',
    () async {
      final before = snapshot();
      await expectLater(
        repository.importProducts(
          [product(code: 'DUP'), product(code: 'dup')],
          sourceRows: [3, 7],
        ),
        rowError(7, 'repetido'),
      );
      expect(snapshot(), before);
      await expectLater(
        repository.importProducts(
          [product(), product(code: 'INVALID', name: '')],
          sourceRows: [3, 7],
        ),
        rowError(7),
      );
      expect(snapshot(), before);
    },
  );

  test(
    'source row metadata must match the batch and exclude the header',
    () async {
      final before = snapshot();
      for (final sourceRows in <List<int>>[
        [],
        [1],
        [2, 3],
      ]) {
        await expectLater(
          repository.importProducts([product()], sourceRows: sourceRows),
          throwsA(isA<CapcException>()),
        );
        expect(snapshot(), before);
      }
    },
  );

  test(
    'supplied existing or new identifiers cannot turn an import into an edit',
    () async {
      await repository.saveProduct(product(id: 'original'));
      final before = snapshot();
      for (final id in ['original', 'unused-id']) {
        await expectLater(
          repository.importProducts([
            product(code: 'NEW'),
            product(id: id, code: 'CHANGED', stock: 999),
          ]),
          rowError(3, 'sin identificador'),
        );
        expect(snapshot(), before);
      }
    },
  );

  test(
    'invalid later rows and inventory overflow leave no partial batch',
    () async {
      final before = snapshot();
      for (final invalid in [
        product(code: ''),
        product(code: 'INVALID', name: ' '),
        product(code: 'INVALID', unit: ''),
        product(code: 'INVALID', service: true, stock: 1, minimum: 0),
        product(code: 'INVALID', service: true, stock: 0, minimum: 1),
        product(code: 'INVALID', cost: -1),
        product(code: 'INVALID', price: 1000000000000),
        product(code: 'INVALID', stock: 1000000001),
        product(code: 'INVALID', minimum: -1),
        product(code: 'INVALID', cost: 999999999999, stock: 1000000000),
      ]) {
        await expectLater(
          repository.importProducts([product(), invalid]),
          rowError(3),
        );
        expect(snapshot(), before);
      }
    },
  );

  test('empty and oversized imports are rejected without writes', () async {
    final before = snapshot();
    for (final entries in <List<Product>>[
      [],
      List<Product>.filled(5001, product()),
    ]) {
      await expectLater(
        repository.importProducts(entries),
        throwsA(
          isA<CapcException>().having(
            (error) => error.message,
            'message',
            contains('5000'),
          ),
        ),
      );
      expect(snapshot(), before);
    }
  });

  test('cashiers and unauthenticated callers cannot import', () async {
    await repository.saveUser(
      id: 'cashier',
      name: 'Cajera',
      username: 'cashier',
      role: UserRole.cashier,
      password: password,
    );
    await repository.login('cashier', password);
    final before = snapshot();
    await expectLater(
      repository.importProducts([product()]),
      throwsA(isA<CapcException>()),
    );
    expect(snapshot(), before);
    repository.logout();
    await expectLater(
      repository.importProducts([product()]),
      throwsA(isA<CapcException>()),
    );
    expect(snapshot(), before);
  });

  test('revoked admin sessions are revalidated against the database', () async {
    await repository.saveUser(
      id: 'admin',
      name: 'Administradora',
      username: 'admin',
      role: UserRole.admin,
      password: password,
    );
    final admin = await CapcRepository.open(databasePath);
    try {
      await admin.login('admin', password);
      await repository.saveUser(
        id: 'admin',
        name: 'Administradora',
        username: 'admin',
        role: UserRole.admin,
        active: false,
      );
      final before = snapshot();
      await expectLater(
        admin.importProducts([product()]),
        throwsA(isA<CapcException>()),
      );
      expect(snapshot(), before);
      expect(admin.currentUser, isNull);
    } finally {
      await admin.close();
    }
  });

  test(
    'logout while import is queued invalidates the whole operation',
    () async {
      final before = snapshot();
      final pending = repository.importProducts([product()]);
      repository.logout();
      await expectLater(pending, throwsA(isA<CapcException>()));
      expect(snapshot(), before);
    },
  );

  test(
    'concurrent batches with a shared code commit only one complete batch',
    () async {
      Future<Object> attempt(List<Product> entries) async {
        try {
          return await repository.importProducts(entries);
        } on CapcException catch (error) {
          return error;
        }
      }

      final results = await Future.wait([
        attempt([product(code: 'FIRST'), product(code: 'COMMON')]),
        attempt([product(code: 'SECOND'), product(code: 'common')]),
      ]);
      expect(results.whereType<int>().single, 2);
      expect(
        results.whereType<CapcException>().single.message,
        startsWith('Fila 3:'),
      );
      final saved = await repository.listProducts();
      expect(saved, hasLength(2));
      expect(saved.where((entry) => entry.code == 'COMMON'), hasLength(1));
      expect(saved.where((entry) => entry.code != 'COMMON'), hasLength(1));
      expect(await repository.listStockMovements(), hasLength(2));
      final outbox = snapshot()['outbox']!;
      expect(outbox, hasLength(4));
      expect(
        outbox.where((row) => row['kind'] == 'product.saved'),
        hasLength(2),
      );
      expect(
        outbox.where((row) => row['kind'] == 'stock.adjusted'),
        hasLength(2),
      );
      expect(
        (await repository.listAudit()).where(
          (entry) => entry.action == 'catalog.imported',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a caller cannot mutate the queued import by editing its input list',
    () async {
      final entries = [product(code: 'ORIGINAL')];
      final pending = repository.importProducts(entries);
      entries
        ..clear()
        ..add(product(code: 'REPLACEMENT'));
      expect(await pending, 1);
      expect((await repository.listProducts()).single.code, 'ORIGINAL');
    },
  );
}
