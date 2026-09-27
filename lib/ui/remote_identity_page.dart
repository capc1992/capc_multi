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
