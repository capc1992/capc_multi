import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/services/factory_reset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('respalda, elimina archivos locales y vuelve al alta inicial', () async {
    final directory = await Directory.systemTemp.createTemp('capc_reset_');
    final databasePath = p.join(directory.path, 'capc.sqlite3');
    var repository = await CapcRepository.open(databasePath);
    try {
      await repository.setupOwner(
        name: 'Propietaria',
        username: 'owner',
        password: 'Una-clave-larga-2026',
      );
      await repository.saveProduct(
        const Product(
          id: 'paper',
          code: 'PAP-001',
          name: 'Papel',
          unit: 'Unidad',
          isService: false,
          purchasePrice: 100,
          salePrice: 200,
          stock: 3,
          minimumStock: 1,
        ),
      );

      final backup = await FactoryResetService.createBackup(repository);
      expect(File(backup).existsSync(), isTrue);
      await FactoryResetService.markForReset(
        databasePath: databasePath,
        backupPath: backup,
      );
      await repository.close();
      await FactoryResetService.completePendingReset(databasePath);

      expect(File(databasePath).existsSync(), isFalse);
      expect(File('$databasePath-wal').existsSync(), isFalse);
      expect(File('$databasePath-shm').existsSync(), isFalse);
      expect(File('$databasePath.factory-reset.json').existsSync(), isFalse);

      final saved = await CapcRepository.open(backup);
      try {
        await saved.login('owner', 'Una-clave-larga-2026');
        expect((await saved.listProducts()).single.code, 'PAP-001');
      } finally {
        await saved.close();
      }

      repository = await CapcRepository.open(databasePath);
      expect(await repository.needsSetup(), isTrue);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('un diario inválido no elimina la base activa', () async {
    final directory = await Directory.systemTemp.createTemp('capc_reset_bad_');
    final databasePath = p.join(directory.path, 'capc.sqlite3');
    final repository = await CapcRepository.open(databasePath);
    try {
      await repository.setupOwner(
        name: 'Propietaria',
        username: 'owner',
        password: 'Una-clave-larga-2026',
      );
      await File(
        '$databasePath.factory-reset.json',
      ).writeAsString('{incompleto');
      await expectLater(
        FactoryResetService.completePendingReset(databasePath),
        throwsA(isA<CapcException>()),
      );
      expect(File(databasePath).existsSync(), isTrue);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });
}
