import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'update_models.dart';
import 'update_service.dart';
import 'update_store.dart';

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.service,
    required this.store,
    required this.channel,
    DateTime Function()? now,
    Future<void> Function()? terminateApplication,
  }) : _now = now ?? DateTime.now,
       _terminateApplication = terminateApplication ?? _exitApplication;

  static const automaticInterval = Duration(hours: 24);

  final UpdateService service;
  final UpdateCheckStore store;
  final UpdateChannel channel;
  final DateTime Function() _now;
  final Future<void> Function() _terminateApplication;

  AppVersion? installedVersion;
  UpdateRelease? release;
  PreparedUpdate? prepared;
  UpdateStatus status = UpdateStatus.idle;
  String message = 'Listo para comprobar actualizaciones.';
  double? progress;
  DateTime? lastCheckedAt;
  StreamSubscription<PlatformUpdateEvent>? _platformSubscription;
  bool _initialized = false;

  UpdatePlatform get platform => service.platform;
  bool get busy =>
      status == UpdateStatus.checking || status == UpdateStatus.downloading;
  bool get mandatory =>
      release != null &&
      installedVersion != null &&
      release!.isMandatoryFor(installedVersion!);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _platformSubscription = service.platformProgress.listen(
      _handlePlatformEvent,
    );
    try {
      installedVersion = await service.currentVersion();
      lastCheckedAt = await store.readLastCheck();
      notifyListeners();
      if (_automaticCheckIsDue()) unawaited(check(manual: false));
    } catch (_) {
      status = UpdateStatus.error;
      message =
          'No se pudo leer la versión instalada. La aplicación puede seguir usándose.';
      notifyListeners();
    }
  }

  bool _automaticCheckIsDue() {
    final last = lastCheckedAt;
    if (last == null) return true;
    final elapsed = _now().toUtc().difference(last);
    return elapsed.isNegative || elapsed >= automaticInterval;
  }

  Future<void> check({bool manual = true}) async {
    if (busy) return;
    final installed = installedVersion;
    if (installed == null) {
      if (!_initialized) await initialize();
      if (installedVersion == null) return;
    }
    if (!manual && !_automaticCheckIsDue()) return;
    status = UpdateStatus.checking;
    message = 'Buscando actualización…';
    progress = null;
    notifyListeners();
    final attemptedAt = _now().toUtc();
    try {
      await store.writeLastCheck(attemptedAt);
      lastCheckedAt = attemptedAt;
      final found = await service.checkForUpdate(installedVersion!, channel);
      release = found;
      prepared = null;
      if (found == null) {
        status = UpdateStatus.upToDate;
        message = 'Tienes la última versión.';
      } else {
        status = UpdateStatus.available;
        message = found.isMandatoryFor(installedVersion!)
            ? 'Hay una actualización obligatoria disponible.'
            : 'Hay una nueva versión disponible.';
      }
    } on UpdateException catch (error) {
      status = error.offline ? UpdateStatus.offline : UpdateStatus.error;
      message = error.message;
    } catch (_) {
      status = UpdateStatus.error;
      message =
          'No se pudo comprobar la actualización. La aplicación puede seguir usándose.';
    }
    notifyListeners();
  }

  Future<void> downloadWindows() async {
    if (platform != UpdatePlatform.windows ||
        release == null ||
        installedVersion == null) {
      return;
    }
    status = UpdateStatus.downloading;
    message = 'Descargando y verificando el instalador…';
    progress = 0;
    notifyListeners();
    try {
      prepared = await service.download(release!, installedVersion!, (value) {
        progress = value?.clamp(0, 1);
        notifyListeners();
      });
      progress = 1;
      status = UpdateStatus.readyToInstall;
      message = 'Instalador verificado y listo para instalar.';
    } on UpdateException catch (error) {
      prepared = null;
      progress = null;
      status = error.offline ? UpdateStatus.offline : UpdateStatus.error;
      message = error.message;
    } catch (_) {
      prepared = null;
      progress = null;
      status = UpdateStatus.error;
      message =
          'No se pudo preparar el instalador. La descarga incompleta fue eliminada.';
    }
    notifyListeners();
  }

  Future<void> installWindows({
    required Future<void> Function() createBackup,
    required Future<void> Function() closeApplicationData,
  }) async {
    final ready = prepared;
    final installed = installedVersion;
    if (platform != UpdatePlatform.windows ||
        ready == null ||
        installed == null) {
      return;
    }
    try {
      await service.installPrepared(
        ready,
        installed,
        createBackup: createBackup,
        closeApplicationData: closeApplicationData,
      );
      await _terminateApplication();
    } on UpdateException catch (error) {
      status = UpdateStatus.error;
      message = error.message;
      notifyListeners();
    } catch (_) {
      status = UpdateStatus.error;
      message =
          'No se pudo abrir el instalador. La aplicación continúa disponible.';
      notifyListeners();
    }
  }

  Future<void> startAndroidUpdate() async {
    if (platform != UpdatePlatform.android || release == null) return;
    status = UpdateStatus.downloading;
    message = mandatory
        ? 'Google Play está iniciando la actualización obligatoria…'
        : 'Google Play está preparando la actualización flexible…';
    progress = null;
    notifyListeners();
    try {
      await service.startAndroidUpdate(release!);
    } on UpdateException catch (error) {
      status = error.offline ? UpdateStatus.offline : UpdateStatus.error;
      message = error.message;
      notifyListeners();
    } catch (_) {
      status = UpdateStatus.error;
      message = 'Google Play no pudo iniciar la actualización.';
      notifyListeners();
    }
  }

  Future<void> completeAndroidUpdate() async {
    try {
      await service.completeAndroidUpdate();
    } catch (_) {
      status = UpdateStatus.error;
      message =
          'Google Play no pudo reiniciar para completar la actualización.';
      notifyListeners();
    }
  }

  Future<void> openStore() async {
    try {
      await service.openStoreListing();
    } catch (_) {
      status = UpdateStatus.error;
      message = 'No se pudo abrir la ficha de CAPC en Google Play.';
      notifyListeners();
    }
  }

  void _handlePlatformEvent(PlatformUpdateEvent event) {
    switch (event.phase) {
      case PlatformUpdatePhase.downloading:
        status = UpdateStatus.downloading;
        message = 'Google Play está descargando la actualización…';
        progress = event.progress;
      case PlatformUpdatePhase.downloaded:
        status = UpdateStatus.readyToInstall;
        message = 'La actualización está lista. Reinicia para instalarla.';
        progress = 1;
      case PlatformUpdatePhase.installing:
        status = UpdateStatus.downloading;
        message = 'Google Play está instalando la actualización…';
      case PlatformUpdatePhase.failed:
        status = UpdateStatus.error;
        message = 'Google Play no pudo descargar la actualización.';
        progress = null;
      case PlatformUpdatePhase.canceled:
        status = UpdateStatus.available;
        message = 'La actualización fue cancelada. Puedes intentarlo de nuevo.';
        progress = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _platformSubscription?.cancel();
    super.dispose();
  }

  static Future<void> _exitApplication() async => exit(0);
}
