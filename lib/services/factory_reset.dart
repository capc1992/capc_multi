import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../data/repository.dart';

class FactoryResetService {
  const FactoryResetService._();

  static String _journalPath(String databasePath) =>
      '$databasePath.factory-reset.json';

  static Future<String> createBackup(CapcRepository repository) async {
    final directory = Directory(
      p.join(p.dirname(repository.databasePath), 'respaldos_reinicio'),
    );
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final target = p.join(directory.path, 'antes-reinicio-$stamp.sqlite3');
    await repository.backupTo(target);
    return target;
  }

  static Future<void> markForReset({
    required String databasePath,
    required String backupPath,
  }) async {
    final journal = File(_journalPath(databasePath));
    await journal.writeAsString(
      jsonEncode({
        'phase': 'erase_local',
        'database': databasePath,
        'backup': backupPath,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  static Future<void> completePendingReset(String databasePath) async {
    if (databasePath == inMemoryDatabasePath) {
      throw const CapcException(
        'El reinicio no está disponible para una base temporal.',
      );
    }
    final journal = File(_journalPath(databasePath));
    if (!await journal.exists()) return;
    Map<String, Object?> data;
    try {
      data = Map<String, Object?>.from(
        jsonDecode(await journal.readAsString()) as Map,
      );
    } catch (_) {
      throw const CapcException(
        'El registro de reinicio está dañado. Conserva los archivos y solicita soporte.',
      );
    }
    if (data['phase'] != 'erase_local' ||
        p.normalize(data['database'] as String? ?? '') !=
            p.normalize(databasePath)) {
      throw const CapcException(
        'El registro de reinicio no corresponde a esta instalación.',
      );
    }
    for (final path in [
      databasePath,
      '$databasePath-wal',
      '$databasePath-shm',
      '$databasePath-journal',
    ]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await journal.delete();
  }
}
