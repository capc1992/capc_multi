import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../sync/remote_identity.dart';
import 'ui_shared.dart';

class RemoteIdentityPage extends StatefulWidget {
  const RemoteIdentityPage({super.key, required this.controller});
  final RemoteIdentityController controller;

  @override
  State<RemoteIdentityPage> createState() => _RemoteIdentityPageState();
}

class _RemoteIdentityPageState extends State<RemoteIdentityPage> {
  final _businessName = TextEditingController(text: 'CAPC MULTISERVICIO');
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _linkCode = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _success;
  List<RemoteDevice> _devices = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _businessName.dispose();
    _email.dispose();
    _password.dispose();
    _linkCode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await action();
      _password.clear();
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    await widget.controller.initialize();
    if (widget.controller.connected) {
      try {
        _devices = await widget.controller.listDevices();
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Conexión remota')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
          ],
          if (!widget.controller.enabled)
            _disabled()
          else if (!widget.controller.connected)
            _authentication()
          else
            _connected(),
          if (_success != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                _success!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _privacyAndDeletionLinks(),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _disabled() => _card(
    title: 'Sin configuración remota',
    icon: Icons.cloud_off_outlined,
    children: [
      const Text(
        'La aplicación continúa completamente offline. Esta compilación no abrirá conexiones ni guardará credenciales remotas.',
      ),
      const SizedBox(height: 12),
      Text(
        'Para una compilación de prueba, define CAPC_SYNC_URL. Dirección preparada, aún no activada: ${RemoteIdentityController.recommendedProductionUri}',
      ),
    ],
  );

  Widget _authentication() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _card(
        title: 'Conectar este negocio',
        icon: Icons.add_business_outlined,
        children: [
          const Text(
            'Crea credenciales remotas independientes. La contraseña local nunca se envía.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _businessName,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Nombre del negocio'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Correo remoto'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Nueva contraseña remota',
              helperText:
                  'Mínimo 12 caracteres; distinta de la contraseña local.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.controller.connectBusiness(
                      businessName: _businessName.text,
                      email: _email.text,
                      password: _password.text,
                    ),
                  ),
            icon: const Icon(Icons.cloud_done_outlined),
            label: const Text('Conectar negocio'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _card(
        title: 'Iniciar sesión remoto',
        icon: Icons.login_outlined,
        children: [
          const Text(
            'Úsalo en un dispositivo que ya fue autorizado para este negocio.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _showLogin,
            icon: const Icon(Icons.person_outline),
            label: const Text('Abrir inicio de sesión'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _card(
        title: 'Vincular este dispositivo',
        icon: Icons.devices_other_outlined,
        children: [
          const Text(
            'Introduce el código temporal generado en un equipo autorizado. Solo se aceptan instalaciones nuevas o sin movimientos.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _linkCode,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Código de vinculación',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy || _linkCode.text.trim().isEmpty
                ? null
                : () =>
                      _run(() => widget.controller.linkDevice(_linkCode.text)),
            icon: const Icon(Icons.link),
            label: const Text('Vincular dispositivo'),
          ),
        ],
      ),
    ],
  );

  Widget _connected() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _card(
        title: 'Negocio conectado',
        icon: Icons.verified_user_outlined,
        children: [
          SelectableText('Negocio: ${widget.controller.session!.businessId}'),
          const SizedBox(height: 8),
          SelectableText('Dispositivo: ${widget.controller.session!.deviceId}'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _createCode,
                icon: const Icon(Icons.add_link),
                label: const Text('Generar código temporal'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(widget.controller.logout),
                icon: const Icon(Icons.logout),
                label: const Text('Cerrar sesión remota'),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 16),
      _card(
        title: 'Dispositivos autorizados',
        icon: Icons.devices_outlined,
        children: [
          if (_devices.isEmpty)
            const Text('No se pudieron cargar dispositivos.')
          else
            ..._devices.map(_deviceTile),
        ],
      ),
      const SizedBox(height: 16),
      _card(
        title: 'Eliminar cuenta remota',
        icon: Icons.delete_forever_outlined,
        children: [
          const Text(
            'Elimina definitivamente la identidad, los dispositivos y los datos sincronizados del servidor. La base local de este dispositivo se conserva.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Antes de continuar, crea un respaldo si necesitas conservar una copia independiente.',
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              label: 'Eliminar definitivamente la cuenta remota',
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  minimumSize: const Size(48, 48),
                ),
                onPressed: _busy ? null : _confirmDeleteAccount,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Eliminar cuenta remota'),
              ),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _privacyAndDeletionLinks() => _card(
    title: 'Privacidad y datos',
    icon: Icons.privacy_tip_outlined,
    children: [
      const Text(
        'Consulta cómo se manejan los datos o solicita la eliminación desde la web, incluso si ya no tienes la aplicación instalada.',
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(widget.controller.openPrivacyPolicy),
            icon: const Icon(Icons.policy_outlined),
            label: const Text('Política de privacidad'),
          ),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(widget.controller.openExternalDeletion),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Eliminar desde la web'),
          ),
        ],
      ),
    ],
  );

  Widget _deviceTile(RemoteDevice device) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      device.platform.toLowerCase().contains('android')
          ? Icons.phone_android
          : Icons.computer,
    ),
    title: Text(device.name),
    subtitle: Text(
      [
        device.platform,
        if (device.current) 'Este dispositivo',
        if (device.revokedAt != null) 'Revocado',
        if (device.lastSeenAt != null)
          'Último acceso ${DateFormat('dd/MM/yyyy HH:mm').format(device.lastSeenAt!.toLocal())}',
      ].join(' · '),
    ),
    trailing: device.revokedAt != null
        ? null
        : IconButton(
            tooltip: 'Revocar ${device.name}',
            onPressed: _busy ? null : () => _confirmRevoke(device),
            icon: const Icon(Icons.block_outlined),
          ),
  );

  Future<void> _showLogin() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Iniciar sesión remoto'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Correo remoto'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: (_) => Navigator.pop(context, true),
                decoration: const InputDecoration(
                  labelText: 'Contraseña remota',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ingresar'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _run(
        () => widget.controller.login(
          email: _email.text,
          password: _password.text,
        ),
      );
    }
  }

  Future<void> _createCode() async {
    await _run(() async {
      final link = await widget.controller.createLinkCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Código de vinculación'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Es temporal, de un solo uso y no debe enviarse por canales públicos.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                link.code,
                style: Theme.of(
                  context,
                ).textTheme.headlineMedium?.copyWith(letterSpacing: 3),
              ),
              const SizedBox(height: 12),
              Text(
                'Vence a las ${DateFormat('HH:mm').format(link.expiresAt.toLocal())}.',
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Listo'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _confirmRevoke(RemoteDevice device) async {
    final confirmed = await confirmAction(
      context,
      'Revocar dispositivo',
      'Se cerrarán sus sesiones y no podrá sincronizar hasta volver a vincularse.',
      action: 'Revocar',
    );
    if (confirmed) await _run(() => widget.controller.revokeDevice(device.id));
  }

  Future<void> _confirmDeleteAccount() async {
    final credentials = await showDialog<_DeleteAccountCredentials>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (credentials == null) return;
    await _run(() async {
      await widget.controller.deleteAccount(
        email: credentials.email,
        password: credentials.password,
      );
      if (mounted) {
        setState(() {
          _devices = const [];
          _success =
              'La cuenta remota y sus datos sincronizados fueron eliminados. Los datos locales permanecen en este dispositivo.';
        });
      }
    });
  }

  Widget _card({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );
}

class _DeleteAccountCredentials {
  const _DeleteAccountCredentials(this.email, this.password);
  final String email;
  final String password;
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: Icon(
      Icons.warning_amber_rounded,
      color: Theme.of(context).colorScheme.error,
      size: 36,
    ),
    title: const Text('Eliminar cuenta remota'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Se borrarán permanentemente la cuenta, sesiones, dispositivos y datos sincronizados del servidor. La base SQLite local permanecerá en este dispositivo.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Correo remoto'),
                validator: (value) =>
                    value == null ||
                        !value.contains('@') ||
                        value.trim().length < 5
                    ? 'Escribe el correo de la cuenta remota.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Contraseña remota',
                ),
                validator: (value) => value == null || value.isEmpty
                    ? 'Escribe la contraseña remota.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirmation,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Escribe ELIMINAR para confirmar',
                ),
                validator: (value) => value?.trim() == 'ELIMINAR'
                    ? null
                    : 'Escribe exactamente ELIMINAR.',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Conservar cuenta'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(
              context,
              _DeleteAccountCredentials(_email.text.trim(), _password.text),
            );
          }
        },
        child: const Text('Eliminar definitivamente'),
      ),
    ],
  );
}
