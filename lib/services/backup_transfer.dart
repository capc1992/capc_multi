import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import '../platform/platform_services.dart';

class PreparedBackup {
  const PreparedBackup({required this.path, required this.originalName});

  final String path;
  final String originalName;

  Future<void> dispose() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

class BackupTransfer {
  static const _uuid = Uuid();
  static const backupType = DocumentType(
    label: 'Respaldo SQLite de CAPC',
    extensions: ['sqlite', 'sqlite3', 'db'],
    mimeType: 'application/vnd.sqlite3',
  );

  static Future<SavedDocument?> exportBackup(
    CapcRepository repository, {
    required String suggestedName,
  }) async {
    final temporary = await appPlatform.temporaryDirectory();
    final snapshot = File(
      p.join(temporary.path, 'capc-export-${_uuid.v4()}.sqlite'),
    );
    try {
      return await appPlatform.saveDocument(
        buildBytes: () async {
          await repository.backupTo(snapshot.path);
          return Uint8List.fromList(await snapshot.readAsBytes());
        },
        suggestedName: suggestedName,
        type: backupType,
      );
    } finally {
      if (await snapshot.exists()) await snapshot.delete();
    }
  }

  static Future<PreparedBackup?> prepareImport() async {
    final selected = await appPlatform.openDocument(backupType);
    if (selected == null) return null;
    final temporary = await appPlatform.temporaryDirectory();
    final local = File(
      p.join(temporary.path, 'capc-import-${_uuid.v4()}.sqlite'),
    );
    try {
      await local.writeAsBytes(await selected.readBytes(), flush: true);
      return PreparedBackup(path: local.path, originalName: selected.name);
    } catch (_) {
      if (await local.exists()) await local.delete();
      rethrow;
    }
  }
}
