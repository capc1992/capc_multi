import 'package:flutter/material.dart';
import '../data/repository.dart';
import '../sync/remote_identity.dart';
import 'account_security.dart';

class CapcAccessGate extends StatefulWidget {
  const CapcAccessGate({
    super.key,
    required this.repository,
    required this.remoteIdentity,
    required this.builder,
  });
  final CapcRepository repository;
  final RemoteIdentityController remoteIdentity;
  final Widget Function(VoidCallback onLogout) builder;
  @override
  State<CapcAccessGate> createState() => _AccessState();
}

class _AccessState extends State<CapcAccessGate> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController(),
      _confirmation = TextEditingController(),
      _recovery = TextEditingController();
  final _activation = TextEditingController();
  bool? _setup;
  bool _reconfigure = false;
  bool _recovering = false;
  bool _centralLogin = false;
  bool _centralActivation = false;
  bool _created = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  String? _createdCode;
  String _createdUsername = '';
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await widget.remoteIdentity.initialize();
    await _check();
  }

  Future<void> _check() async {
    try {
      final setup = await widget.repository.needsSetup();
      final reconfigure = await widget.repository.pendingOwnerReconfiguration();
      if (mounted) {
        setState(() {
          _setup = setup || reconfigure;
          _reconfigure = reconfigure;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _username,
      _password,
      _confirmation,
      _recovery,
      _activation,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_created) return _createdPage(context);
    if (widget.repository.isAuthenticated) {
      return widget.builder(() {
        _password.clear();
        _confirmation.clear();
        _recovery.clear();
        setState(() {
          _notice = null;
          _error = null;
          _recovering = false;
        });
        _check();
      });
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Form(
                    key: _form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF142638),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Image.asset(
                            'assets/branding/capc_logo_horizontal.png',
                            height: 76,
                            fit: BoxFit.contain,
                            semanticLabel: 'CAPC MULTISERVICIO',
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _reconfigure
                              ? 'Configura tu nuevo propietario'
                              : _setup == true
                              ? 'Crea el primer propietario'
                              : _recovering
                              ? 'Restablecer contraseña'
                              : _centralActivation
                              ? 'Activar usuario central'
                              : _centralLogin
                              ? 'Ingresar con usuario central'
                              : 'Ingresar a tu negocio',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _reconfigure
                              ? 'Elige el nombre, usuario y contraseña del nuevo propietario. Se conservarán tus ventas, clientes e inventario. Usa una contraseña de al menos 10 caracteres.'
                              : _setup == true
                              ? 'Esta cuenta administrará los usuarios, la caja y tus datos. Elige tu propia contraseña (mínimo 10 caracteres).'
                              : _recovering
                              ? 'Escribe tu usuario y el código de recuperación que guardaste para elegir una contraseña nueva. El código se puede usar una sola vez.'
                              : _centralActivation
                              ? 'Usa el código entregado por un administrador. Esta cuenta quedará preparada para trabajar offline durante el periodo autorizado.'
                              : _centralLogin
                              ? 'Se validará con el servidor. Sin internet podrás entrar con una autorización firmada vigente guardada en este dispositivo.'
                              : 'Usuarios locales. Puedes iniciar sesión sin internet.',
                        ),
                        const SizedBox(height: 22),
                        if (_setup == null && _error == null)
                          const LinearProgressIndicator(),
                        if (_setup == true) ...[
                          TextFormField(
                            controller: _name,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                              labelText: 'Nombre del propietario',
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Escribe tu nombre.'
                                : null,
                          ),
                          const SizedBox(height: 18),
                        ],
                        TextFormField(
                          key: const Key('access-username'),
                          controller: _username,
                          enabled: !_busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Usuario',
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Escribe tu usuario.'
                              : null,
                        ),
                        const SizedBox(height: 18),
                        if (_recovering) ...[
                          TextFormField(
                            controller: _recovery,
                            enabled: !_busy,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Código de recuperación',
                              helperText:
                                  'Puedes pegarlo con espacios o guiones.',
                              helperMaxLines: 3,
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Escribe tu código de recuperación.'
                                : null,
                          ),
                          const SizedBox(height: 18),
                        ],
                        if (_centralActivation) ...[
                          TextFormField(
                            controller: _activation,
                            enabled: !_busy,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                              labelText: 'Código de activación',
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Escribe el código de activación.'
                                : null,
                          ),
                          const SizedBox(height: 18),
                        ],
                        TextFormField(
                          key: const Key('access-password'),
                          controller: _password,
                          enabled: !_busy,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction:
                              _setup == true ||
                                  _recovering ||
                                  _centralActivation
                              ? TextInputAction.next
                              : TextInputAction.done,
                          decoration: InputDecoration(
                            labelText: _recovering || _centralActivation
                                ? 'Nueva contraseña'
                                : 'Contraseña',
                          ),
                          validator: (v) => v == null || v.isEmpty
                              ? 'Escribe tu contraseña.'
                              : (_setup == true || _recovering) && v.length < 10
                              ? 'Usa al menos 10 caracteres.'
                              : _centralActivation && v.length < 12
                              ? 'Usa al menos 12 caracteres.'
                              : null,
                          onFieldSubmitted: (_) {
                            if (!_busy &&
                                _setup == false &&
                                !_recovering &&
                                !_centralActivation) {
                              _submit();
                            }
                          },
                        ),
                        const SizedBox(height: 18),
                        if (_setup == true ||
                            _recovering ||
                            _centralActivation) ...[
                          TextFormField(
                            controller: _confirmation,
                            enabled: !_busy,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: 'Repetir contraseña',
                            ),
                            validator: (v) => v != _password.text
                                ? 'Las contraseñas no coinciden.'
                                : null,
                            onFieldSubmitted: (_) => _submit(),
                          ),
                          const SizedBox(height: 18),
                        ],
                        if (_notice != null) ...[
                          Semantics(liveRegion: true, child: Text(_notice!)),
                          const SizedBox(height: 18),
                        ],
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 18),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        FilledButton(
                          onPressed: _busy || _setup == null ? null : _submit,
                          child: Text(
                            _busy
                                ? 'Validando…'
                                : _setup == true
                                ? 'Crear propietario'
                                : _recovering
                                ? 'Guardar nueva contraseña'
                                : _centralActivation
                                ? 'Activar e ingresar'
                                : 'Ingresar',
                          ),
                        ),
                        if (_setup == false) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _busy || _centralLogin
                                ? null
                                : _toggleRecovery,
                            child: Text(
                              _recovering
                                  ? 'Volver al ingreso'
                                  : 'Olvidé mi contraseña',
                            ),
                          ),
                          if (widget.remoteIdentity.enabled) ...[
                            const Divider(),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _toggleCentralLogin,
                              icon: Icon(
                                _centralLogin
                                    ? Icons.person_outline
                                    : Icons.cloud_outlined,
                              ),
                              label: Text(
                                _centralLogin
                                    ? 'Usar usuario local'
                                    : 'Usar usuario central',
                              ),
                            ),
                            if (_centralLogin)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : _toggleCentralActivation,
                                child: Text(
                                  _centralActivation
                                      ? 'Ya activé mi usuario'
                                      : 'Activar usuario por primera vez',
                                ),
                              ),
                          ],
                        ],
                        if (_recovering) ...[
                          const SizedBox(height: 12),
                          const Text(
                            '¿No tienes un código? Se genera al crear la cuenta o desde «Seguridad de mi cuenta» con la sesión abierta. Pide al propietario que cambie tu contraseña en «Usuarios y auditoría». Si eres el único propietario y no puedes ingresar, solicita un restablecimiento local asistido.',
                          ),
                        ],
                      ],
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

  Future<void> _submit() async {
    if (_busy || _setup == null || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_setup!) {
        if (_reconfigure) {
          await widget.repository.completeOwnerReconfiguration(
            name: _name.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
          );
        } else {
          await widget.repository.setupOwner(
            name: _name.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
          );
        }
        // Account creation has committed. A recovery-code failure must never
        // return to setup or repeat the owner change.
        if (!mounted) return;
        setState(() {
          _created = true;
          _createdUsername =
              widget.repository.currentUser?.username ?? _username.text.trim();
        });
        try {
          final code = await widget.repository.generateRecoveryCode(
            currentPassword: _password.text,
          );
          if (mounted) setState(() => _createdCode = code);
        } catch (_) {
          if (mounted) {
            setState(
              () => _error =
                  'Tu cuenta ya está creada. No se pudo generar el código de recuperación. Puedes volver a intentarlo desde Seguridad de mi cuenta.',
            );
          }
        }
      } else if (_centralActivation) {
        await widget.remoteIdentity.activateAccessUser(
          username: _username.text.trim(),
          activationCode: _activation.text.trim(),
          password: _password.text,
        );
        await widget.remoteIdentity.loginAccessUser(
          username: _username.text.trim(),
          password: _password.text,
          authenticateLocally: true,
        );
      } else if (_centralLogin) {
        try {
          await widget.remoteIdentity.loginAccessUser(
            username: _username.text.trim(),
            password: _password.text,
            authenticateLocally: true,
          );
        } catch (_) {
          await widget.remoteIdentity.loginAccessUserOffline(
            username: _username.text.trim(),
            password: _password.text,
          );
        }
      } else if (_recovering) {
        await widget.repository.resetPasswordWithRecoveryCode(
          username: _username.text.trim(),
          recoveryCode: _recovery.text,
          newPassword: _password.text,
        );
        if (mounted) {
          setState(() {
            _recovering = false;
            _recovery.clear();
            _notice =
                'Contraseña restablecida. Ingresa con tu nueva contraseña y genera otro código en «Seguridad de mi cuenta».';
          });
        }
      } else {
        await widget.repository.login(_username.text.trim(), _password.text);
      }
      if (mounted) {
        setState(() {
          _password.clear();
          _confirmation.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleRecovery() {
    final username = _username.text;
    _form.currentState?.reset();
    setState(() {
      _username.text = username;
      _recovering = !_recovering;
      _password.clear();
      _confirmation.clear();
      _recovery.clear();
      _error = null;
      _notice = null;
    });
  }

  void _toggleCentralLogin() {
    _form.currentState?.reset();
    setState(() {
      _centralLogin = !_centralLogin;
      _centralActivation = false;
      _recovering = false;
      _activation.clear();
      _password.clear();
      _confirmation.clear();
      _error = null;
      _notice = null;
    });
  }

  void _toggleCentralActivation() {
    final username = _username.text;
    _form.currentState?.reset();
    setState(() {
      _username.text = username;
      _centralActivation = !_centralActivation;
      _activation.clear();
      _password.clear();
      _confirmation.clear();
      _error = null;
    });
  }

  Widget _createdPage(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: _createdCode != null
                    ? RecoveryCodePanel(
                        code: _createdCode!,
                        username: _createdUsername,
                        onContinue: () => setState(() {
                          _createdCode = null;
                          _created = false;
                          _setup = false;
                          _reconfigure = false;
                          _error = null;
                        }),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Tu cuenta está lista',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 16),
                          if (_busy) ...[
                            const Text('Preparando tu código de recuperación…'),
                            const SizedBox(height: 16),
                            const LinearProgressIndicator(),
                          ],
                          if (!_busy && _error != null) ...[
                            AccountError(_error!),
                            const SizedBox(height: 20),
                            if (widget.repository.isAuthenticated)
                              FilledButton(
                                onPressed: () async {
                                  await Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      builder: (_) => AccountSecurityPage(
                                        repository: widget.repository,
                                      ),
                                    ),
                                  );
                                },
                                child: const Text(
                                  'Abrir Seguridad de mi cuenta',
                                ),
                              ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: () => setState(() {
                                _created = false;
                                _setup = false;
                                _reconfigure = false;
                                _error = null;
                              }),
                              child: const Text('Continuar al negocio'),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
