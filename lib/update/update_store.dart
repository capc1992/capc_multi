import 'dart:convert';
import 'dart:io';

abstract interface class UpdateCheckStore {
  Future<DateTime?> readLastCheck();
  Future<void> writeLastCheck(DateTime value);
}

class FileUpdateCheckStore implements UpdateCheckStore {
  const FileUpdateCheckStore(this.file);
  final File file;

  @override
  Future<DateTime?> readLastCheck() async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schemaVersion'] != 1) return null;
      final value = decoded['lastCheck'];
      return value is String ? DateTime.tryParse(value)?.toUtc() : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeLastCheck(DateTime value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'lastCheck': value.toUtc().toIso8601String(),
        }),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class MemoryUpdateCheckStore implements UpdateCheckStore {
  DateTime? value;

  @override
  Future<DateTime?> readLastCheck() async => value;

  @override
  Future<void> writeLastCheck(DateTime value) async =>
      this.value = value.toUtc();
}
