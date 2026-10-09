import 'dart:io';
import 'dart:typed_data';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/platform/platform_android.dart';
import 'package:capc_multiservicio/platform/platform_services.dart';
import 'package:capc_multiservicio/services/backup_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

class _TestAndroidPlatform extends AndroidPlatformServices {
  _TestAndroidPlatform(this.testDirectory);

  final Directory testDirectory;
  Uint8List? exportedBytes;
  String? exportedName;

  @override
  Future<Directory> temporaryDirectory() async => testDirectory;

  @override
  Future<SavedDocument?> saveDocument({
    required Future<Uint8List> Function() buildBytes,
    required String suggestedName,
    required DocumentType type,
    Future<bool> Function(String path)? confirmReplace,
  }) async {
    exportedBytes = await buildBytes();
    exportedName = suggestedName;
    return const SavedDocument(displayLocation: 'content://test/respaldo');
  }

  @override
  Future<SelectedDocument?> openDocument(DocumentType type) async {
    final bytes = exportedBytes;
    if (bytes == null) return null;
    return SelectedDocument(
      name: exportedName ?? 'respaldo.sqlite',
      path: 'content://test/respaldo',
      readBytes: () async => bytes,
      length: () async => bytes.length,
    );
  }
}

void main() {
  late Directory directory;
  late String databasePath;
  late CapcRepository repository;
  late _TestAndroidPlatform platform;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_android_offline_');
    databasePath = p.join(directory.path, 'private', 'CAPC', 'local.sqlite');
    platform = _TestAndroidPlatform(directory);
    platformServicesOverride = platform;
    repository = await CapcRepository.open(databasePath);
    await repository.setupOwner(
      name: 'Propietaria Android',
      username: 'owner',
      password: 'Clave-Android-2026',
    );
    await repository.openCash(500, operationId: 'android-open-cash');
  });

  tearDown(() async {
    await repository.close();
    platformServicesOverride = null;
    await directory.delete(recursive: true);
  });

  Product product({int stock = 3}) => Product(
    id: 'paper',
    code: '000123',
    name: 'Papel carta',
    unit: 'Hoja',
    isService: false,
    purchasePrice: 50,
    salePrice: 200,
    stock: stock,
    minimumStock: 0,
  );

  test(
    'almacén compartido conserva una venta offline y aplica cada operación una vez',
    () async {
      expect(File(databasePath).existsSync(), isTrue);
      await repository.saveProduct(product());
      await repository.saveCustomer(
        const Customer(id: 'ana', name: 'Ana', phone: '0000456'),
      );
      final dueAt = DateTime.now().toUtc().add(const Duration(days: 15));
      final sale = await repository.createSale(
        items: const [CartLine(productId: 'paper', quantity: 2)],
        paid: 100,
        customerId: 'ana',
        paymentMethod: 'Efectivo',
        dueAt: dueAt,
        operationId: 'android-sale',
      );
      final retry = await repository.createSale(
        items: const [CartLine(productId: 'paper', quantity: 2)],
        paid: 100,
        customerId: 'ana',
        paymentMethod: 'Efectivo',
        dueAt: dueAt,
        operationId: 'android-sale',
      );
      expect(retry.id, sale.id);
      expect((await repository.listProducts()).single.stock, 1);

      await expectLater(
        repository.createSale(
          items: const [CartLine(productId: 'paper', quantity: 2)],
          paid: 400,
          paymentMethod: 'Efectivo',
          operationId: 'android-no-stock',
        ),
        throwsA(isA<CapcException>()),
      );
      await expectLater(
        repository.createSale(
          items: const [CartLine(productId: 'paper', quantity: 1)],
          paid: 0,
          paymentMethod: 'Crédito',
          dueAt: dueAt,
          operationId: 'android-debt-no-customer',
        ),
        throwsA(isA<CapcException>()),
      );

      await repository.addPayment(
        sale.id,
        100,
        'Efectivo',
        operationId: 'android-payment',
      );
      await repository.addPayment(
        sale.id,
        100,
        'Efectivo',
        operationId: 'android-payment',
      );
      await expectLater(
        repository.addPayment(
          sale.id,
          201,
          'Efectivo',
          operationId: 'android-overpayment',
        ),
        throwsA(isA<CapcException>()),
      );

      await repository.close();
      repository = await CapcRepository.open(databasePath);
      await repository.login('owner', 'Clave-Android-2026');
      expect((await repository.listSales()).single.balance, 200);
      expect((await repository.listProducts()).single.stock, 1);
      expect(await repository.listPayments(), hasLength(2));

      final raw = sqlite3.open(databasePath, mode: OpenMode.readOnly);
      try {
        expect(
          raw.select('SELECT COUNT(*) AS n FROM outbox').single['n'],
          greaterThanOrEqualTo(5),
        );
        expect(
          raw
              .select("SELECT COUNT(*) AS n FROM outbox WHERE state='pending'")
              .single['n'],
          greaterThan(0),
        );
      } finally {
        raw.close();
      }
    },
  );

  test(
    'respaldo Android exportado e importado conserva un SQLite válido',
    () async {
      await repository.saveProduct(product());
      final saved = await BackupTransfer.exportBackup(
        repository,
        suggestedName: 'CAPC-respaldo-prueba.sqlite',
      );
      expect(saved?.displayLocation, startsWith('content://'));
      expect(platform.exportedBytes, isNotEmpty);

      final prepared = await BackupTransfer.prepareImport();
      expect(prepared, isNotNull);
      try {
        await CapcRepository.validateBackup(prepared!.path);
        final backup = await CapcRepository.open(prepared.path);
        try {
          await backup.login('owner', 'Clave-Android-2026');
          expect((await backup.listProducts()).single.code, '000123');
        } finally {
          await backup.close();
        }
      } finally {
        await prepared?.dispose();
      }
    },
  );
}
