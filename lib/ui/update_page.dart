import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../update/update_controller.dart';
import '../update/update_models.dart';

class UpdatePage extends StatelessWidget {
  const UpdatePage({
    super.key,
    required this.controller,
    required this.repository,
    required this.canInstall,
  });

  final UpdateController controller;
  final CapcRepository repository;
  final bool canInstall;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Actualizaciones')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context),
                  const SizedBox(height: 20),
                  _status(context),
                  const SizedBox(height: 16),
                  _versions(context),
                  if (controller.release != null) ...[
                    const SizedBox(height: 16),
                    _releaseNotes(context),
                  ],
                  if (controller.status == UpdateStatus.downloading) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      label: 'Progreso de descarga',
                      value: controller.progress == null
                          ? 'En curso'
                          : '${(controller.progress! * 100).round()} por ciento',
                      child: LinearProgressIndicator(
                        value: controller.progress,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      controller.progress == null
                          ? 'Google Play administra la descarga.'
                          : '${(controller.progress! * 100).round()} %',
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  _actions(context),
                  const SizedBox(height: 16),
                  Text(
                    'Actualizar la aplicación no elimina ventas, inventario, caja, clientes, respaldos ni configuración. Sin internet puedes continuar trabajando normalmente.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _header(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        controller.platform == UpdatePlatform.windows
            ? Icons.desktop_windows_outlined
            : Icons.android_outlined,
        size: 40,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 12),
      Text(
        'Centro de actualizaciones',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 6),
      const Text(
        'La sincronización actualiza tus datos; esta sección actualiza el programa CAPC.',
      ),
    ],
  );

  Widget _status(BuildContext context) {
    final mandatory = controller.mandatory;
    final colors = Theme.of(context).colorScheme;
    final background = mandatory
        ? colors.errorContainer
        : controller.status == UpdateStatus.error
        ? colors.errorContainer
        : controller.status == UpdateStatus.upToDate
        ? colors.primaryContainer
        : colors.surfaceContainerHighest;
    final icon = switch (controller.status) {
      UpdateStatus.checking => Icons.sync,
      UpdateStatus.upToDate => Icons.check_circle_outline,
      UpdateStatus.available => Icons.system_update_alt,
      UpdateStatus.downloading => Icons.downloading_outlined,
      UpdateStatus.readyToInstall => Icons.install_desktop_outlined,
      UpdateStatus.offline => Icons.cloud_off_outlined,
      UpdateStatus.error => Icons.error_outline,
      UpdateStatus.idle => Icons.info_outline,
    };
    return Semantics(
      liveRegion: true,
      label: 'Estado de la aplicación: ${controller.message}',
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mandatory
                          ? 'Actualización obligatoria'
                          : 'Estado de la aplicación',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(controller.message),
                    if (mandatory) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Haz un respaldo e instala esta versión cuanto antes. Tus datos locales se conservan.',
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _versions(BuildContext context) {
    final installed = controller.installedVersion;
    final release = controller.release;
    final published = release?.publishedAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Wrap(
          spacing: 28,
          runSpacing: 18,
          children: [
            _value(
              context,
              'Versión instalada',
              installed?.versionName ?? 'Leyendo…',
            ),
            _value(
              context,
              'Número de compilación',
              installed?.buildNumber.toString() ?? '—',
            ),
            _value(context, 'Canal', controller.channel.label),
            _value(
              context,
              'Última versión disponible',
              release == null
                  ? controller.status == UpdateStatus.upToDate
                        ? installed?.versionName ?? '—'
                        : 'No comprobada'
                  : release.platform == 'android-play'
                  ? 'Google Play (compilación ${release.buildNumber})'
                  : '${release.versionName} (${release.buildNumber})',
            ),
            _value(
              context,
              'Fecha de publicación',
              published == null
                  ? release?.platform == 'android-play'
                        ? 'Administrada por Google Play'
                        : 'No disponible'
                  : DateFormat(
                      'dd/MM/yyyy HH:mm',
                      'es_CO',
                    ).format(published.toLocal()),
            ),
            _value(
              context,
              'Última comprobación',
              controller.lastCheckedAt == null
                  ? 'Todavía no realizada'
                  : DateFormat(
                      'dd/MM/yyyy HH:mm',
                      'es_CO',
                    ).format(controller.lastCheckedAt!.toLocal()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _value(BuildContext context, String label, String value) => SizedBox(
    width: 210,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );

  Widget _releaseNotes(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notas de la nueva versión',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          for (final note in controller.release!.releaseNotes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  '),
                  Expanded(child: Text(note)),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _actions(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      OutlinedButton.icon(
        onPressed: controller.busy ? null : () => controller.check(),
        icon: const Icon(Icons.refresh),
        label: const Text('Buscar actualizaciones'),
      ),
      if (controller.platform == UpdatePlatform.windows &&
          controller.status == UpdateStatus.available)
        FilledButton.icon(
          onPressed: controller.busy || !canInstall
              ? null
              : () => _downloadAndInstall(context),
          icon: const Icon(Icons.download_for_offline_outlined),
          label: const Text('Descargar e instalar'),
        ),
      if (controller.platform == UpdatePlatform.windows &&
          controller.status == UpdateStatus.readyToInstall)
        FilledButton.icon(
          onPressed: !canInstall ? null : () => _confirmAndInstall(context),
          icon: const Icon(Icons.install_desktop_outlined),
          label: const Text('Instalar ahora'),
        ),
      if (controller.platform == UpdatePlatform.android &&
          controller.status == UpdateStatus.available)
        FilledButton.icon(
          onPressed: controller.busy ? null : controller.startAndroidUpdate,
          icon: const Icon(Icons.shop_outlined),
          label: const Text('Actualizar desde Google Play'),
        ),
      if (controller.platform == UpdatePlatform.android &&
          controller.status == UpdateStatus.readyToInstall)
        FilledButton.icon(
          onPressed: controller.completeAndroidUpdate,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reiniciar para actualizar'),
        ),
      if (controller.platform == UpdatePlatform.android)
        TextButton.icon(
          onPressed: controller.busy ? null : controller.openStore,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Abrir ficha de Google Play'),
        ),
      if (!canInstall && controller.platform == UpdatePlatform.windows)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'El propietario debe iniciar sesión para instalar y crear el respaldo previo.',
          ),
        ),
    ],
  );

  Future<void> _downloadAndInstall(BuildContext context) async {
    await controller.downloadWindows();
    if (context.mounted && controller.status == UpdateStatus.readyToInstall) {
      await _confirmAndInstall(context);
    }
  }

  Future<void> _confirmAndInstall(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Instalar actualización'),
        content: const Text(
          'CAPC creará un respaldo coherente, abrirá el instalador verificado y cerrará la aplicación. No se borrarán tus datos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Respaldar e instalar'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await controller.installWindows(
      createBackup: _backupBeforeUpdate,
      closeApplicationData: repository.close,
    );
  }

  Future<void> _backupBeforeUpdate() async {
    final directory = Directory(
      p.join(p.dirname(repository.databasePath), 'respaldos_actualizacion'),
    );
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    await repository.backupTo(
      p.join(directory.path, 'antes-actualizar-$stamp.sqlite3'),
    );
  }
}
