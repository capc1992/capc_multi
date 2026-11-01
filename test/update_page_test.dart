import 'dart:io';

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/ui/update_page.dart';
import 'package:capc_multiservicio/update/update_controller.dart';
import 'package:capc_multiservicio/update/update_models.dart';
import 'package:capc_multiservicio/update/update_service.dart';
import 'package:capc_multiservicio/update/update_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late CapcRepository repository;
  late UpdateController controller;

  setUp(() async {
    await initializeDateFormatting('es_CO');
    temporary = await Directory.systemTemp.createTemp('capc-update-ui-');
    repository = await CapcRepository.open(
      p.join(temporary.path, 'test.sqlite'),
    );
    controller = UpdateController(
      service: _UiUpdateService(),
      store: MemoryUpdateCheckStore(),
      channel: UpdateChannel.stable,
    );
    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    controller.dispose();
    await repository.close();
    await temporary.delete(recursive: true);
  });

  testWidgets('centro es legible en teléfono pequeño y texto grande', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(375, 667),
            textScaler: TextScaler.linear(2),
          ),
          child: UpdatePage(
            controller: controller,
            repository: repository,
            canInstall: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Centro de actualizaciones'), findsOneWidget);
    expect(find.text('Descargar e instalar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('centro se adapta a orientación horizontal', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: UpdatePage(
          controller: controller,
          repository: repository,
          canInstall: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Actualizaciones'), findsOneWidget);
    expect(
      find.textContaining('propietario debe iniciar sesión'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _VersionProvider implements PackageVersionProvider {
  @override
  Future<AppVersion> current() async => AppVersion(
    versionName: '0.4.0',
    buildNumber: 7,
    packageName: 'site.capcmultiservicios.capc',
  );
}

class _UiUpdateService extends UpdateService {
  _UiUpdateService() : super(versionProvider: _VersionProvider());

  @override
  UpdatePlatform get platform => UpdatePlatform.windows;

  @override
  Future<UpdateRelease?> checkForUpdate(
    AppVersion installed,
    UpdateChannel channel,
  ) async => UpdateRelease(
    platform: 'windows-x64',
    channel: channel,
    versionName: '0.4.1',
    buildNumber: 8,
    publishedAt: DateTime.utc(2026, 9, 27, 15),
    mandatory: false,
    minimumSupportedBuild: 7,
    releaseNotes: const ['Mejoras de estabilidad'],
    artifact: UpdateArtifact(
      url: Uri.https(
        'updates.capcmultiservicios.site',
        '/windows/stable/0.4.1/CAPC-MULTISERVICIO-Setup-0.4.1.exe',
      ),
      sha256: 'A' * 64,
      sizeBytes: 1024,
    ),
  );
}
