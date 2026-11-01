import 'package:capc_multiservicio/platform/platform_ios.dart';
import 'package:capc_multiservicio/platform/platform_services.dart';
import 'package:capc_multiservicio/update/update_models.dart';
import 'package:capc_multiservicio/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _VersionProvider implements PackageVersionProvider {
  @override
  Future<AppVersion> current() async => AppVersion(
    versionName: '0.4.2',
    buildNumber: 9,
    packageName: 'site.capcmultiservicios.capc',
  );
}

void main() {
  test('iOS usa servicios móviles y comparte documentos', () {
    final platform = IosPlatformServices();
    expect(platform.kind, CapcPlatformKind.ios);
    expect(platform.platformLabel, 'iOS');
    expect(platform.isAndroid, isFalse);
    expect(platform.isIOS, isTrue);
    expect(platform.supportsDocumentSharing, isTrue);
  });

  test('iOS informa que la actualización se instala con Sideloadly', () async {
    final service = UnavailableUpdateService(
      versionProvider: _VersionProvider(),
      currentPlatform: UpdatePlatform.ios,
      reason: 'Instala la nueva IPA con Sideloadly.',
    );
    expect(service.platform, UpdatePlatform.ios);
    final installed = await service.currentVersion();
    expect(
      () => service.checkForUpdate(installed, UpdateChannel.stable),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('Sideloadly'),
        ),
      ),
    );
  });

  test('los documentos aceptan identificadores UTI de Apple', () {
    const type = DocumentType(
      label: 'PDF',
      extensions: ['pdf'],
      mimeType: 'application/pdf',
      uniformTypeIdentifiers: ['com.adobe.pdf'],
    );
    expect(type.uniformTypeIdentifiers, ['com.adobe.pdf']);
  });
}
