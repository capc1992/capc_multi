import 'dart:convert';
import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/sync/remote_identity.dart';
import 'package:capc_multiservicio/sync/secure_credentials.dart';
import 'package:capc_multiservicio/sync/sync_coordinator.dart';
import 'package:capc_multiservicio/sync/sync_engine.dart';
import 'package:capc_multiservicio/sync/sync_models.dart';
import 'package:capc_multiservicio/sync/sync_transport.dart';
import 'package:capc_multiservicio/ui/remote_identity_page.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as native;

class _DeletionController extends RemoteIdentityController {
  // The explicit constructor also supplies the test-only remote URL.
  // ignore: use_super_parameters
  _DeletionController({required CapcRepository repository})
    : _session = RemoteSession(
        businessId: repository.businessId,
        deviceId: repository.deviceId,
        accessToken: 'access-token-for-widget',
        refreshToken: 'refresh-token-for-widget',
        accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
        permissions: const ['devices:manage'],
      ),
      super(
        repository: repository,
        configuration: SyncConfiguration(
          baseUri: Uri.parse('https://api.example.test'),
        ),
      );

  final RemoteSession _session;
  bool deleted = false;
  bool failLinkCode = false;

  @override
  Future<LinkingCode> createLinkCode() async {
    if (failLinkCode) {
      throw const RemoteIdentityException('No se pudo generar el código.');
    }
    return LinkingCode(
      'ABCD234567',
      DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  bool get enabled => true;

  @override
  bool get connected => !deleted;

  @override
  RemoteSession? get session => deleted ? null : _session;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<RemoteDevice>> listDevices() async => const [];

  @override
  Future<void> deleteAccount({
    required String email,
    required String password,
  }) async {
    expect(email, 'owner@example.test');
    expect(password, 'remote-password-2026');
    deleted = true;
  }
}

// Bypass the widget binding's HTTP stub for the loopback transport regression.
class _RealHttpOverrides extends HttpOverrides {}

class _FakeSyncEngine extends SyncEngine {
  _FakeSyncEngine({required this.testRepository, required super.configuration})
    : super(repository: testRepository);

  final CapcRepository testRepository;
  int calls = 0;

  @override
  Future<SyncRunResult> runOnce({
    int batchSize = 100,
    bool forceRetry = true,
  }) async {
    calls++;
    await testRepository.setSyncStatus(SyncStatus.synced, successful: true);
    return const SyncRunResult(
      enabled: true,
      pushed: 0,
      received: 0,
      applied: 0,
      conflicts: 0,
      cursor: 0,
    );
  }
}

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
    'concesión offline firmada limita dispositivo, permisos y 72 horas',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final issued = DateTime.now().toUtc();
      final payload = base64UrlEncode(
        utf8.encode(
          jsonEncode({
            'business_id': repository.businessId,
            'device_id': repository.deviceId,
            'principal_id': 'central-user',
            'principal_name': 'Caja central',
            'username': 'caja.central',
            'role_type': 'operational',
            'permissions': ['ventas.ver', 'ventas.crear'],
            'security_version': 3,
            'issued_at': issued.toIso8601String(),
            'expires_at': issued
                .add(const Duration(hours: 72))
                .toIso8601String(),
          }),
        ),
      );
      final signature = await algorithm.sign(
        utf8.encode(payload),
        keyPair: keyPair,
      );
      final session = RemoteSession(
        businessId: repository.businessId,
        deviceId: repository.deviceId,
        userId: 'central-user',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: issued.add(const Duration(minutes: 15)),
        refreshExpiresAt: issued.add(const Duration(days: 30)),
        permissions: const ['ventas.ver', 'ventas.crear'],
        offlineGrant: '$payload.${base64UrlEncode(signature.bytes)}',
        offlineGrantPublicKey: base64UrlEncode(publicKey.bytes),
        offlineGrantExpiresAt: issued.add(const Duration(hours: 72)),
      );
      final authorization = await session.verifyOfflineAuthorization(
        now: issued,
      );
      expect(authorization!.can('ventas.crear'), isTrue);
      expect(authorization.can('productos.eliminar'), isFalse);
      expect(authorization.securityVersion, 3);
      expect(
        await session.verifyOfflineAuthorization(
          now: issued.add(const Duration(hours: 72, seconds: 1)),
        ),
        isNull,
      );
      final tampered = RemoteSession.fromJson({
        ...session.toJson(),
        'offline_grant': '${payload}x.${base64UrlEncode(signature.bytes)}',
      });
      expect(await tampered.verifyOfflineAuthorization(now: issued), isNull);
    },
  );

  test(
    'usuario central conserva acceso offline y aplica permisos exactos',
    () async {
      final issued = DateTime.now().toUtc();
      final authorization = OfflineAuthorization(
        businessId: repository.businessId,
        deviceId: repository.deviceId,
        userId: 'central-user',
        principalName: 'Consulta de productos',
        username: 'consulta.productos',
        roleType: 'administrator',
        permissions: const ['productos.ver'],
        securityVersion: 4,
        issuedAt: issued,
        expiresAt: issued.add(const Duration(hours: 24)),
      );
      await repository.cacheCentralLogin(
        authorization,
        'clave-central-segura-2026',
      );
      expect(repository.currentUser!.central, isTrue);
      expect(repository.currentUser!.roleLabel, 'Administrador configurable');
      expect(await repository.listProducts(), isEmpty);
      await expectLater(
        repository.saveProduct(
          const Product(
            id: '',
            code: 'P-1',
            name: 'Sin permiso',
            unit: 'unidad',
            isService: false,
            purchasePrice: 1,
            salePrice: 2,
            stock: 0,
            minimumStock: 0,
          ),
        ),
        throwsA(isA<CapcException>()),
      );

      repository.logout();
      await repository.loginCentralOffline(
        'consulta.productos',
        'clave-central-segura-2026',
        authorization,
      );
      expect(repository.hasPermission('productos.ver'), isTrue);
      expect(repository.hasPermission('productos.crear'), isFalse);

      final renewed = OfflineAuthorization(
        businessId: repository.businessId,
        deviceId: repository.deviceId,
        userId: 'central-user',
        principalName: 'Consulta renovada',
        username: 'consulta.productos',
        roleType: 'administrator',
        permissions: const ['productos.ver', 'productos.crear'],
        securityVersion: 5,
        issuedAt: issued.add(const Duration(hours: 1)),
        expiresAt: issued.add(const Duration(hours: 73)),
      );
      await repository.refreshCentralAuthorization(renewed);
      expect(repository.currentUser!.name, 'Consulta renovada');
      expect(repository.hasPermission('productos.crear'), isTrue);
    },
  );

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

  test(
    'peticiones sin cuerpo no anuncian JSON vacío al generar código y salir',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = _RealHttpOverrides().createHttpClient(null);
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
      });
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        final body = await utf8.decoder.bind(request).join();
        if (body.isEmpty &&
            request.headers.contentType?.mimeType == 'application/json') {
          request.response.statusCode = 400;
          request.response.write(jsonEncode({'error': 'invalid_request'}));
        } else if (request.uri.path.endsWith('/link-codes')) {
          request.response.statusCode = 201;
          request.response.write(
            jsonEncode({
              'code': 'ABCD234567',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
            }),
          );
        } else {
          request.response.statusCode = 204;
        }
        await request.response.close();
      });
      final credentials = MemoryCredentialStore();
      await credentials.write(
        _DeletionController(repository: repository).session!,
      );
      final controller = RemoteIdentityController(
        repository: repository,
        credentials: credentials,
        client: client,
        configuration: SyncConfiguration(
          baseUri: Uri.parse('http://localhost:${server.port}'),
        ),
      );
      await controller.initialize();
      expect((await controller.createLinkCode()).code, 'ABCD234567');
      await controller.logout();
      expect(paths, ['/api/v1/identity/link-codes', '/api/v1/identity/logout']);
      expect(await credentials.read(), isNull);
    },
  );

  test(
    'control central serializa roles y usuarios sin guardar el código',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = _RealHttpOverrides().createHttpClient(null);
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
      });
      final requests = <Map<String, Object?>>[];
      server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        requests.add({
          'method': request.method,
          'path': request.uri.path,
          'body': text.isEmpty ? null : jsonDecode(text),
        });
        final response = switch (request.uri.path) {
          '/api/v1/access/permissions' => {
            'permissions': [
              {
                'key': 'ventas.ver',
                'module': 'ventas',
                'action': 'ver',
                'description': 'Consultar ventas',
              },
            ],
          },
          '/api/v1/access/roles' =>
            request.method == 'GET'
                ? {
                    'roles': [
                      {
                        'id': '11111111-1111-4111-8111-111111111111',
                        'name': 'Cajero',
                        'roleType': 'operational',
                        'permissions': ['ventas.ver'],
                        'system': false,
                        'version': 1,
                      },
                    ],
                  }
                : {
                    'role': {
                      'id': '11111111-1111-4111-8111-111111111111',
                      'name': 'Cajero',
                      'roleType': 'operational',
                      'permissions': ['ventas.ver'],
                      'system': false,
                      'version': 1,
                    },
                  },
          '/api/v1/access/users' => {
            'user': {
              'id': '22222222-2222-4222-8222-222222222222',
              'name': 'Carlos',
              'username': 'carlos',
              'email': null,
              'active': true,
              'activated': false,
              'roles': [
                {
                  'id': '11111111-1111-4111-8111-111111111111',
                  'name': 'Cajero',
                },
              ],
              'securityVersion': 1,
            },
            'activation_code': 'codigo-secreto-de-un-solo-uso',
            'activation_expires_at': '2026-10-01T00:00:00.000Z',
          },
          '/api/v1/access/activate' => <String, Object?>{},
          '/api/v1/access/login' => {
            'business_id': repository.businessId,
            'device_id': repository.deviceId,
            'user_id': '22222222-2222-4222-8222-222222222222',
            'permissions': ['sync:read', 'sync:write', 'ventas.ver'],
            'access_token': 'central-access-token',
            'refresh_token': 'central-refresh-token',
            'access_expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
            'refresh_expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(days: 1))
                .toIso8601String(),
          },
          _ => <String, Object?>{},
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final credentials = MemoryCredentialStore();
      await credentials.write(
        RemoteSession(
          businessId: repository.businessId,
          deviceId: repository.deviceId,
          accessToken: 'access-token',
          refreshToken: 'refresh-token',
          accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
          permissions: const ['access:read', 'access:manage'],
        ),
      );
      final controller = RemoteIdentityController(
        repository: repository,
        credentials: credentials,
        client: client,
        configuration: SyncConfiguration(
          baseUri: Uri.parse('http://localhost:${server.port}'),
        ),
      );
      await controller.initialize();
      expect(
        (await controller.listAccessPermissions()).single.key,
        'ventas.ver',
      );
      final role = (await controller.listAccessRoles()).single;
      await controller.saveAccessRole(
        name: role.name,
        roleType: role.roleType,
        permissions: role.permissions,
      );
      final created = await controller.createAccessUser(
        name: 'Carlos',
        username: 'carlos',
        roleIds: [role.id],
      );
      expect(created.user.activated, isFalse);
      expect(created.activationCode, 'codigo-secreto-de-un-solo-uso');
      expect(requests.last['body'], {
        'name': 'Carlos',
        'username': 'carlos',
        'role_ids': [role.id],
      });
      await controller.activateAccessUser(
        username: 'carlos',
        activationCode: created.activationCode,
        password: 'central-password-2026',
      );
      await controller.loginAccessUser(
        username: 'carlos',
        password: 'central-password-2026',
      );
      expect(
        controller.session!.userId,
        '22222222-2222-4222-8222-222222222222',
      );
      expect(controller.session!.permissions, contains('ventas.ver'));
      expect(requests.toString(), isNot(contains('refresh-token')));
    },
  );

  testWidgets('generar código muestra el código y su vencimiento', (
    tester,
  ) async {
    final controller = _DeletionController(repository: repository);
    await tester.pumpWidget(
      MaterialApp(home: RemoteIdentityPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generar código temporal'));
    // The request remains busy while the modal is open, so its underlying
    // progress indicator keeps animating until the user dismisses the code.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Código de vinculación'), findsOneWidget);
    expect(find.text('ABCD234567'), findsOneWidget);
    expect(find.textContaining('Vence a las'), findsOneWidget);
    await tester.tap(find.text('Listo'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'fallo al generar código aparece sin buscar al final de la página',
    (tester) async {
      final controller = _DeletionController(repository: repository)
        ..failLinkCode = true;
      await tester.pumpWidget(
        MaterialApp(home: RemoteIdentityPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generar código temporal'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('No se pudo generar el código.'),
        ),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('eliminación remota exige contraseña y confirmación escrita', (
    tester,
  ) async {
    final controller = _DeletionController(repository: repository);
    await tester.pumpWidget(
      MaterialApp(home: RemoteIdentityPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Eliminar cuenta remota'),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Eliminar cuenta remota'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Eliminar definitivamente'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Correo remoto'),
      'owner@example.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Contraseña remota'),
      'remote-password-2026',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Escribe ELIMINAR para confirmar'),
      'BORRAR',
    );
    await tester.tap(find.text('Eliminar definitivamente'));
    await tester.pump();
    expect(find.text('Escribe exactamente ELIMINAR.'), findsOneWidget);
    expect(controller.deleted, isFalse);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Escribe ELIMINAR para confirmar'),
      'ELIMINAR',
    );
    await tester.tap(find.text('Eliminar definitivamente'));
    await tester.pumpAndSettle();
    expect(controller.deleted, isTrue);
    expect(
      find.textContaining('datos sincronizados fueron eliminados'),
      findsOneWidget,
    );
  });

  test(
    'coordinador ejecuta sincronización manual y actualiza el estado',
    () async {
      final controller = _DeletionController(repository: repository);
      final configuration = SyncConfiguration(
        baseUri: controller.configuration.baseUri,
        tokenProvider: controller.accessToken,
      );
      final engine = _FakeSyncEngine(
        testRepository: repository,
        configuration: configuration,
      );
      final coordinator = SyncCoordinator(
        repository: repository,
        identity: controller,
        retryInterval: const Duration(days: 1),
        engine: engine,
      );
      addTearDown(coordinator.dispose);
      await coordinator.refreshStatus();
      final result = await coordinator.syncNow();
      expect(engine.calls, 1);
      expect(result, isNotNull);
      expect(coordinator.snapshot!.status, SyncStatus.synced);
      expect(coordinator.running, isFalse);
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
