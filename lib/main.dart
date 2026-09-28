import 'dart:async';

import 'package:flutter/material.dart';

import 'data/repository.dart';
import 'platform/platform_services.dart';
import 'services/backup_transfer.dart';
import 'sync/remote_identity.dart';
import 'sync/sync_coordinator.dart';
import 'ui/capc_app.dart';
import 'update/update_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? databasePath;
  try {
    databasePath = await appPlatform.databasePath();
    final repository = await CapcRepository.open(databasePath);
    final remoteIdentity = RemoteIdentityController(repository: repository);
    await remoteIdentity.initialize();
    final syncCoordinator = SyncCoordinator(
      repository: repository,
      identity: remoteIdentity,
    );
    await syncCoordinator.initialize();
    _runCapc(
      repository,
      remoteIdentity: remoteIdentity,
      syncCoordinator: syncCoordinator,
    );
  } catch (error) {
    runApp(
      _StartupFailure(message: error.toString(), databasePath: databasePath),
    );
  }
}

void _runCapc(
  CapcRepository repository, {
  RemoteIdentityController? remoteIdentity,
  SyncCoordinator? syncCoordinator,
}) {
  final updates = UpdateRuntime.create(databasePath: repository.databasePath);
  runApp(
    CapcApp(
      repository: repository,
      remoteIdentity: remoteIdentity,
      syncCoordinator: syncCoordinator,
      updateController: updates,
    ),
  );
  unawaited(updates.initialize());
}

class _StartupFailure extends StatefulWidget {
  const _StartupFailure({required this.message, this.databasePath});
  final String message;
  final String? databasePath;

  @override
  State<_StartupFailure> createState() => _StartupFailureState();
}

class _StartupFailureState extends State<_StartupFailure> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _backupPath;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    if (_busy || _backupPath == null || widget.databasePath == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await CapcRepository.recoverDatabase(
        databasePath: widget.databasePath!,
        backupPath: _backupPath!,
        username: _username.text.trim(),
        password: _password.text,
      );
      _password.clear();
      final repository = await CapcRepository.open(widget.databasePath!);
      final remoteIdentity = RemoteIdentityController(repository: repository);
      await remoteIdentity.initialize();
      final syncCoordinator = SyncCoordinator(
        repository: repository,
        identity: remoteIdentity,
      );
      await syncCoordinator.initialize();
      _runCapc(
        repository,
        remoteIdentity: remoteIdentity,
        syncCoordinator: syncCoordinator,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'CAPC MULTISERVICIO',
    theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.storage_outlined, size: 40),
                  const SizedBox(height: 20),
                  const Text(
                    'No se pudo abrir la base de datos',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Tus archivos no se han borrado. Revisa los permisos de la '
                    'carpeta y el espacio disponible, y vuelve a abrir CAPC.',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(widget.message),
                  if (widget.databasePath != null) ...[
                    const SizedBox(height: 12),
                    SelectableText('Ubicación: ${widget.databasePath}'),
                    const Divider(height: 32),
                    const Text(
                      'Recuperar desde un respaldo',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Se validará la copia y se conservarán los archivos actuales antes de reemplazarlos. Usa la cuenta propietaria y la contraseña vigentes en el respaldo.',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              final file = await appPlatform.openDocument(
                                BackupTransfer.backupType,
                              );
                              if (file != null && mounted) {
                                setState(() => _backupPath = file.path);
                              }
                            },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Seleccionar respaldo'),
                    ),
                    if (_backupPath != null) SelectableText(_backupPath!),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _username,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Usuario propietario del respaldo',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña del respaldo',
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy || _backupPath == null ? null : _recover,
                      icon: const Icon(Icons.restore),
                      label: Text(
                        _busy
                            ? 'Validando y recuperando…'
                            : 'Restaurar y abrir CAPC',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
