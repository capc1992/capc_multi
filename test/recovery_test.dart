import 'dart:convert';
import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  const password = 'Una-clave-larga-2026';
  const replacement = 'Otra-clave-larga-2026';
  late Directory directory;
  late String path;
  late CapcRepository repository;
  late LocalUser owner;
  final additionalConnections = <CapcRepository>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_recovery_test_');
    path = p.join(directory.path, 'capc.sqlite');
    repository = await CapcRepository.open(path);
    owner = await repository.setupOwner(
      name: 'Propietaria original',
      username: 'owner',
      password: password,
    );
  });

  tearDown(() async {
    for (final connection in additionalConnections) {
      await connection.close();
    }
    additionalConnections.clear();
    await repository.close();
    await directory.delete(recursive: true);
  });

  T inspect<T>(T Function(Database db) operation) {
    final db = sqlite3.open(path);
    try {
      return operation(db);
    } finally {
      db.close();
    }
  }

  Map<String, Object?> userRow([String? id]) => inspect(
    (db) => Map.of(
      db.select('SELECT * FROM users WHERE id = ?', [id ?? owner.id]).single,
    ),
  );

  List<Map<String, Object?>> settings() => inspect(
    (db) => db
        .select('SELECT * FROM settings ORDER BY key')
        .map((row) => Map<String, Object?>.of(row))
        .toList(),
  );

  String commercialSnapshot() => inspect((db) {
    final tables = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT IN ('users','settings','audit') ORDER BY name",
    );
    return jsonEncode({
      for (final table in tables)
        table['name']: db
            .select('SELECT * FROM "${table['name']}"')
            .map((row) => Map<String, Object?>.of(row))
            .toList(),
    });
  });

  void prepareOwner([String? id]) => inspect((db) {
    db.execute('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)', [
      'owner_reconfiguration_user_id',
      id ?? owner.id,
    ]);
  });

  Future<CapcRepository> anotherConnection({bool loggedIn = false}) async {
    final connection = await CapcRepository.open(path);
    additionalConnections.add(connection);
    if (loggedIn) await connection.login('owner', password);
    return connection;
  }

  Future<void> seedBusiness() async {
    await repository.openCash(1000, operationId: 'opening');
    await repository.saveProduct(
      const Product(
        id: 'paper',
        code: 'PAPEL',
        name: 'Papel',
        unit: 'Unidad',
        isService: false,
        purchasePrice: 50,
        salePrice: 200,
        stock: 10,
        minimumStock: 1,
      ),
    );
    await repository.saveCustomer(const Customer(id: 'ana', name: 'Ana'));
    await repository.createSale(
      items: [const CartLine(productId: 'paper', quantity: 2)],
      paid: 400,
      customerId: 'ana',
      paymentMethod: 'Efectivo',
    );
  }

  Future<String> failure(Future<void> operation) async {
    try {
      await operation;
      fail('Expected recovery to fail');
    } on CapcException catch (error) {
      return error.message;
    }
  }

  test(
    'code creation requires a live session and the current password',
    () async {
      expect(await repository.recoveryCodeConfigured(), isFalse);
      final before = settings();
      final auditCount = inspect(
        (db) => db.select('SELECT COUNT(*) AS n FROM audit').single['n'],
      );
      await expectLater(
        repository.generateRecoveryCode(currentPassword: 'wrong'),
        throwsA(isA<CapcException>()),
      );
      repository.logout();
      await expectLater(
        repository.generateRecoveryCode(currentPassword: password),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.recoveryCodeConfigured(),
        throwsA(isA<CapcException>()),
      );
      expect(settings(), before);
      expect(
        inspect(
          (db) => db.select('SELECT COUNT(*) AS n FROM audit').single['n'],
        ),
        auditCount,
      );
    },
  );

  test(
    'code survives restart, restores access once and preserves business history',
    () async {
      await seedBusiness();
      final code = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      expect(code, matches(RegExp(r'^[A-F0-9]{8}(-[A-F0-9]{8}){7}$')));
      expect(await repository.recoveryCodeConfigured(), isTrue);
      final stored =
          settings().singleWhere(
                (row) => row['key'] == 'password_recovery_hash:${owner.id}',
              )['value']
              as String;
      expect(base64Decode(stored), hasLength(32));
      expect(stored, isNot(code));
      expect(
        jsonEncode(settings()),
        isNot(contains(code.replaceAll('-', '').toLowerCase())),
      );
      final commercialBefore = commercialSnapshot();
      final other = await anotherConnection(loggedIn: true);
      for (var i = 0; i < 5; i++) {
        await expectLater(
          repository.login('owner', 'incorrect'),
          throwsA(isA<CapcException>()),
        );
      }
      expect(userRow()['locked_until'], isNotNull);
      await repository.close();
      repository = await CapcRepository.open(path);
      await repository.resetPasswordWithRecoveryCode(
        username: 'OWNER',
        recoveryCode: code.toLowerCase().replaceAll('-', ' '),
        newPassword: replacement,
      );
      expect(repository.isAuthenticated, isFalse);
      expect(userRow()['failed_login'], 0);
      expect(userRow()['locked_until'], isNull);
      expect(userRow()['session_version'], 1);
      expect(commercialSnapshot(), commercialBefore);
      await expectLater(other.listProducts(), throwsA(isA<CapcException>()));
      await expectLater(
        repository.login('owner', password),
        throwsA(isA<CapcException>()),
      );
      await repository.login('owner', replacement);
      expect(await repository.recoveryCodeConfigured(), isFalse);
      final saved = userRow();
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'owner',
          recoveryCode: code,
          newPassword: password,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), saved);
      final records = inspect(
        (db) => db
            .select("SELECT * FROM audit WHERE action LIKE 'user.%recover%'")
            .map((row) => Map<String, Object?>.of(row))
            .toList(),
      );
      expect(
        records.map((row) => row['action']),
        contains('user.password_recovered'),
      );
      expect(jsonEncode(records), isNot(contains(code)));
      expect(jsonEncode(records), isNot(contains(replacement)));
    },
  );

  test(
    'rotation replaces old code and codes are bound to their own account',
    () async {
      final first = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      final second = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      expect(first, isNot(second));
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.cashier,
        password: password,
      );
      repository.logout();
      final before = userRow();
      final invalid = await failure(
        repository.resetPasswordWithRecoveryCode(
          username: 'owner',
          recoveryCode: first,
          newPassword: replacement,
        ),
      );
      expect(
        await failure(
          repository.resetPasswordWithRecoveryCode(
            username: 'cashier',
            recoveryCode: second,
            newPassword: replacement,
          ),
        ),
        invalid,
      );
      expect(
        await failure(
          repository.resetPasswordWithRecoveryCode(
            username: 'missing',
            recoveryCode: second,
            newPassword: replacement,
          ),
        ),
        invalid,
      );
      expect(
        await failure(
          repository.resetPasswordWithRecoveryCode(
            username: 'owner',
            recoveryCode: 'not-a-code',
            newPassword: replacement,
          ),
        ),
        invalid,
      );
      expect(userRow(), before);
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'owner',
          recoveryCode: second,
          newPassword: 'short',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), before);
      await repository.resetPasswordWithRecoveryCode(
        username: 'owner',
        recoveryCode: second,
        newPassword: replacement,
      );
      await repository.login('owner', replacement);
    },
  );

  test(
    'recovery limit persists independently from normal login and expires',
    () async {
      final code = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      final wrongCode = List.filled(
        64,
        code.startsWith('0') ? '1' : '0',
      ).join();
      final before = userRow();
      for (var i = 0; i < 5; i++) {
        await expectLater(
          repository.resetPasswordWithRecoveryCode(
            username: 'owner',
            recoveryCode: wrongCode,
            newPassword: replacement,
          ),
          throwsA(isA<CapcException>()),
        );
      }
      expect(userRow(), before);
      await repository.close();
      repository = await CapcRepository.open(path);
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'owner',
          recoveryCode: code,
          newPassword: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      await repository.login('owner', password);
      inspect(
        (db) => db.execute('UPDATE settings SET value = ? WHERE key = ?', [
          jsonEncode({
            'failures': 5,
            'lockedUntil': DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 1))
                .toIso8601String(),
          }),
          'password_recovery_attempts:${owner.id}',
        ]),
      );
      await repository.resetPasswordWithRecoveryCode(
        username: 'owner',
        recoveryCode: code,
        newPassword: replacement,
      );
      expect(repository.isAuthenticated, isFalse);
      expect(
        settings().where(
          (row) => (row['key'] as String).startsWith('password_recovery_'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'concurrent recovery consumes a code exactly once across connections',
    () async {
      final code = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      final other = await anotherConnection();
      repository.logout();
      Future<bool> attempt(CapcRepository connection) async {
        try {
          await connection.resetPasswordWithRecoveryCode(
            username: 'owner',
            recoveryCode: code,
            newPassword: replacement,
          );
          return true;
        } on CapcException {
          return false;
        }
      }

      final results = await Future.wait([attempt(repository), attempt(other)]);
      expect(results.where((success) => success), hasLength(1));
      expect(userRow()['session_version'], 1);
      expect(repository.isAuthenticated, isFalse);
      expect(other.isAuthenticated, isFalse);
      await repository.login('owner', replacement);
    },
  );

  test(
    'audit failure rolls back password, token, lock and session changes',
    () async {
      final code = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      final before = userRow();
      final settingsBefore = settings();
      inspect(
        (db) =>
            db.execute('''CREATE TRIGGER reject_recovery BEFORE INSERT ON audit
      WHEN NEW.action = 'user.password_recovered' BEGIN
        SELECT RAISE(ABORT, 'simulated audit failure');
      END'''),
      );
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'owner',
          recoveryCode: code,
          newPassword: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), before);
      expect(settings(), settingsBefore);
      expect(repository.isAuthenticated, isTrue);
      inspect((db) => db.execute('DROP TRIGGER reject_recovery'));
      await repository.resetPasswordWithRecoveryCode(
        username: 'owner',
        recoveryCode: code,
        newPassword: replacement,
      );
    },
  );

  test(
    'managed password, role and active changes invalidate recovery secrets',
    () async {
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.cashier,
        password: password,
      );
      final cashier = await anotherConnection();
      await cashier.login('cashier', password);
      var code = await cashier.generateRecoveryCode(currentPassword: password);
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.cashier,
        password: replacement,
      );
      await expectLater(
        cashier.recoveryCodeConfigured(),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'cashier',
          recoveryCode: code,
          newPassword: password,
        ),
        throwsA(isA<CapcException>()),
      );
      await cashier.login('cashier', replacement);
      expect(await cashier.recoveryCodeConfigured(), isFalse);
      code = await cashier.generateRecoveryCode(currentPassword: replacement);
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.admin,
      );
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'cashier',
          recoveryCode: code,
          newPassword: password,
        ),
        throwsA(isA<CapcException>()),
      );
      await cashier.login('cashier', replacement);
      code = await cashier.generateRecoveryCode(currentPassword: replacement);
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.admin,
        active: false,
      );
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'cashier',
          recoveryCode: code,
          newPassword: password,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow('cashier')['active'], 0);
      expect(
        settings().where(
          (row) => row['key'] == 'password_recovery_hash:cashier',
        ),
        isEmpty,
      );
    },
  );

  test(
    'owner reconfiguration requires the exact authorized active local owner',
    () async {
      final before = userRow();
      expect(await repository.pendingOwnerReconfiguration(), isFalse);
      await expectLater(
        repository.completeOwnerReconfiguration(
          name: 'Nueva',
          username: 'new',
          password: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), before);
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.cashier,
        password: password,
      );
      for (final id in ['missing', 'cashier']) {
        prepareOwner(id);
        await expectLater(
          repository.completeOwnerReconfiguration(
            name: 'Nueva',
            username: 'new',
            password: replacement,
          ),
          throwsA(isA<CapcException>()),
        );
        expect(await repository.pendingOwnerReconfiguration(), isTrue);
        expect(userRow(), before);
      }
      inspect(
        (db) =>
            db.execute('UPDATE users SET active = 0 WHERE id = ?', [owner.id]),
      );
      prepareOwner();
      await expectLater(
        repository.completeOwnerReconfiguration(
          name: 'Nueva',
          username: 'new',
          password: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow()['username'], 'owner');
      inspect(
        (db) => db.execute(
          'UPDATE users SET active = 1, business_id = ? WHERE id = ?',
          ['another-business', owner.id],
        ),
      );
      await expectLater(
        repository.completeOwnerReconfiguration(
          name: 'Nueva',
          username: 'new',
          password: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
    },
  );

  test(
    'owner handoff preserves identities and history and blocks pending access',
    () async {
      await seedBusiness();
      final code = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      final other = await anotherConnection(loggedIn: true);
      final before = commercialSnapshot();
      final saleBefore = (await repository.listSales()).single;
      final businessId = repository.businessId;
      final deviceId = repository.deviceId;
      prepareOwner();
      expect(await repository.needsSetup(), isFalse);
      expect(await repository.pendingOwnerReconfiguration(), isTrue);
      await expectLater(
        repository.login('owner', password),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        other.saveCustomer(const Customer(id: 'blocked', name: 'Blocked')),
        throwsA(isA<CapcException>()),
      );
      await expectLater(other.listProducts(), throwsA(isA<CapcException>()));
      await expectLater(
        repository.generateRecoveryCode(currentPassword: password),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'owner',
          recoveryCode: code,
          newPassword: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      final configured = await repository.completeOwnerReconfiguration(
        name: 'Nueva propietaria',
        username: 'NEW-OWNER',
        password: replacement,
      );
      expect(configured.id, owner.id);
      expect(configured.username, 'new-owner');
      expect(configured.role, UserRole.owner);
      expect(repository.isAuthenticated, isTrue);
      expect(await repository.pendingOwnerReconfiguration(), isFalse);
      expect(await repository.recoveryCodeConfigured(), isFalse);
      expect(repository.businessId, businessId);
      expect(repository.deviceId, deviceId);
      expect(commercialSnapshot(), before);
      final saleAfter = (await repository.listSales()).single;
      expect(saleAfter.id, saleBefore.id);
      expect(saleAfter.operatorName, saleBefore.operatorName);
      expect((await repository.listUsers()).single.id, owner.id);
      await expectLater(other.listProducts(), throwsA(isA<CapcException>()));
      final after = userRow();
      await expectLater(
        repository.completeOwnerReconfiguration(
          name: 'Replay',
          username: 'replay',
          password: password,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), after);
      await repository.close();
      repository = await CapcRepository.open(path);
      expect(await repository.pendingOwnerReconfiguration(), isFalse);
      await expectLater(
        repository.login('owner', password),
        throwsA(isA<CapcException>()),
      );
      await repository.login('new-owner', replacement);
      expect((await repository.listProducts()).single.stock, 8);
    },
  );

  test(
    'owner handoff collision and audit failure retain marker and credentials',
    () async {
      final code = await repository.generateRecoveryCode(
        currentPassword: password,
      );
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.cashier,
        password: password,
      );
      prepareOwner();
      final before = userRow();
      final settingsBefore = settings();
      await expectLater(
        repository.completeOwnerReconfiguration(
          name: 'Nueva',
          username: 'cashier',
          password: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), before);
      expect(settings(), settingsBefore);
      inspect(
        (db) =>
            db.execute('''CREATE TRIGGER reject_handoff BEFORE INSERT ON audit
      WHEN NEW.action = 'user.owner_reconfigured' BEGIN
        SELECT RAISE(ABORT, 'simulated audit failure');
      END'''),
      );
      await expectLater(
        repository.completeOwnerReconfiguration(
          name: 'Nueva',
          username: 'new-owner',
          password: replacement,
        ),
        throwsA(isA<CapcException>()),
      );
      expect(userRow(), before);
      expect(settings(), settingsBefore);
      inspect((db) => db.execute('DROP TRIGGER reject_handoff'));
      await repository.completeOwnerReconfiguration(
        name: 'Nueva',
        username: 'new-owner',
        password: replacement,
      );
      await expectLater(
        repository.resetPasswordWithRecoveryCode(
          username: 'new-owner',
          recoveryCode: code,
          newPassword: password,
        ),
        throwsA(isA<CapcException>()),
      );
    },
  );

  test(
    'concurrent owner handoffs update the authorized identity once',
    () async {
      final other = await anotherConnection();
      prepareOwner();
      Future<bool> complete(CapcRepository connection, String username) async {
        try {
          await connection.completeOwnerReconfiguration(
            name: 'Nueva',
            username: username,
            password: replacement,
          );
          return true;
        } on CapcException {
          return false;
        }
      }

      final results = await Future.wait([
        complete(repository, 'first'),
        complete(other, 'second'),
      ]);
      expect(results.where((success) => success), hasLength(1));
      expect(userRow()['session_version'], 1);
      expect(userRow()['username'], results.first ? 'first' : 'second');
      expect(await repository.pendingOwnerReconfiguration(), isFalse);
    },
  );

  test(
    'logout interrupts login, code generation and owner setup without writing credentials',
    () async {
      final before = userRow();
      final settingsBefore = settings();
      final generation = repository.generateRecoveryCode(
        currentPassword: password,
      );
      repository.logout();
      await expectLater(generation, throwsA(isA<CapcException>()));
      expect(settings(), settingsBefore);
      final login = repository.login('owner', password);
      repository.logout();
      await expectLater(login, throwsA(isA<CapcException>()));
      expect(repository.isAuthenticated, isFalse);
      await repository.login('owner', password);
      prepareOwner();
      final handoff = repository.completeOwnerReconfiguration(
        name: 'Nueva',
        username: 'new-owner',
        password: replacement,
      );
      repository.logout();
      await expectLater(handoff, throwsA(isA<CapcException>()));
      expect(repository.isAuthenticated, isFalse);
      expect(userRow(), before);
      expect(await repository.pendingOwnerReconfiguration(), isTrue);
    },
  );
}
