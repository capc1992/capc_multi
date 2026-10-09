import 'dart:convert';
import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Frozen v1 fixture intentionally contains only the old schema. Building it
/// with current repository code would fail to exercise real migrations.
void createV1Fixture(String path, {bool brokenReference = false}) {
  final db = sqlite3.open(path);
  try {
    for (final statement in [
      '''CREATE TABLE products(id TEXT PRIMARY KEY,code TEXT UNIQUE COLLATE NOCASE,name TEXT,unit TEXT,is_service INTEGER,purchase_price INTEGER,sale_price INTEGER,stock INTEGER,minimum_stock INTEGER,updated_at TEXT)''',
      '''CREATE TABLE customers(id TEXT PRIMARY KEY,name TEXT,phone TEXT,updated_at TEXT)''',
      '''CREATE TABLE sales(id TEXT PRIMARY KEY,number TEXT UNIQUE,sequence INTEGER UNIQUE,created_at TEXT,customer_id TEXT REFERENCES customers(id),customer_name TEXT,operator_name TEXT,total INTEGER,paid INTEGER,payment_method TEXT)''',
      '''CREATE TABLE sale_lines(id TEXT PRIMARY KEY,sale_id TEXT REFERENCES sales(id),position INTEGER,product_id TEXT REFERENCES products(id),code TEXT,name TEXT,unit TEXT,is_service INTEGER,quantity INTEGER,unit_price INTEGER,unit_cost INTEGER)''',
      '''CREATE TABLE payments(id TEXT PRIMARY KEY,sale_id TEXT REFERENCES sales(id),amount INTEGER,created_at TEXT,method TEXT)''',
      '''CREATE TABLE stock_movements(id TEXT PRIMARY KEY,product_id TEXT REFERENCES products(id),delta INTEGER,reason TEXT,created_at TEXT,sale_id TEXT REFERENCES sales(id))''',
      '''CREATE TABLE operations(id TEXT PRIMARY KEY,kind TEXT,request TEXT,entity_id TEXT,created_at TEXT)''',
      '''CREATE TABLE outbox(id TEXT PRIMARY KEY,operation_id TEXT UNIQUE,kind TEXT,schema_version INTEGER,payload TEXT,created_at TEXT,state TEXT)''',
      'CREATE TABLE counters(name TEXT PRIMARY KEY,value INTEGER)',
      'CREATE INDEX sales_created_at ON sales(created_at)',
      'CREATE INDEX payments_sale ON payments(sale_id)',
      'PRAGMA user_version = 1',
    ]) {
      db.execute(statement);
    }
    const created = '2026-01-02T14:05:06.000Z';
    db.execute('INSERT INTO products VALUES(?,?,?,?,?,?,?,?,?,?)', [
      'old-material',
      'OLD-01',
      'Papel histórico',
      'Hoja',
      0,
      50,
      200,
      8,
      2,
      created,
    ]);
    db.execute('INSERT INTO customers VALUES(?,?,?,?)', [
      'old-customer',
      'Ana histórica',
      '3001234567',
      created,
    ]);
    db.execute('INSERT INTO sales VALUES(?,?,?,?,?,?,?,?,?,?)', [
      'old-sale',
      'V-000007',
      7,
      created,
      'old-customer',
      'Ana histórica',
      'Operador v1',
      400,
      150,
      'Efectivo',
    ]);
    db.execute('INSERT INTO sale_lines VALUES(?,?,?,?,?,?,?,?,?,?,?)', [
      'old-line',
      'old-sale',
      0,
      brokenReference ? 'missing-product' : 'old-material',
      'OLD-01',
      'Papel histórico',
      'Hoja',
      0,
      2,
      200,
      50,
    ]);
    db.execute('INSERT INTO payments VALUES(?,?,?,?,?)', [
      'old-initial',
      'old-sale',
      100,
      created,
      'Efectivo',
    ]);
    db.execute('INSERT INTO payments VALUES(?,?,?,?,?)', [
      'old-abono',
      'old-sale',
      50,
      '2026-01-03T16:00:00.000Z',
      'Transferencia',
    ]);
    db.execute('INSERT INTO stock_movements VALUES(?,?,?,?,?,?)', [
      'old-stock',
      'old-material',
      10,
      'Stock inicial',
      created,
      null,
    ]);
    db.execute('INSERT INTO stock_movements VALUES(?,?,?,?,?,?)', [
      'old-output',
      'old-material',
      -2,
      'Venta V-000007',
      created,
      'old-sale',
    ]);
    db.execute('INSERT INTO operations VALUES(?,?,?,?,?)', [
      'old-sale-op',
      'sale.create',
      jsonEncode({
        'items': [
          {'productId': 'old-material', 'quantity': 2},
        ],
        'customerId': 'old-customer',
        'paid': 100,
        'paymentMethod': 'Efectivo',
        'operatorName': 'Operador v1',
      }),
      'old-sale',
      created,
    ]);
    db.execute('INSERT INTO operations VALUES(?,?,?,?,?)', [
      'old-abono-op',
      'payment.add',
      jsonEncode({
        'saleId': 'old-sale',
        'amount': 50,
        'method': 'Transferencia',
      }),
      'old-abono',
      '2026-01-03T16:00:00.000Z',
    ]);
    db.execute('INSERT INTO outbox VALUES(?,?,?,?,?,?,?)', [
      'old-event',
      'old-sale-op',
      'sale.created',
      1,
      jsonEncode({'saleId': 'old-sale'}),
      created,
      'pending',
    ]);
    db.execute('INSERT INTO counters VALUES(?,?)', ['sale', 7]);
  } finally {
    db.close();
  }
}

void main() {
  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_v1_migration_');
    path = p.join(directory.path, 'legacy.sqlite');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'v1 migrates identifiers, stock, historical documents, payments and retry IDs without default users',
    () async {
      createV1Fixture(path);
      final repository = await CapcRepository.open(path);
      try {
        expect(await repository.needsSetup(), isTrue);
        expect(repository.currentUser, isNull);
        await expectLater(
          repository.listProducts(),
          throwsA(isA<CapcException>()),
        );
        await repository.setupOwner(
          name: 'Propietaria',
          username: 'owner',
          password: 'Clave-elegida-2026',
        );
        final product = (await repository.listProducts()).single;
        expect(product.id, 'old-material');
        expect(product.stock, 8);
        expect(product.inventoryValueMicros, 400000000);
        expect(product.costBasis, 'legacy');
        final sale = (await repository.listSales()).single;
        expect(sale.id, 'old-sale');
        expect(sale.number, 'V-000007');
        expect(sale.createdAt, DateTime.utc(2026, 1, 2, 14, 5, 6));
        expect(sale.operatorName, 'Operador v1');
        expect(sale.total, 400);
        expect(sale.paid, 150);
        expect(sale.balance, 250);
        expect(sale.lines.single.id, 'old-line');
        expect(sale.lines.single.costBasis, 'legacy');
        expect(sale.lines.single.costTotalMicros, 100000000);
        expect((await repository.listPayments()).map((p) => p.id).toSet(), {
          'old-initial',
          'old-abono',
        });
        expect(
          (await repository.listStockMovements()).map((m) => m.id).toSet(),
          {'old-stock', 'old-output'},
        );
        final retry = await repository.createSale(
          items: const [CartLine(productId: 'old-material', quantity: 2)],
          customerId: 'old-customer',
          paid: 100,
          paymentMethod: 'Efectivo',
          operationId: 'old-sale-op',
        );
        expect(retry.id, sale.id);
        await repository.addPayment(
          sale.id,
          50,
          'Transferencia',
          operationId: 'old-abono-op',
        );
        expect((await repository.listSales()).single.paid, 150);
        expect(await repository.listPayments(), hasLength(2));
        await repository.openCash(0, operationId: 'opening');
        final next = await repository.createSale(
          items: const [CartLine(productId: 'old-material', quantity: 1)],
          paid: 200,
          paymentMethod: 'Efectivo',
          operationId: 'new-sale',
        );
        expect(next.number, 'V-000008');
        expect((await repository.listProducts()).single.stock, 7);
        final raw = sqlite3.open(path);
        try {
          expect(raw.select('PRAGMA user_version').single.values.single, 3);
          expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
          for (final table in ['inbox', 'sync_state', 'sync_conflicts']) {
            expect(
              raw.select(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                [table],
              ),
              hasLength(1),
            );
          }
          expect(
            raw.select('SELECT id FROM outbox WHERE id = ?', ['old-event']),
            hasLength(1),
          );
          expect(
            raw.select(
              "SELECT name FROM sqlite_master WHERE name LIKE 'legacy_%'",
            ),
            isEmpty,
          );
        } finally {
          raw.close();
        }
      } finally {
        await repository.close();
      }
      final reopened = await CapcRepository.open(path);
      try {
        expect(await reopened.needsSetup(), isFalse);
        await reopened.login('owner', 'Clave-elegida-2026');
        expect(await reopened.listSales(), hasLength(2));
        expect((await reopened.listProducts()).single.stock, 7);
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'broken v1 references abort migration and leave original schema and data',
    () async {
      createV1Fixture(path, brokenReference: true);
      await expectLater(CapcRepository.open(path), throwsA(anything));
      final raw = sqlite3.open(path);
      try {
        expect(raw.select('PRAGMA user_version').single.values.single, 1);
        expect(
          raw.select('SELECT id FROM products').single['id'],
          'old-material',
        );
        expect(
          raw.select('SELECT product_id FROM sale_lines').single['product_id'],
          'missing-product',
        );
        expect(
          raw.select(
            "SELECT name FROM sqlite_master WHERE name LIKE 'legacy_%'",
          ),
          isEmpty,
        );
        expect(
          raw.select("SELECT name FROM sqlite_master WHERE name = 'users'"),
          isEmpty,
        );
      } finally {
        raw.close();
      }
    },
  );
}
