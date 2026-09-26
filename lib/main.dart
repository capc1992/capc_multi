import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/repository.dart';
import 'ui/capc_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? databasePath;
  try {
    // An explicit directory lets integration tests avoid the user's real data.
    final override = Platform.environment['CAPC_DATA_DIR'];
    final base = override == null || override.trim().isEmpty
        ? await getApplicationSupportDirectory()
        : Directory(override);
    final directory = Directory(p.join(base.path, 'CAPC', 'local'));
    await directory.create(recursive: true);
    databasePath = p.join(directory.path, 'capc.sqlite3');
    final repository = await CapcRepository.open(databasePath);
    runApp(CapcApp(repository: repository));
  } catch (error) {
    runApp(
      _StartupFailure(message: error.toString(), databasePath: databasePath),
    );
  }
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
      runApp(CapcApp(repository: repository));
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
                              final file = await openFile(
                                acceptedTypeGroups: const [
                                  XTypeGroup(
                                    label: 'Respaldo SQLite',
                                    extensions: ['sqlite3', 'db', 'sqlite'],
                                  ),
                                ],
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
