import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../platform/platform_services.dart';

const _recoveryTextType = DocumentType(
  label: 'Archivo de texto',
  extensions: ['txt'],
  mimeType: 'text/plain',
);

class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage({super.key, required this.repository});

  final CapcRepository repository;

  @override
  State<AccountSecurityPage> createState() => _AccountSecurityState();
}

class _AccountSecurityState extends State<AccountSecurityPage> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool? _configured;
  bool _busy = false;
  String? _error;
  String? _code;
  late final String _username;

  @override
  void initState() {
    super.initState();
    _username = widget.repository.currentUser?.username ?? '';
    _load();
  }

  Future<void> _load() async {
    try {
      final configured = await widget.repository.recoveryCodeConfigured();
      if (mounted) {
        setState(() {
          _configured = configured;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await widget.repository.generateRecoveryCode(
        currentPassword: _password.text,
      );
      if (mounted) {
        setState(() {
          _code = code;
          _configured = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && _code == null,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Seguridad de mi cuenta'),
        automaticallyImplyLeading: !_busy && _code == null,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _code != null
                      ? RecoveryCodePanel(
                          code: _code!,
                          username: _username,
                          onContinue: () {
                            setState(() => _code = null);
                            Navigator.of(context).pop();
                          },
                        )
                      : Form(
                          key: _form,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Recupera el acceso a tu cuenta',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 12),
                              Text('Usuario: $_username'),
                              const SizedBox(height: 12),
                              const Text(
                                'El código de recuperación te permite crear una nueva contraseña desde «Olvidé mi contraseña», sin internet. Guárdalo en un lugar privado y seguro.',
                              ),
                              const SizedBox(height: 16),
                              if (_configured == null && _error == null)
                                const LinearProgressIndicator(),
                              if (_configured != null &&
                                  widget.repository.isAuthenticated) ...[
                                Text(
                                  _configured!
                                      ? 'Ya tienes un código activo. Al renovarlo, el anterior dejará de funcionar.'
                                      : 'Aún no tienes un código de recuperación activo.',
                                ),
                                const SizedBox(height: 24),
                                TextFormField(
                                  controller: _password,
                                  enabled: !_busy,
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: const InputDecoration(
                                    labelText: 'Contraseña actual',
                                  ),
                                  validator: (value) =>
                                      value == null || value.isEmpty
                                      ? 'Escribe tu contraseña actual.'
                                      : null,
                                  onFieldSubmitted: (_) => _generate(),
                                ),
                                const SizedBox(height: 20),
                              ],
                              if (_error != null) ...[
                                AccountError(_error!),
                                const SizedBox(height: 16),
                              ],
                              if (!widget.repository.isAuthenticated) ...[
                                const Text(
                                  'La sesión terminó. Vuelve a ingresar para administrar tu cuenta.',
                                ),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Volver al ingreso'),
                                ),
                              ] else if (_configured == null && _error != null)
                                OutlinedButton(
                                  onPressed: _load,
                                  child: const Text('Volver a intentar'),
                                ),
                              if (_configured != null &&
                                  widget.repository.isAuthenticated)
                                FilledButton.icon(
                                  onPressed: _busy ? null : _generate,
                                  icon: const Icon(Icons.key_outlined),
                                  label: Text(
                                    _busy
                                        ? 'Generando código…'
                                        : _configured!
                                        ? 'Renovar código de recuperación'
                                        : 'Generar código de recuperación',
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Holds the only plaintext copy shown to the user, until they leave this step.
class RecoveryCodePanel extends StatefulWidget {
  const RecoveryCodePanel({
    super.key,
    required this.code,
    required this.username,
    required this.onContinue,
  });

  final String code;
  final String username;
  final VoidCallback onContinue;

  @override
  State<RecoveryCodePanel> createState() => _RecoveryCodePanelState();
}

class _RecoveryCodePanelState extends State<RecoveryCodePanel> {
  bool _saved = false;
  bool _busy = false;
  String? _error;
  String? _notice;

  Future<void> _export({required bool copy}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      if (copy) {
        await Clipboard.setData(ClipboardData(text: widget.code));
        if (mounted) {
          setState(
            () => _notice = 'Código copiado. Guárdalo en un lugar seguro.',
          );
        }
      } else {
        final content =
            'CAPC MULTISERVICIO — Recuperación de acceso\n'
            'Usuario: ${widget.username}\n'
            'Código: ${widget.code}\n\n'
            'Guarda este archivo en un lugar privado y seguro.\n'
            'Este código permite cambiar tu contraseña y se puede usar una sola vez.\n'
            'En la pantalla de ingreso, elige «Olvidé mi contraseña».\n'
            'Después de usarlo, genera un nuevo código en «Seguridad de mi cuenta».\n';
        final saved = await appPlatform.saveDocument(
          buildBytes: () async => Uint8List.fromList(utf8.encode(content)),
          suggestedName: 'CAPC-codigo-recuperacion.txt',
          type: _recoveryTextType,
        );
        if (saved == null) return;
        if (mounted) {
          setState(
            () => _notice = 'Archivo guardado. Consérvalo en un lugar seguro.',
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = copy
              ? 'No se pudo copiar el código. Puedes seleccionarlo o guardarlo en un archivo.'
              : 'No se pudo guardar el archivo. Vuelve a intentarlo o copia el código.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Icon(
        Icons.key_outlined,
        size: 40,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 16),
      Text(
        'Guarda tu código de recuperación',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      Text('Usuario: ${widget.username}'),
      const SizedBox(height: 12),
      const Text(
        'Este código se muestra solo ahora. Permite cambiar tu contraseña y se puede usar una sola vez. No lo compartas.',
      ),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          widget.code.replaceAll('-', ' '),
          key: const Key('recovery-code'),
          style: const TextStyle(
            fontFamily: 'Roboto',
            letterSpacing: 1,
            fontSize: 18,
            height: 1.6,
          ),
        ),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _export(copy: true),
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copiar código'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _export(copy: false),
            icon: const Icon(Icons.save_alt_outlined),
            label: const Text('Guardar archivo TXT'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (_notice != null) Semantics(liveRegion: true, child: Text(_notice!)),
      if (_error != null) AccountError(_error!),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _saved,
        onChanged: _busy
            ? null
            : (value) => setState(() => _saved = value ?? false),
        title: const Text('Ya guardé mi código en un lugar seguro'),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _saved && !_busy ? widget.onContinue : null,
        child: const Text('Continuar'),
      ),
    ],
  );
}

class AccountError extends StatelessWidget {
  const AccountError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}
