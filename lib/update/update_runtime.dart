import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/platform_services.dart';
import 'update_controller.dart';
import 'update_models.dart';
import 'update_service.dart';
import 'update_store.dart';
import 'update_transport.dart';

class UpdateRuntime {
  const UpdateRuntime._();

  static UpdateController create({required String databasePath}) {
    final provider = PlatformPackageVersionProvider();
    final stateFile = File(
      p.join(p.dirname(databasePath), 'update-check.json'),
    );
    UpdateChannel channel;
    UpdateService service;
    try {
      const rawChannel = String.fromEnvironment(
        'CAPC_UPDATE_CHANNEL',
        defaultValue: 'stable',
      );
      channel = UpdateChannel.parse(rawChannel);
      service = switch (appPlatform.kind) {
        CapcPlatformKind.windows => _windows(provider),
        CapcPlatformKind.android => AndroidUpdateService(
          versionProvider: provider,
          gateway: PlayCoreUpdateGateway(),
        ),
      };
    } on UpdateException catch (error) {
      channel = UpdateChannel.stable;
      service = UnavailableUpdateService(
        versionProvider: provider,
        currentPlatform: appPlatform.isAndroid
            ? UpdatePlatform.android
            : UpdatePlatform.windows,
        reason: error.message,
      );
    }
    return UpdateController(
      service: service,
      store: FileUpdateCheckStore(stateFile),
      channel: channel,
    );
  }

  static WindowsUpdateService _windows(PackageVersionProvider provider) {
    final configuration = WindowsUpdateConfiguration.fromEnvironment();
    final policy = UpdateSecurityPolicy(
      allowedHosts: configuration.allowedHosts,
    );
    return WindowsUpdateService(
      versionProvider: provider,
      configuration: configuration,
      transport: HttpUpdateTransport(policy: policy),
      signatureVerifier: PowerShellAuthenticodeVerifier(),
      launcher: InnoInstallerLauncher(),
      temporaryDirectory: appPlatform.temporaryDirectory,
    );
  }
}
