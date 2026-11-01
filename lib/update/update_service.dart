import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart' as play;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import 'update_models.dart';
import 'update_transport.dart';

abstract interface class PackageVersionProvider {
  Future<AppVersion> current();
}

class PlatformPackageVersionProvider implements PackageVersionProvider {
  @override
  Future<AppVersion> current() async {
    final package = await PackageInfo.fromPlatform();
    final build = int.tryParse(package.buildNumber);
    if (build == null || build <= 0) {
      throw const UpdateException(
        'El número de compilación instalado no es válido.',
      );
    }
    return AppVersion(
      versionName: package.version,
      buildNumber: build,
      packageName: package.packageName,
    );
  }
}

abstract class UpdateService {
  UpdateService({required this.versionProvider});
  final PackageVersionProvider versionProvider;

  UpdatePlatform get platform;
  Stream<PlatformUpdateEvent> get platformProgress => const Stream.empty();

  Future<AppVersion> currentVersion() => versionProvider.current();
  Future<UpdateRelease?> checkForUpdate(
    AppVersion installed,
    UpdateChannel channel,
  );

  Future<PreparedUpdate> download(
    UpdateRelease release,
    AppVersion installed,
    void Function(double? progress) onProgress,
  ) => throw UnsupportedError(
    'Esta plataforma no descarga instaladores directamente.',
  );

  Future<void> installPrepared(
    PreparedUpdate prepared,
    AppVersion installed, {
    required Future<void> Function() createBackup,
    required Future<void> Function() closeApplicationData,
  }) => throw UnsupportedError(
    'Esta plataforma no instala ejecutables directamente.',
  );

  Future<void> startAndroidUpdate(UpdateRelease release) =>
      throw UnsupportedError('Esta plataforma no usa Google Play.');

  Future<void> completeAndroidUpdate() =>
      throw UnsupportedError('Esta plataforma no usa Google Play.');

  Future<void> openStoreListing() =>
      throw UnsupportedError('Esta plataforma no usa Google Play.');
}

class UnavailableUpdateService extends UpdateService {
  UnavailableUpdateService({
    required super.versionProvider,
    required this.currentPlatform,
    required this.reason,
  });

  final UpdatePlatform currentPlatform;
  final String reason;

  @override
  UpdatePlatform get platform => currentPlatform;

  @override
  Future<UpdateRelease?> checkForUpdate(
    AppVersion installed,
    UpdateChannel channel,
  ) => throw UpdateException(reason);
}

class WindowsUpdateConfiguration {
  const WindowsUpdateConfiguration({
    required this.manifestUri,
    required this.channel,
    required this.expectedPublisher,
    required this.allowedHosts,
  });

  final Uri manifestUri;
  final UpdateChannel channel;
  final String expectedPublisher;
  final Set<String> allowedHosts;

  factory WindowsUpdateConfiguration.fromEnvironment() {
    const rawChannel = String.fromEnvironment(
      'CAPC_UPDATE_CHANNEL',
      defaultValue: 'stable',
    );
    final channel = UpdateChannel.parse(rawChannel);
    const override = String.fromEnvironment('CAPC_UPDATE_WINDOWS_URL');
    final uri = Uri.parse(
      override.isEmpty
          ? 'https://updates.capcmultiservicios.site/windows/${channel.slug}/latest.json'
          : override,
    );
    const publisher = String.fromEnvironment('CAPC_WINDOWS_UPDATE_PUBLISHER');
    return WindowsUpdateConfiguration(
      manifestUri: uri,
      channel: channel,
      expectedPublisher: publisher.trim(),
      allowedHosts: const {'updates.capcmultiservicios.site'},
    );
  }
}

class InstallerSignature {
  const InstallerSignature({
    required this.valid,
    required this.publisher,
    this.reason,
  });
  final bool valid;
  final String publisher;
  final String? reason;
}

abstract interface class InstallerSignatureVerifier {
  Future<InstallerSignature> verify(File installer, String expectedPublisher);
}

class PowerShellAuthenticodeVerifier implements InstallerSignatureVerifier {
  @override
  Future<InstallerSignature> verify(
    File installer,
    String expectedPublisher,
  ) async {
    if (expectedPublisher.trim().isEmpty) {
      return const InstallerSignature(
        valid: false,
        publisher: '',
        reason: 'Falta configurar CAPC_WINDOWS_UPDATE_PUBLISHER.',
      );
    }
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final executable = p.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final result = await Process.run(executable, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'AllSigned',
      '-Command',
      r'''$signature=Get-AuthenticodeSignature -LiteralPath $args[0]; [PSCustomObject]@{Status=$signature.Status.ToString();Publisher=if($signature.SignerCertificate){$signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)}else{''}} | ConvertTo-Json -Compress''',
      installer.path,
    ]).timeout(const Duration(seconds: 20));
    if (result.exitCode != 0) {
      return const InstallerSignature(
        valid: false,
        publisher: '',
        reason: 'Windows no pudo validar la firma del instalador.',
      );
    }
    try {
      final decoded = jsonDecode(result.stdout as String) as Map;
      final status = decoded['Status'] as String? ?? '';
      final publisher = decoded['Publisher'] as String? ?? '';
      final publisherMatches =
          publisher.toLowerCase() == expectedPublisher.trim().toLowerCase();
      return InstallerSignature(
        valid: status == 'Valid' && publisherMatches,
        publisher: publisher,
        reason: status != 'Valid'
            ? 'El instalador no tiene una firma Authenticode válida.'
            : !publisherMatches
            ? 'El editor del instalador no coincide con CAPC.'
            : null,
      );
    } catch (_) {
      return const InstallerSignature(
        valid: false,
        publisher: '',
        reason: 'Windows devolvió una respuesta de firma inválida.',
      );
    }
  }
}

abstract interface class WindowsInstallerLauncher {
  Future<void> launch(File installer);
}

class InnoInstallerLauncher implements WindowsInstallerLauncher {
  @override
  Future<void> launch(File installer) async {
    await Process.start(installer.path, const [
      '/SP-',
      '/SILENT',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
    ], mode: ProcessStartMode.detached);
  }
}

class WindowsUpdateService extends UpdateService {
  WindowsUpdateService({
    required super.versionProvider,
    required this.configuration,
    required this.transport,
    required this.signatureVerifier,
    required this.launcher,
    required this.temporaryDirectory,
  });

  final WindowsUpdateConfiguration configuration;
  final UpdateTransport transport;
  final InstallerSignatureVerifier signatureVerifier;
  final WindowsInstallerLauncher launcher;
  final Future<Directory> Function() temporaryDirectory;

  @override
  UpdatePlatform get platform => UpdatePlatform.windows;

  @override
  Future<UpdateRelease?> checkForUpdate(
    AppVersion installed,
    UpdateChannel channel,
  ) async {
    if (channel != configuration.channel) {
      throw const UpdateException(
        'El canal configurado no coincide con el servicio de Windows.',
      );
    }
    final policy = UpdateSecurityPolicy(
      allowedHosts: configuration.allowedHosts,
    );
    policy.validate(configuration.manifestUri);
    final bytes = await transport.getBytes(
      configuration.manifestUri,
      maximumBytes: 256 * 1024,
    );
    final release = UpdateRelease.decodeWindows(utf8.decode(bytes));
    if (release.channel != channel) {
      throw const UpdateException('El manifiesto pertenece a otro canal.');
    }
    final artifact = release.artifact!;
    policy.validate(artifact.url);
    if (!installed.isOlderThan(release.asVersion(installed.packageName))) {
      return null;
    }
    return release;
  }

  @override
  Future<PreparedUpdate> download(
    UpdateRelease release,
    AppVersion installed,
    void Function(double? progress) onProgress,
  ) async {
    _requireNewer(release, installed);
    final artifact = release.artifact;
    if (artifact == null) {
      throw const UpdateException('Falta el instalador publicado.');
    }
    UpdateSecurityPolicy(
      allowedHosts: configuration.allowedHosts,
    ).validate(artifact.url);
    final root = await temporaryDirectory();
    final directory = await root.createTemp('capc-update-');
    final partial = File(p.join(directory.path, 'CAPC-update.part'));
    final completed = File(
      p.join(directory.path, 'CAPC-MULTISERVICIO-Setup.exe'),
    );
    try {
      final received = await transport.download(
        artifact.url,
        partial,
        maximumBytes: artifact.sizeBytes,
        onProgress: (value, _) => onProgress(value / artifact.sizeBytes),
      );
      if (received != artifact.sizeBytes ||
          await partial.length() != artifact.sizeBytes) {
        throw const UpdateException(
          'El tamaño descargado no coincide con el publicado.',
        );
      }
      final hash = await _sha256(partial);
      if (hash != artifact.sha256.toUpperCase()) {
        throw const UpdateException('El SHA-256 del instalador no coincide.');
      }
      await partial.rename(completed.path);
      final signature = await signatureVerifier.verify(
        completed,
        configuration.expectedPublisher,
      );
      if (!signature.valid) {
        throw UpdateException(
          signature.reason ?? 'La firma del instalador no es válida.',
        );
      }
      onProgress(1);
      return PreparedUpdate(release: release, path: completed.path);
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  @override
  Future<void> installPrepared(
    PreparedUpdate prepared,
    AppVersion installed, {
    required Future<void> Function() createBackup,
    required Future<void> Function() closeApplicationData,
  }) async {
    _requireNewer(prepared.release, installed);
    final installer = File(prepared.path);
    final artifact = prepared.release.artifact!;
    if (!await installer.exists() ||
        await installer.length() != artifact.sizeBytes) {
      throw const UpdateException('El instalador preparado ya no es válido.');
    }
    if (await _sha256(installer) != artifact.sha256.toUpperCase()) {
      throw const UpdateException(
        'El instalador cambió después de descargarse.',
      );
    }
    final signature = await signatureVerifier.verify(
      installer,
      configuration.expectedPublisher,
    );
    if (!signature.valid) {
      throw UpdateException(
        signature.reason ?? 'La firma del instalador no es válida.',
      );
    }
    await createBackup();
    await launcher.launch(installer);
    await closeApplicationData();
  }

  void _requireNewer(UpdateRelease release, AppVersion installed) {
    if (!installed.isOlderThan(release.asVersion(installed.packageName))) {
      throw const UpdateException(
        'Nunca se instala una versión igual o inferior.',
      );
    }
  }

  Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toUpperCase();
  }
}

abstract interface class AndroidUpdateGateway {
  Stream<play.InstallStatus> get installStatus;
  Future<play.AppUpdateInfo> check();
  Future<play.AppUpdateResult> startFlexible();
  Future<play.AppUpdateResult> startImmediate();
  Future<void> completeFlexible();
  Future<void> openStore();
}

class PlayCoreUpdateGateway implements AndroidUpdateGateway {
  static const _channel = MethodChannel('co.capc.multiservicio/platform');

  @override
  Stream<play.InstallStatus> get installStatus =>
      play.InAppUpdate.installUpdateListener;

  @override
  Future<play.AppUpdateInfo> check() => play.InAppUpdate.checkForUpdate();

  @override
  Future<play.AppUpdateResult> startFlexible() =>
      play.InAppUpdate.startFlexibleUpdate();

  @override
  Future<play.AppUpdateResult> startImmediate() =>
      play.InAppUpdate.performImmediateUpdate();

  @override
  Future<void> completeFlexible() => play.InAppUpdate.completeFlexibleUpdate();

  @override
  Future<void> openStore() => _channel.invokeMethod<void>('openPlayStore');
}

class AndroidUpdateService extends UpdateService {
  AndroidUpdateService({required super.versionProvider, required this.gateway});
  final AndroidUpdateGateway gateway;
  play.AppUpdateInfo? _lastInfo;

  @override
  UpdatePlatform get platform => UpdatePlatform.android;

  @override
  Stream<PlatformUpdateEvent> get platformProgress => gateway.installStatus.map(
    (status) => switch (status) {
      play.InstallStatus.downloaded => const PlatformUpdateEvent(
        PlatformUpdatePhase.downloaded,
        progress: 1,
      ),
      play.InstallStatus.installing => const PlatformUpdateEvent(
        PlatformUpdatePhase.installing,
      ),
      play.InstallStatus.failed => const PlatformUpdateEvent(
        PlatformUpdatePhase.failed,
      ),
      play.InstallStatus.canceled => const PlatformUpdateEvent(
        PlatformUpdatePhase.canceled,
      ),
      _ => const PlatformUpdateEvent(PlatformUpdatePhase.downloading),
    },
  );

  @override
  Future<UpdateRelease?> checkForUpdate(
    AppVersion installed,
    UpdateChannel channel,
  ) async {
    try {
      final info = await gateway.check();
      _lastInfo = info;
      final available =
          info.updateAvailability == play.UpdateAvailability.updateAvailable ||
          info.updateAvailability ==
              play.UpdateAvailability.developerTriggeredUpdateInProgress;
      final build = info.availableVersionCode;
      if (!available || build == null || build <= installed.buildNumber) {
        return null;
      }
      return UpdateRelease(
        platform: 'android-play',
        channel: channel,
        versionName: installed.versionName,
        buildNumber: build,
        publishedAt: null,
        mandatory: info.updatePriority >= 4,
        minimumSupportedBuild: installed.buildNumber,
        releaseNotes: const [
          'Actualización descargada e instalada exclusivamente por Google Play.',
        ],
      );
    } on SocketException {
      throw const UpdateException(
        'No hay conexión con Google Play.',
        offline: true,
      );
    } on PlatformException catch (error) {
      throw UpdateException(
        error.code == 'TASK_FAILURE'
            ? 'Google Play no pudo comprobar actualizaciones. La app puede seguir usándose offline.'
            : 'La actualización interna de Google Play no está disponible.',
        offline: error.code == 'TASK_FAILURE',
      );
    }
  }

  @override
  Future<void> startAndroidUpdate(UpdateRelease release) async {
    final info = _lastInfo ?? await gateway.check();
    final mandatory = release.mandatory || info.updatePriority >= 4;
    if (mandatory && info.immediateUpdateAllowed) {
      final result = await gateway.startImmediate();
      if (result == play.AppUpdateResult.inAppUpdateFailed) {
        throw const UpdateException(
          'Google Play no pudo iniciar la actualización inmediata.',
        );
      }
      return;
    }
    if (!info.flexibleUpdateAllowed) {
      throw const UpdateException(
        'Google Play no permite la actualización flexible en este momento.',
      );
    }
    final result = await gateway.startFlexible();
    if (result != play.AppUpdateResult.success) {
      throw const UpdateException(
        'La actualización de Google Play fue cancelada o falló.',
      );
    }
  }

  @override
  Future<void> completeAndroidUpdate() => gateway.completeFlexible();

  @override
  Future<void> openStoreListing() => gateway.openStore();
}
