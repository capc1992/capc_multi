import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';

import 'ffi_database_driver.dart';
import 'platform_services.dart';

/// Minimal host services used by `flutter test` on Linux CI.
///
/// This is deliberately not a supported application platform. The production
/// factory only selects it when Flutter marks the process as a test runner.
class TestHostPlatformServices implements AppPlatformServices {
  @override
  final LocalDatabaseDriver database = FfiLocalDatabaseDriver();

  @override
  CapcPlatformKind get kind => CapcPlatformKind.windows;

  @override
  String get platformLabel => 'Pruebas';

  @override
  bool get isAndroid => false;

  @override
  bool get caseInsensitivePaths => Platform.isWindows;

  @override
  bool get supportsDocumentSharing => false;

  @override
  Future<String> databasePath() async =>
      p.join(Directory.systemTemp.path, 'capc-test.sqlite3');

  @override
  Future<Directory> temporaryDirectory() async => Directory.systemTemp;

  @override
  Future<DeviceSummary> deviceSummary() async => DeviceSummary(
    platform: platformLabel,
    description: 'Flutter test en ${Platform.operatingSystem}',
  );

  @override
  Future<void> openExternalUri(Uri uri) => throw UnsupportedError(
    'Los enlaces externos no están disponibles durante las pruebas.',
  );

  @override
  Future<SelectedDocument?> openDocument(DocumentType type) async => null;

  @override
  Future<SavedDocument?> saveDocument({
    required Future<Uint8List> Function() buildBytes,
    required String suggestedName,
    required DocumentType type,
    Future<bool> Function(String path)? confirmReplace,
  }) async => null;

  @override
  Future<bool> printPdf({
    required Uint8List bytes,
    required String name,
    required PdfPageFormat format,
  }) async => false;

  @override
  Future<bool> sharePdf({required Uint8List bytes, required String name}) async =>
      false;
}
