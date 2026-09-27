import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:capc_multiservicio/update/update_controller.dart';
import 'package:capc_multiservicio/update/update_models.dart';
import 'package:capc_multiservicio/update/update_service.dart';
import 'package:capc_multiservicio/update/update_store.dart';
import 'package:capc_multiservicio/update/update_transport.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart' as play;

void main() {
  late Directory temporary;
  final installed = AppVersion(
    versionName: '0.4.0',
    buildNumber: 7,
    packageName: 'com.example.capc_multi',
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('capc-update-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  group('controlador compartido', () {
    test('aplicación actualizada', () async {
      final service = _FakeService(installed: installed);
      final controller = _controller(service);
      await controller.initialize();
      await _settle();
      expect(controller.status, UpdateStatus.upToDate);
      expect(controller.message, 'Tienes la última versión.');
    });

    test('nueva versión disponible', () async {
      final service = _FakeService(
        installed: installed,
        result: _release(version: '0.4.1', build: 8),
      );
      final controller = _controller(service);
      await controller.initialize();
      await _settle();
      expect(controller.status, UpdateStatus.available);
      expect(controller.mandatory, isFalse);
    });

    test(
      'actualización obligatoria por bandera o compilación mínima',
      () async {
        for (final release in [
          _release(version: '0.4.1', build: 8, mandatory: true),
          _release(version: '0.4.1', build: 8, minimum: 8),
        ]) {
          final controller = _controller(
            _FakeService(installed: installed, result: release),
          );
          await controller.initialize();
          await _settle();
          expect(controller.mandatory, isTrue);
        }
      },
    );

    test('sin internet conserva la aplicación disponible', () async {
      final controller = _controller(
        _FakeService(
          installed: installed,
          failure: const UpdateException('Sin internet.', offline: true),
        ),
      );
      await controller.initialize();
      await _settle();
      expect(controller.status, UpdateStatus.offline);
      expect(controller.installedVersion, installed);
    });

    test('tiempo de espera produce error recuperable', () async {
      final controller = _controller(
        _FakeService(
          installed: installed,
          failure: const UpdateException('Tiempo de espera agotado.'),
        ),
      );
      await controller.initialize();
      await _settle();
      expect(controller.status, UpdateStatus.error);
      expect(controller.message, contains('Tiempo'));
    });

    test('persiste la comprobación y no repite antes de 24 horas', () async {
      final now = DateTime.utc(2026, 9, 27, 15);
      final store = MemoryUpdateCheckStore()
        ..value = now.subtract(const Duration(hours: 2));
      final service = _FakeService(installed: installed);
      final controller = UpdateController(
        service: service,
        store: store,
        channel: UpdateChannel.stable,
        now: () => now,
      );
      await controller.initialize();
      await _settle();
      expect(service.checks, 0);
      await controller.check();
      expect(service.checks, 1);
      expect(store.value, now);
    });
  });

  group('manifiesto y descarga Windows', () {
    test('rechaza JSON incorrecto y esquema desconocido', () async {
      for (final manifest in ['{incorrecto', _manifest(schema: 2)]) {
        final service = _windows(
          installed,
          temporary,
          _FakeTransport(manifest: utf8.encode(manifest)),
        );
        await expectLater(
          service.checkForUpdate(installed, UpdateChannel.stable),
          throwsA(isA<UpdateException>()),
        );
      }
    });

    test('rechaza intento de instalar versión inferior', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      final release = _release(version: '0.3.9', build: 99, bytes: data);
      final service = _windows(
        installed,
        temporary,
        _FakeTransport(manifest: utf8.encode(_manifest()), data: data),
      );
      await expectLater(
        service.download(release, installed, (_) {}),
        throwsA(isA<UpdateException>()),
      );
    });

    test('elimina descarga interrumpida', () async {
      final data = Uint8List.fromList(List.generate(64, (index) => index));
      final service = _windows(
        installed,
        temporary,
        _FakeTransport(
          manifest: utf8.encode(_manifest()),
          data: data,
          interrupt: true,
        ),
      );
      await expectLater(
        service.download(
          _release(version: '0.4.1', build: 8, bytes: data),
          installed,
          (_) {},
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(temporary.listSync(), isEmpty);
    });

    test('rechaza tamaño incorrecto', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      final release = _release(
        version: '0.4.1',
        build: 8,
        bytes: data,
        declaredSize: 4,
      );
      final service = _windows(
        installed,
        temporary,
        _FakeTransport(manifest: utf8.encode(_manifest()), data: data),
      );
      await expectLater(
        service.download(release, installed, (_) {}),
        throwsA(isA<UpdateException>()),
      );
      expect(temporary.listSync(), isEmpty);
    });

    test('rechaza SHA-256 incorrecto', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      final release = UpdateRelease(
        platform: 'windows-x64',
        channel: UpdateChannel.stable,
        versionName: '0.4.1',
        buildNumber: 8,
        publishedAt: DateTime.utc(2026, 9, 27),
        mandatory: false,
        minimumSupportedBuild: 7,
        releaseNotes: const ['Prueba'],
        artifact: UpdateArtifact(
          url: Uri.parse('https://updates.capcmultiservicios.site/file.exe'),
          sha256: List.filled(64, 'A').join(),
          sizeBytes: data.length,
        ),
      );
      final service = _windows(
        installed,
        temporary,
        _FakeTransport(manifest: utf8.encode(_manifest()), data: data),
      );
      await expectLater(
        service.download(release, installed, (_) {}),
        throwsA(isA<UpdateException>()),
      );
      expect(temporary.listSync(), isEmpty);
    });

    test('rechaza instalador sin firma', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      final service = _windows(
        installed,
        temporary,
        _FakeTransport(manifest: utf8.encode(_manifest()), data: data),
        signature: const InstallerSignature(
          valid: false,
          publisher: '',
          reason: 'Sin firma.',
        ),
      );
      await expectLater(
        service.download(
          _release(version: '0.4.1', build: 8, bytes: data),
          installed,
          (_) {},
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(temporary.listSync(), isEmpty);
    });

    test('rechaza HTTP y redirección a otro dominio', () {
      final policy = UpdateSecurityPolicy(
        allowedHosts: const {'updates.capcmultiservicios.site'},
      );
      expect(
        () => policy.validate(
          Uri.parse('http://updates.capcmultiservicios.site/latest.json'),
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(
        () => policy.validateRedirect(
          Uri.parse('https://updates.capcmultiservicios.site/latest.json'),
          'https://example.com/file.exe',
        ),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  test(
    'Windows descarga instalador y Android usa flujo flexible o inmediato',
    () async {
      final data = Uint8List.fromList([7, 8, 9]);
      final windows = _windows(
        installed,
        temporary,
        _FakeTransport(manifest: utf8.encode(_manifest()), data: data),
      );
      expect(windows.platform, UpdatePlatform.windows);
      final prepared = await windows.download(
        _release(version: '0.4.1', build: 8, bytes: data),
        installed,
        (_) {},
      );
      expect(File(prepared.path).existsSync(), isTrue);

      final flexibleGateway = _FakeAndroidGateway(priority: 1);
      final android = AndroidUpdateService(
        versionProvider: _VersionProvider(installed),
        gateway: flexibleGateway,
      );
      final flexibleRelease = await android.checkForUpdate(
        installed,
        UpdateChannel.stable,
      );
      await android.startAndroidUpdate(flexibleRelease!);
      expect(flexibleGateway.flexibleStarts, 1);
      expect(flexibleGateway.immediateStarts, 0);

      final immediateGateway = _FakeAndroidGateway(priority: 5);
      final mandatoryAndroid = AndroidUpdateService(
        versionProvider: _VersionProvider(installed),
        gateway: immediateGateway,
      );
      final mandatoryRelease = await mandatoryAndroid.checkForUpdate(
        installed,
        UpdateChannel.stable,
      );
      expect(mandatoryRelease!.mandatory, isTrue);
      await mandatoryAndroid.startAndroidUpdate(mandatoryRelease);
      expect(immediateGateway.immediateStarts, 1);
      expect(immediateGateway.flexibleStarts, 0);
    },
  );
}

UpdateController _controller(_FakeService service) => UpdateController(
  service: service,
  store: MemoryUpdateCheckStore(),
  channel: UpdateChannel.stable,
  now: () => DateTime.utc(2026, 9, 27, 15),
  terminateApplication: () async {},
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

UpdateRelease _release({
  required String version,
  required int build,
  bool mandatory = false,
  int minimum = 7,
  Uint8List? bytes,
  int? declaredSize,
}) {
  final data = bytes ?? Uint8List.fromList([1, 2, 3]);
  return UpdateRelease(
    platform: 'windows-x64',
    channel: UpdateChannel.stable,
    versionName: version,
    buildNumber: build,
    publishedAt: DateTime.utc(2026, 9, 27, 15),
    mandatory: mandatory,
    minimumSupportedBuild: minimum,
    releaseNotes: const ['Mejoras de estabilidad'],
    artifact: UpdateArtifact(
      url: Uri.parse(
        'https://updates.capcmultiservicios.site/windows/stable/$version/setup.exe',
      ),
      sha256: sha256.convert(data).toString().toUpperCase(),
      sizeBytes: declaredSize ?? data.length,
    ),
  );
}

String _manifest({int schema = 1}) => jsonEncode({
  'schemaVersion': schema,
  'platform': 'windows-x64',
  'channel': 'stable',
  'versionName': '0.4.1',
  'buildNumber': 8,
  'publishedAt': '2026-09-27T15:00:00Z',
  'mandatory': false,
  'minimumSupportedBuild': 7,
  'releaseNotes': ['Mejoras'],
  'artifact': {
    'url':
        'https://updates.capcmultiservicios.site/windows/stable/0.4.1/setup.exe',
    'sha256': List.filled(64, 'A').join(),
    'sizeBytes': 3,
  },
});

WindowsUpdateService _windows(
  AppVersion installed,
  Directory temporary,
  UpdateTransport transport, {
  InstallerSignature signature = const InstallerSignature(
    valid: true,
    publisher: 'CN=CAPC MULTISERVICIO',
  ),
}) => WindowsUpdateService(
  versionProvider: _VersionProvider(installed),
  configuration: WindowsUpdateConfiguration(
    manifestUri: Uri.parse(
      'https://updates.capcmultiservicios.site/windows/stable/latest.json',
    ),
    channel: UpdateChannel.stable,
    expectedPublisher: 'CAPC MULTISERVICIO',
    allowedHosts: const {'updates.capcmultiservicios.site'},
  ),
  transport: transport,
  signatureVerifier: _SignatureVerifier(signature),
  launcher: _Launcher(),
  temporaryDirectory: () async => temporary,
);

class _VersionProvider implements PackageVersionProvider {
  const _VersionProvider(this.value);
  final AppVersion value;
  @override
  Future<AppVersion> current() async => value;
}

class _FakeService extends UpdateService {
  _FakeService({required AppVersion installed, this.result, this.failure})
    : super(versionProvider: _VersionProvider(installed));

  final UpdateRelease? result;
  final UpdateException? failure;
  int checks = 0;

  @override
  UpdatePlatform get platform => UpdatePlatform.windows;

  @override
  Future<UpdateRelease?> checkForUpdate(
    AppVersion installed,
    UpdateChannel channel,
  ) async {
    checks++;
    if (failure != null) throw failure!;
    return result;
  }
}

class _FakeTransport implements UpdateTransport {
  _FakeTransport({
    required List<int> manifest,
    this.data,
    this.interrupt = false,
  }) : manifest = Uint8List.fromList(manifest);
  final Uint8List manifest;
  final Uint8List? data;
  final bool interrupt;

  @override
  Future<Uint8List> getBytes(Uri uri, {required int maximumBytes}) async =>
      manifest;

  @override
  Future<int> download(
    Uri uri,
    File destination, {
    required int maximumBytes,
    required void Function(int received, int? total) onProgress,
  }) async {
    final bytes = data ?? Uint8List.fromList([1, 2, 3]);
    if (interrupt) {
      await destination.writeAsBytes(
        bytes.sublist(0, bytes.length ~/ 2),
        flush: true,
      );
      throw const UpdateException('Descarga interrumpida.', offline: true);
    }
    await destination.writeAsBytes(bytes, flush: true);
    onProgress(bytes.length, bytes.length);
    return bytes.length;
  }
}

class _SignatureVerifier implements InstallerSignatureVerifier {
  const _SignatureVerifier(this.signature);
  final InstallerSignature signature;
  @override
  Future<InstallerSignature> verify(
    File installer,
    String expectedPublisher,
  ) async => signature;
}

class _Launcher implements WindowsInstallerLauncher {
  @override
  Future<void> launch(File installer) async {}
}

class _FakeAndroidGateway implements AndroidUpdateGateway {
  _FakeAndroidGateway({required this.priority});
  final int priority;
  final events = StreamController<play.InstallStatus>.broadcast();
  int flexibleStarts = 0;
  int immediateStarts = 0;

  @override
  Stream<play.InstallStatus> get installStatus => events.stream;

  @override
  Future<play.AppUpdateInfo> check() async => play.AppUpdateInfo(
    updateAvailability: play.UpdateAvailability.updateAvailable,
    immediateUpdateAllowed: true,
    immediateAllowedPreconditions: const [],
    flexibleUpdateAllowed: true,
    flexibleAllowedPreconditions: const [],
    availableVersionCode: 8,
    installStatus: play.InstallStatus.unknown,
    packageName: 'com.example.capc_multi',
    clientVersionStalenessDays: 1,
    updatePriority: priority,
  );

  @override
  Future<void> completeFlexible() async {}

  @override
  Future<void> openStore() async {}

  @override
  Future<play.AppUpdateResult> startFlexible() async {
    flexibleStarts++;
    return play.AppUpdateResult.success;
  }

  @override
  Future<play.AppUpdateResult> startImmediate() async {
    immediateStarts++;
    return play.AppUpdateResult.success;
  }
}
