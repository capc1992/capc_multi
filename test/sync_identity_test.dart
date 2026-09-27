import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/sync/remote_identity.dart';
import 'package:capc_multiservicio/sync/secure_credentials.dart';
import 'package:capc_multiservicio/sync/sync_transport.dart';
import 'package:capc_multiservicio/ui/remote_identity_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as native;

void main() {
  late Directory directory;
  late CapcRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_sync_identity_');
    repository = await CapcRepository.open(
      p.join(directory.path, 'identity.sqlite3'),
    );
    await repository.setupOwner(
      name: 'Propietaria',
      username: 'owner',
      password: 'clave-local-independiente-2026',
    );
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test('credenciales remotas permanecen en la abstracción segura', () async {
    final store = MemoryCredentialStore();
    final session = RemoteSession(
      businessId: repository.businessId,
      deviceId: repository.deviceId,
      accessToken: 'access-secret',
      refreshToken: 'refresh-secret',
      accessExpiresAt: DateTime.utc(2026, 10, 1),
      refreshExpiresAt: DateTime.utc(2026, 11, 1),
      permissions: const ['sync:read'],
    );
    await store.write(session);
    expect((await store.read())!.refreshToken, 'refresh-secret');
    await store.clear();
    expect(await store.read(), isNull);

    final db = native.sqlite3.open(
      repository.databasePath,
      mode: native.OpenMode.readOnly,
    );
    try {
      final values = db.select(
        "SELECT name FROM sqlite_master WHERE sql LIKE '%access_token%' OR sql LIKE '%refresh_token%'",
      );
      expect(values, isEmpty);
    } finally {
      db.close();
    }
  });

  test(
    'sin CAPC_SYNC_URL no lee credenciales ni habilita conexiones',
    () async {
      final store = MemoryCredentialStore();
      final controller = RemoteIdentityController(
        repository: repository,
        credentials: store,
        configuration: const SyncConfiguration(),
      );
      await controller.initialize();
      expect(controller.enabled, isFalse);
      expect(controller.connected, isFalse);
      expect(await controller.accessToken(), isNull);
    },
  );

  test(
    'solo una base sin movimientos puede adoptar el business_id canónico',
    () async {
      expect(
        await repository.remoteLinkState(),
        RemoteLinkState.newInstallation,
      );
      await repository.saveProduct(
        const Product(
          id: '55555555-5555-4555-8555-555555555555',
          code: 'P-1',
          name: 'Papel',
          unit: 'Unidad',
          isService: false,
          purchasePrice: 10,
          salePrice: 20,
          stock: 0,
          minimumStock: 0,
        ),
      );
      expect(await repository.remoteLinkState(), RemoteLinkState.noMovements);
      const canonical = '11111111-1111-4111-8111-111111111111';
      await repository.adoptRemoteBusinessId(canonical);
      expect(repository.businessId, canonical);
      expect(await repository.listProducts(), hasLength(1));
      final db = native.sqlite3.open(
        repository.databasePath,
        mode: native.OpenMode.readOnly,
      );
      try {
        expect(
          db
              .select('SELECT DISTINCT business_id FROM outbox')
              .single['business_id'],
          canonical,
        );
        expect(
          db
              .select("SELECT value FROM settings WHERE key='business_id'")
              .single['value'],
          canonical,
        );
      } finally {
        db.close();
      }

      await repository.adjustStock(
        '55555555-5555-4555-8555-555555555555',
        1,
        'Entrada',
        totalCost: 10,
      );
      expect(
        await repository.remoteLinkState(),
        RemoteLinkState.hasBusinessMovements,
      );
      await expectLater(
        repository.adoptRemoteBusinessId(
          '22222222-2222-4222-8222-222222222222',
        ),
        throwsA(isA<CapcException>()),
      );
      expect(repository.businessId, canonical);
    },
  );

  testWidgets('pantalla remota offline cabe a 375 px con texto al 200%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = RemoteIdentityController(
      repository: repository,
      credentials: MemoryCredentialStore(),
      configuration: const SyncConfiguration(),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: RemoteIdentityPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sin configuración remota'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
