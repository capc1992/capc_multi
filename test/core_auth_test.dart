import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late String path;
  late CapcRepository repository;
  const ownerPassword = 'Clave-propietaria-2026';
  const userPassword = 'Clave-personal-local-2026';
  const product = Product(
    id: 'paper',
    code: 'PAPER',
    name: 'Papel',
    unit: 'Hoja',
    isService: false,
    purchasePrice: 50,
    salePrice: 200,
    stock: 10,
    minimumStock: 1,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_auth_');
    path = p.join(directory.path, 'auth.sqlite');
    repository = await CapcRepository.open(path);
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<LocalUser> owner() => repository.setupOwner(
    name: 'Propietaria',
    username: 'owner',
    password: ownerPassword,
  );

  Future<Sale> sell({
    int quantity = 1,
    String method = 'Efectivo',
    int? received,
    String? operationId,
  }) => repository.createSale(
    items: [CartLine(productId: 'paper', quantity: quantity)],
    paid: quantity * 200,
    paymentMethod: method,
    received: received,
    operationId: operationId,
    operatorName: 'Nombre no autenticado que debe ignorarse',
  );

  test(
    'first setup requires a chosen password and no default credentials or unauthenticated access exist',
    () async {
      expect(await repository.needsSetup(), isTrue);
      expect(repository.currentUser, isNull);
      await expectLater(
        repository.login('admin', 'admin'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.saveProduct(product),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.listProducts(),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.setupOwner(
          name: 'Propietaria',
          username: 'owner',
          password: '123',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.needsSetup(), isTrue);
      final configured = await owner();
      expect(configured.role, UserRole.owner);
      expect(await repository.needsSetup(), isFalse);
      await expectLater(owner(), throwsA(isA<CapcException>()));
      repository.logout();
      await expectLater(
        repository.login('owner', 'incorrecta'),
        throwsA(isA<CapcException>()),
      );
      expect(repository.currentUser, isNull);
      expect(
        (await repository.login('OWNER', ownerPassword)).id,
        configured.id,
      );
      await expectLater(
        repository.saveUser(
          id: configured.id,
          name: configured.name,
          username: configured.username,
          role: UserRole.cashier,
        ),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.saveUser(
          id: configured.id,
          name: configured.name,
          username: configured.username,
          role: UserRole.owner,
          active: false,
        ),
        throwsA(isA<CapcException>()),
      );
    },
  );

  test(
    'passwords use separate random salts and password verification never needs a network',
    () async {
      await owner();
      await repository.saveUser(
        id: 'one',
        name: 'Uno',
        username: 'uno',
        role: UserRole.cashier,
        password: userPassword,
      );
      await repository.saveUser(
        id: 'two',
        name: 'Dos',
        username: 'dos',
        role: UserRole.cashier,
        password: userPassword,
      );
      final raw = sqlite3.open(path);
      try {
        final users = raw.select(
          "SELECT password_hash,password_salt,password_algorithm FROM users WHERE id IN ('one','two') ORDER BY id",
        );
        expect(users, hasLength(2));
        expect(users[0]['password_hash'], isNot(userPassword));
        expect(users[0]['password_hash'], isNot(users[1]['password_hash']));
        expect(users[0]['password_salt'], isNot(users[1]['password_salt']));
        expect(users[0]['password_algorithm'], startsWith('argon2id'));
      } finally {
        raw.close();
      }
      repository.logout();
      expect((await repository.login('uno', userPassword)).id, 'one');
      repository.logout();
      expect((await repository.login('dos', userPassword)).id, 'two');
    },
  );

  test(
    'cashier can sell but cannot override prices, adjust stock, expense, cancel or administer users',
    () async {
      await owner();
      await repository.saveProduct(product);
      await repository.openCash(1000, operationId: 'opening');
      await repository.saveUser(
        id: 'cashier',
        name: 'Cajera',
        username: 'cashier',
        role: UserRole.cashier,
        password: userPassword,
      );
      await repository.login('cashier', userPassword);
      await repository.saveCustomer(
        const Customer(id: 'customer', name: 'Cliente registrado'),
      );
      final sale = await sell(operationId: 'cashier-sale');
      expect(sale.operatorName, 'Cajera');
      await expectLater(
        repository.saveProduct(product),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.adjustStock('paper', 1, 'No permitido'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.createSale(
          items: const [
            CartLine(productId: 'paper', quantity: 1, unitPrice: 1),
          ],
          paid: 1,
          paymentMethod: 'Efectivo',
        ),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.addExpense(10, 'No permitido'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.createSale(
          items: const [CartLine(productId: 'paper', quantity: 1)],
          customItems: const [
            CustomSaleItem(
              description: 'Servicio con precio manual',
              quantity: 1,
              unitPrice: 1,
            ),
          ],
          paid: 201,
          paymentMethod: 'Efectivo',
          operationId: 'custom-cashier-sale',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await repository.listSales(), hasLength(1));
      expect(await repository.listPayments(), hasLength(1));
      await expectLater(
        repository.cancelSale(sale.id, reason: 'No permitido'),
        throwsA(isA<CapcException>()),
      );
      await expectLater(repository.listUsers(), throwsA(isA<CapcException>()));
      await expectLater(
        repository.saveUser(
          name: 'No',
          username: 'no',
          role: UserRole.owner,
          password: userPassword,
        ),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.closeCash(1200),
        throwsA(isA<CapcException>()),
        reason:
            'Only the cashier who opened a session or an administrator may close it.',
      );
      await repository.login('owner', ownerPassword);
      final audit = await repository.listAudit();
      expect(
        audit.any(
          (entry) =>
              entry.action == 'sale.created' && entry.actorName == 'Cajera',
        ),
        isTrue,
      );
      expect((await repository.listProducts()).single.stock, 9);
    },
  );

  test(
    'administrator manages operations but owner retains user and restore permissions',
    () async {
      await owner();
      await repository.saveUser(
        id: 'admin',
        name: 'Administrador',
        username: 'admin',
        role: UserRole.admin,
        password: userPassword,
      );
      await repository.login('admin', userPassword);
      await repository.saveProduct(product);
      await repository.openCash(1000, operationId: 'opening');
      await repository.addExpense(100, 'Papelería', operationId: 'expense');
      await repository.saveSupplier(
        const Supplier(id: 'supplier', name: 'Distribuidor'),
      );
      await repository.adjustStock('paper', -1, 'Merma', operationId: 'adjust');
      expect((await repository.currentCashSession())!.expectedAmount, 900);
      await expectLater(repository.listUsers(), throwsA(isA<CapcException>()));
      await expectLater(
        repository.restoreFrom(p.join(directory.path, 'absent.sqlite')),
        throwsA(isA<CapcException>()),
      );
      expect((await repository.listProducts()).single.stock, 9);
    },
  );

  test(
    'password reset and deactivation revoke sessions on a second connection',
    () async {
      await owner();
      await repository.saveUser(
        id: 'employee',
        name: 'Empleado',
        username: 'employee',
        role: UserRole.cashier,
        password: userPassword,
      );
      final employee = await CapcRepository.open(path);
      try {
        await employee.login('employee', userPassword);
        await repository.saveUser(
          id: 'employee',
          name: 'Empleado',
          username: 'employee',
          role: UserRole.cashier,
          password: 'Una-nueva-clave-2026',
        );
        await expectLater(
          employee.saveCustomer(
            const Customer(id: 'blocked', name: 'No autorizado'),
          ),
          throwsA(isA<CapcException>()),
        );
        expect(employee.currentUser, isNull);
        await expectLater(
          employee.login('employee', userPassword),
          throwsA(isA<CapcException>()),
        );
        await employee.login('employee', 'Una-nueva-clave-2026');
        await employee.saveCustomer(
          const Customer(id: 'allowed', name: 'Cliente válido'),
        );
        await repository.saveUser(
          id: 'employee',
          name: 'Empleado',
          username: 'employee',
          role: UserRole.cashier,
          active: false,
        );
        await expectLater(
          employee.listCustomers(),
          throwsA(isA<CapcException>()),
        );
        await expectLater(
          employee.login('employee', 'Una-nueva-clave-2026'),
          throwsA(isA<CapcException>()),
        );
        expect((await repository.listCustomers()).single.id, 'allowed');
      } finally {
        await employee.close();
      }
    },
  );

  test(
    'cash expected excludes transfers and change, closures and reopening survive restart',
    () async {
      await owner();
      await repository.saveProduct(product);
      final opened = await repository.openCash(1000, operationId: 'opening');
      expect(
        (await repository.openCash(1000, operationId: 'opening')).id,
        opened.id,
      );
      await expectLater(
        repository.openCash(1000, operationId: 'other-opening'),
        throwsA(isA<CapcException>()),
      );
      final cashSale = await sell(received: 500, operationId: 'cash-sale');
      expect(cashSale.change, 300);
      await sell(
        quantity: 2,
        method: 'Transferencia',
        operationId: 'bank-sale',
      );
      await repository.addExpense(
        50,
        'Gasto operativo',
        operationId: 'expense',
      );
      await repository.addCashAdjustment(
        -20,
        'Retiro del propietario',
        operationId: 'withdrawal',
      );
      expect((await repository.currentCashSession())!.expectedAmount, 1130);
      final closed = await repository.closeCash(
        1100,
        note: 'Faltante contado',
        operationId: 'close',
      );
      expect(closed.expectedAmount, 1130);
      expect(closed.countedAmount, 1100);
      expect(closed.difference, -30);
      expect(
        (await repository.closeCash(
          1100,
          note: 'Faltante contado',
          operationId: 'close',
        )).id,
        closed.id,
      );
      await expectLater(
        sell(operationId: 'closed-sale'),
        throwsA(isA<CapcException>()),
      );
      await repository.close();
      repository = await CapcRepository.open(path);
      await repository.login('owner', ownerPassword);
      expect(await repository.currentCashSession(), isNull);
      final saved = (await repository.listCashSessions()).single;
      expect(saved.difference, -30);
      final next = await repository.openCash(1100, operationId: 'reopen');
      expect(next.id, isNot(closed.id));
      expect(next.expectedAmount, 1100);
      expect(await repository.listCashSessions(), hasLength(2));
    },
  );
}
