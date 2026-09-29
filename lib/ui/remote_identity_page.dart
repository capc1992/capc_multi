import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../sync/remote_identity.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_models.dart';
import 'ui_shared.dart';

class RemoteIdentityPage extends StatefulWidget {
  const RemoteIdentityPage({
    super.key,
    required this.controller,
    this.syncCoordinator,
  });
  final RemoteIdentityController controller;
  final SyncCoordinator? syncCoordinator;

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
  List<RemotePermission> _permissions = const [];
  List<RemoteAccessRole> _roles = const [];
  List<RemoteAccessUser> _users = const [];

  @override
  void initState() {
    super.initState();
    widget.syncCoordinator?.addListener(_syncChanged);
    _reload();
  }

  @override
  void dispose() {
    widget.syncCoordinator?.removeListener(_syncChanged);
    _businessName.dispose();
    _email.dispose();
    _password.dispose();
    _linkCode.dispose();
    super.dispose();
  }

  void _syncChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool syncAfter = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await action();
      if (syncAfter) {
        await widget.syncCoordinator?.syncNow(silent: true);
      }
      _password.clear();
      await _reload();
      if (mounted && _success != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(_success!)));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(_error!)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    await widget.controller.initialize();
    if (widget.controller.connected) {
      try {
        if (_hasAny(const {'devices:read', 'devices:manage'})) {
          _devices = await widget.controller.listDevices();
        }
        if (_hasAny(const {
          'access:read',
          'roles.ver',
          'roles.crear',
          'roles.editar',
        })) {
          _permissions = await widget.controller.listAccessPermissions();
          _roles = await widget.controller.listAccessRoles();
        }
        if (_hasAny(const {
          'access:read',
          'usuarios.ver',
          'usuarios.crear',
          'usuarios.editar',
          'usuarios.eliminar',
        })) {
          _users = await widget.controller.listAccessUsers();
        }
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
    }
    await widget.syncCoordinator?.refreshStatus();
    if (mounted) setState(() {});
  }

  bool _hasAny(Set<String> permissions) {
    final granted = widget.controller.session?.permissions ?? const <String>[];
    return permissions.any(granted.contains);
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
          if (_success != null) ...[
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
            const SizedBox(height: 16),
          ],
          if (!widget.controller.enabled)
            _disabled()
          else if (!widget.controller.connected)
            _authentication()
          else
            _connected(),
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
                    syncAfter: true,
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
        title: 'Usuario del negocio',
        icon: Icons.badge_outlined,
        children: [
          const Text(
            'Activa una cuenta creada por un administrador o inicia sesión '
            'con tu usuario central en este dispositivo autorizado.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _showAccessActivation,
                icon: const Icon(Icons.key_outlined),
                label: const Text('Activar usuario'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _showAccessLogin,
                icon: const Icon(Icons.login_outlined),
                label: const Text('Ingresar como usuario'),
              ),
            ],
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
                : () => _run(
                    () => widget.controller.linkDevice(_linkCode.text),
                    syncAfter: true,
                  ),
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
              if (_hasAny(const {'devices:manage'}))
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
      if (widget.syncCoordinator != null) ...[
        _synchronizationCard(),
        const SizedBox(height: 16),
      ],
      if (_hasAny(const {'devices:read', 'devices:manage'})) ...[
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
      ],
      if (_hasAny(const {
        'access:read',
        'roles.ver',
        'roles.crear',
        'roles.editar',
        'usuarios.ver',
        'usuarios.crear',
        'usuarios.editar',
        'usuarios.eliminar',
      })) ...[
        _accessControlCard(),
        const SizedBox(height: 16),
      ],
      if (widget.controller.session!.userId == null)
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

  Widget _accessControlCard() {
    final canCreateRoles = _hasAny(const {'access:manage', 'roles.crear'});
    final canEditRoles = _hasAny(const {'access:manage', 'roles.editar'});
    final canCreateUsers = _hasAny(const {'access:manage', 'usuarios.crear'});
    final canEditUsers = _hasAny(const {
      'access:manage',
      'usuarios.editar',
      'usuarios.eliminar',
    });
    return _card(
      title: 'Usuarios, roles y permisos',
      icon: Icons.admin_panel_settings_outlined,
      children: [
        const Text(
          'La configuración se guarda en el servidor central. Los usuarios '
          'locales actuales continúan disponibles durante la migración.',
        ),
        if (canCreateRoles || canCreateUsers) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (canCreateRoles)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _editRole(),
                  icon: const Icon(Icons.add_moderator_outlined),
                  label: const Text('Crear rol'),
                ),
              if (canCreateUsers)
                FilledButton.icon(
                  onPressed: _busy || _roles.isEmpty
                      ? null
                      : () => _editAccessUser(),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Crear usuario'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Text('Roles', style: Theme.of(context).textTheme.titleMedium),
        if (_roles.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No hay roles disponibles.'),
          )
        else
          ..._roles.map(
            (role) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                role.system
                    ? Icons.verified_user_outlined
                    : Icons.badge_outlined,
              ),
              title: Text(role.name),
              subtitle: Text(
                '${role.roleType == 'administrator' ? 'Administrador' : 'Operativo'} · '
                '${role.permissions.length} permisos · versión ${role.version}',
              ),
              trailing: !canEditRoles || role.system
                  ? null
                  : IconButton(
                      tooltip: 'Editar ${role.name}',
                      onPressed: _busy ? null : () => _editRole(role),
                      icon: const Icon(Icons.edit_outlined),
                    ),
            ),
          ),
        const Divider(height: 32),
        Text(
          'Usuarios centrales',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (_users.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No hay usuarios centrales.'),
          )
        else
          ..._users.map(
            (user) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                user.active ? Icons.person_outline : Icons.person_off_outlined,
              ),
              title: Text(user.name),
              subtitle: Text(
                [
                  '@${user.username}',
                  user.roles.map((role) => role.name).join(', '),
                  user.activated ? 'Activado' : 'Pendiente de activación',
                  if (!user.active) 'Inactivo',
                ].join(' · '),
              ),
              trailing: !canEditUsers
                  ? null
                  : IconButton(
                      tooltip: 'Editar ${user.name}',
                      onPressed: _busy ? null : () => _editAccessUser(user),
                      icon: const Icon(Icons.edit_outlined),
                    ),
            ),
          ),
      ],
    );
  }

  Future<void> _editRole([RemoteAccessRole? role]) async {
    final name = TextEditingController(text: role?.name ?? '');
    final selected = <String>{...?role?.permissions};
    var roleType = role?.roleType ?? 'operational';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(role == null ? 'Crear rol' : 'Editar rol'),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Nombre del rol',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: roleType,
                  decoration: const InputDecoration(labelText: 'Tipo de rol'),
                  items: const [
                    DropdownMenuItem(
                      value: 'operational',
                      child: Text('Operativo'),
                    ),
                    DropdownMenuItem(
                      value: 'administrator',
                      child: Text('Administrador'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => roleType = value ?? 'operational'),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final permission in _permissions)
                        CheckboxListTile(
                          dense: true,
                          value: selected.contains(permission.key),
                          title: Text(permission.description),
                          subtitle: Text(permission.key),
                          onChanged: (value) => setDialogState(() {
                            if (value == true) {
                              selected.add(permission.key);
                            } else {
                              selected.remove(permission.key);
                            }
                          }),
                        ),
                    ],
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
              onPressed: name.text.trim().isEmpty || selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    final value = name.text.trim();
    name.dispose();
    if (accepted != true) return;
    await _run(() async {
      await widget.controller.saveAccessRole(
        id: role?.id,
        name: value,
        roleType: roleType,
        permissions: selected.toList()..sort(),
        expectedVersion: role?.version,
      );
      _success = role == null ? 'Rol creado.' : 'Rol actualizado.';
    });
  }

  Future<void> _editAccessUser([RemoteAccessUser? user]) async {
    final name = TextEditingController(text: user?.name ?? '');
    final username = TextEditingController(text: user?.username ?? '');
    final email = TextEditingController(text: user?.email ?? '');
    final roleIds = <String>{...?(user?.roles.map((role) => role.id))};
    var active = user?.active ?? true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            user == null ? 'Crear usuario central' : 'Editar usuario central',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nombre'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: username,
                    decoration: const InputDecoration(labelText: 'Usuario'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Correo opcional',
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final role in _roles)
                    CheckboxListTile(
                      dense: true,
                      value: roleIds.contains(role.id),
                      title: Text(role.name),
                      onChanged: (value) => setDialogState(() {
                        if (value == true) {
                          roleIds.add(role.id);
                        } else {
                          roleIds.remove(role.id);
                        }
                      }),
                    ),
                  if (user != null)
                    SwitchListTile(
                      value: active,
                      title: const Text('Usuario activo'),
                      onChanged: (value) =>
                          setDialogState(() => active = value),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: roleIds.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    final userName = name.text.trim();
    final login = username.text.trim();
    final mail = email.text.trim();
    name.dispose();
    username.dispose();
    email.dispose();
    if (accepted != true) return;
    await _run(() async {
      if (user == null) {
        final created = await widget.controller.createAccessUser(
          name: userName,
          username: login,
          email: mail,
          roleIds: roleIds.toList(),
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Código de activación'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Entrégalo de forma privada al usuario. Se muestra una sola vez.',
                ),
                const SizedBox(height: 16),
                SelectableText(created.activationCode),
                const SizedBox(height: 12),
                Text(
                  'Vence ${DateFormat('dd/MM/yyyy HH:mm').format(created.activationExpiresAt.toLocal())}.',
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Entendido'),
              ),
            ],
          ),
        );
        _success = 'Usuario central creado y pendiente de activación.';
      } else {
        await widget.controller.updateAccessUser(
          id: user.id,
          name: userName,
          username: login,
          email: mail,
          active: active,
          roleIds: roleIds.toList(),
        );
        _success = 'Usuario central actualizado.';
      }
    });
  }

  Widget _synchronizationCard() {
    final coordinator = widget.syncCoordinator!;
    final snapshot = coordinator.snapshot;
    final status = coordinator.running
        ? 'Sincronizando…'
        : switch (snapshot?.status) {
            SyncStatus.synced => 'Sincronizado',
            SyncStatus.pending => 'Pendiente de sincronizar',
            SyncStatus.error => 'Sin conexión; se reintentará automáticamente',
            SyncStatus.syncing => 'Sincronizando…',
            SyncStatus.localOnly || null => 'Preparando sincronización',
          };
    final lastSuccess = snapshot?.lastSuccessAt;
    return _card(
      title: 'Sincronización',
      icon: coordinator.running
          ? Icons.sync
          : snapshot?.status == SyncStatus.error
          ? Icons.cloud_off_outlined
          : Icons.cloud_done_outlined,
      children: [
        Semantics(
          liveRegion: true,
          label: 'Estado de sincronización: $status',
          child: Text(
            status,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          snapshot == null
              ? 'Consultando operaciones pendientes.'
              : snapshot.pending == 0
              ? 'No hay operaciones pendientes en este dispositivo.'
              : '${snapshot.pending} operaciones permanecen seguras en este dispositivo hasta recuperar Internet.',
        ),
        if (lastSuccess != null) ...[
          const SizedBox(height: 8),
          Text(
            'Última sincronización: ${DateFormat('dd/MM/yyyy HH:mm').format(lastSuccess.toLocal())}',
          ),
        ],
        if (snapshot?.lastError != null) ...[
          const SizedBox(height: 8),
          Text(
            snapshot!.lastError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy || coordinator.running ? null : _syncNow,
          icon: coordinator.running
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          label: Text(
            coordinator.running ? 'Sincronizando…' : 'Sincronizar ahora',
          ),
        ),
      ],
    );
  }

  Future<void> _syncNow() async {
    await _run(() async {
      final result = await widget.syncCoordinator!.syncNow();
      if (result == null) return;
      _success = result.pushed == 0 && result.received == 0
          ? 'Todo está sincronizado.'
          : 'Sincronización completa: ${result.pushed} enviados y ${result.applied} aplicados.';
    });
  }

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
        syncAfter: true,
      );
    }
  }

  Future<void> _showAccessActivation() async {
    final username = TextEditingController();
    final code = TextEditingController();
    final password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Activar usuario central'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: username,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Usuario'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: code,
                decoration: const InputDecoration(
                  labelText: 'Código de activación',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Nueva contraseña central',
                  helperText: 'Mínimo 12 caracteres.',
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
            child: const Text('Activar'),
          ),
        ],
      ),
    );
    final login = username.text;
    final activationCode = code.text;
    final newPassword = password.text;
    username.dispose();
    code.dispose();
    password.dispose();
    if (accepted != true) return;
    await _run(() async {
      await widget.controller.activateAccessUser(
        username: login,
        activationCode: activationCode,
        password: newPassword,
      );
      _success = 'Usuario activado. Ya puedes iniciar sesión.';
    });
  }

  Future<void> _showAccessLogin() async {
    final username = TextEditingController();
    final password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ingresar como usuario'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: username,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Usuario'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Contraseña central',
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
    final login = username.text;
    final secret = password.text;
    username.dispose();
    password.dispose();
    if (accepted != true) return;
    await _run(
      () =>
          widget.controller.loginAccessUser(username: login, password: secret),
      syncAfter: true,
    );
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
