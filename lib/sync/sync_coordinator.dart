import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/repository.dart';
import 'remote_identity.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

class SyncCoordinator extends ChangeNotifier with WidgetsBindingObserver {
  SyncCoordinator({
    required this.repository,
    required this.identity,
    this.retryInterval = const Duration(minutes: 1),
    SyncEngine? engine,
  }) : configuration = SyncConfiguration(
         baseUri: identity.configuration.baseUri,
         tokenProvider: identity.accessToken,
       ) {
    _engine =
        engine ??
        SyncEngine(repository: repository, configuration: configuration);
  }

  final CapcRepository repository;
  final RemoteIdentityController identity;
  final Duration retryInterval;
  final SyncConfiguration configuration;
  late final SyncEngine _engine;
  Timer? _timer;
  SyncStatusSnapshot? _snapshot;
  bool _initialized = false;
  bool _running = false;
  bool _disposed = false;

  bool get enabled => configuration.enabled;
  bool get running => _running;
  SyncStatusSnapshot? get snapshot => _snapshot;

  Future<void> initialize() async {
    if (_initialized) {
      await refreshStatus();
      return;
    }
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    await refreshStatus();
    _timer = Timer.periodic(retryInterval, (_) => _retrySilently());
    _retrySilently();
  }

  Future<void> refreshStatus() async {
    _snapshot = await repository.syncStatus();
    if (!_disposed) notifyListeners();
  }

  Future<SyncRunResult?> syncNow({bool silent = false}) async {
    if (!enabled || !identity.connected || _running) {
      await refreshStatus();
      return null;
    }
    _running = true;
    if (!_disposed) notifyListeners();
    try {
      final result = await _engine.runOnce(forceRetry: !silent);
      await refreshStatus();
      return result;
    } catch (_) {
      await refreshStatus();
      if (!silent) rethrow;
      return null;
    } finally {
      _running = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _retrySilently() {
    if (!_running && identity.connected) {
      unawaited(syncNow(silent: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _retrySilently();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_initialized) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
