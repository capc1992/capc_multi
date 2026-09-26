import 'dart:convert';
import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late CapcRepository repository;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_backup_');
    path = p.join(directory.path, 'data.sqlite');
    repository = await CapcRepository.open(path);
    await repository.setupOwner(
      name: 'Dueña',
      username: 'owner',
      password: 'una-clave-segura',
    );
    await repository.openCash(0);
    await repository.saveProduct(
      const Product(
        id: 'paper',
        code: 'PAP',
        name: 'Papel',
        unit: 'Unidad',
        isService: false,
        purchasePrice: 50,
        salePrice: 100,
        stock: 10,
        minimumStock: 1,
      ),
    );
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });
  Future<Sale> sell() => repository.createSale(
    items: const [CartLine(productId: 'paper', quantity: 1)],
    paid: 100,
    paymentMethod: 'Efectivo',
  );

  test(
    'restore validates, preserves a prior snapshot and requires login again',
    () async {
      final backup = p.join(directory.path, 'backup.sqlite');
      await repository.backupTo(backup);
      final sale = await sell();
      final prior = await repository.restoreFrom(backup);
      expect(File(prior).existsSync(), isTrue);
      expect(repository.isAuthenticated, isFalse);
      await repository.login('owner', 'una-clave-segura');
      expect(await repository.listSales(), isEmpty);
      expect((await repository.listProducts()).single.stock, 10);
      final previous = await CapcRepository.open(prior);
      try {
        await previous.login('owner', 'una-clave-segura');
        expect((await previous.listSales()).single.id, sale.id);
        expect((await previous.listProducts()).single.stock, 9);
      } finally {
        await previous.close();
      }
    },
  );

  test('corrupt or foreign backups never replace active data', () async {
    await sell();
    final corrupt = p.join(directory.path, 'corrupt.sqlite');
    await File(corrupt).writeAsString('not a database');
    await expectLater(
      repository.restoreFrom(corrupt),
      throwsA(isA<CapcException>()),
    );
    expect((await repository.listSales()).length, 1);
    final foreign = p.join(directory.path, 'foreign.sqlite');
    final db = sqlite3.open(foreign);
    db.execute('CREATE TABLE unrelated(id INTEGER)');
    db.close();
    await expectLater(
      repository.restoreFrom(foreign),
      throwsA(isA<CapcException>()),
    );
    expect((await repository.listProducts()).single.stock, 9);
  });

  test(
    'failure after replacement recovers previous database and leaves valid backup',
    () async {
      final backup = p.join(directory.path, 'backup.sqlite');
      await repository.backupTo(backup);
      final sale = await sell();
      await expectLater(
        repository.restoreFrom(
          backup,
          onProgress: (stage) async {
            if (stage == 'replaced') {
              throw StateError('interruption after replacement');
            }
          },
        ),
        throwsA(isA<CapcException>()),
      );
      await repository.login('owner', 'una-clave-segura');
      expect((await repository.listSales()).single.id, sale.id);
      expect((await repository.listProducts()).single.stock, 9);
      final prior = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.antes-restaurar-'))
          .single;
      await CapcRepository.validateBackup(prior.path);
    },
  );

  test('backup validation failure cleans only its new output', () async {
    final db = sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER foreign_trigger AFTER INSERT ON customers BEGIN SELECT 1; END",
    );
    db.close();
    final destination = p.join(directory.path, 'rejected.sqlite');
    await expectLater(
      repository.backupTo(destination),
      throwsA(isA<CapcException>()),
    );
    expect(File(destination).existsSync(), isFalse);
    expect((await repository.listProducts()).single.stock, 10);
  });

  test(
    'failed startup releases the database so a valid backup can be recovered',
    () async {
      final backup = p.join(directory.path, 'backup.sqlite');
      await repository.backupTo(backup);
      await repository.close();
      final damaged = sqlite3.open(path);
      try {
        damaged.execute("DELETE FROM settings WHERE key = 'business_id'");
      } finally {
        damaged.close();
      }

      await expectLater(CapcRepository.open(path), throwsA(isA<StateError>()));

      // Changing out of WAL mode requires the failed startup's connection to
      // have closed, including on systems that allow renaming open files.
      final probe = sqlite3.open(path);
      try {
        expect(
          probe.select('PRAGMA journal_mode = DELETE').single.values.single,
          'delete',
        );
      } finally {
        probe.close();
      }

      final previous = await CapcRepository.recoverDatabase(
        databasePath: path,
        backupPath: backup,
        username: 'owner',
        password: 'una-clave-segura',
      );
      expect(File(p.join(previous, p.basename(path))).existsSync(), isTrue);
      repository = await CapcRepository.open(path);
      await repository.login('owner', 'una-clave-segura');
      expect((await repository.listProducts()).single.stock, 10);
    },
  );

  test(
    'startup recovery authenticates backup owner and preserves corrupt original',
    () async {
      final backup = p.join(directory.path, 'backup.sqlite');
      await repository.backupTo(backup);
      await repository.close();
      final corrupted = List<int>.generate(200, (i) => i % 255);
      await File(path).writeAsBytes(corrupted, flush: true);
      await expectLater(
        CapcRepository.recoverDatabase(
          databasePath: path,
          backupPath: backup,
          username: 'owner',
          password: 'incorrecta',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(await File(path).readAsBytes(), corrupted);
      final previous = await CapcRepository.recoverDatabase(
        databasePath: path,
        backupPath: backup,
        username: 'owner',
        password: 'una-clave-segura',
      );
      expect(
        await File(p.join(previous, p.basename(path))).readAsBytes(),
        corrupted,
      );
      repository = await CapcRepository.open(path);
      await repository.login('owner', 'una-clave-segura');
      expect((await repository.listProducts()).single.stock, 10);
      expect(
        (await repository.listAudit()).any(
          (entry) => entry.action == 'backup.startup_recovered',
        ),
        isTrue,
      );
    },
  );

  for (final replaced in [false, true]) {
    test(
      'reopen recovers abrupt restoration ${replaced ? 'after' : 'before'} replacement',
      () async {
        final originalBackup = p.join(directory.path, 'initial.sqlite');
        await repository.backupTo(originalBackup);
        final sale = await sell();
        final previous = '$path.antes-restaurar-test.sqlite';
        final staged = '$path.restaurando-test.sqlite';
        final displaced = '$path.reemplazado-test';
        await repository.backupTo(previous);
        await File(originalBackup).copy(staged);
        await repository.close();
        await File(path).rename(displaced);
        if (replaced) await File(staged).rename(path);
        await File('$path.restore-journal.json').writeAsString(
          jsonEncode({
            'version': 1,
            'database': path,
            'original': displaced,
            'previous': previous,
            'staged': staged,
            'kind': 'restore',
            'originalPresent': true,
            'phase': 'prepared',
          }),
          flush: true,
        );
        repository = await CapcRepository.open(path);
        await repository.login('owner', 'una-clave-segura');
        expect((await repository.listSales()).single.id, sale.id);
        expect((await repository.listProducts()).single.stock, 9);
        expect(File('$path.restore-journal.json').existsSync(), isFalse);
        expect(
          (await repository.listAudit()).any(
            (e) => e.action == 'backup.interruption_recovered',
          ),
          isTrue,
        );
        if (replaced) {
          expect(
            directory
                .listSync()
                .whereType<File>()
                .where((f) => f.path.contains('.restauracion-interrumpida-'))
                .length,
            1,
          );
        }
      },
    );
  }
}
