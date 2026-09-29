import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
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
  Future<SelectedDocument?> openDocument(DocumentType type) async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: type.label,
          extensions: type.extensions,
          mimeTypes: [type.mimeType],
        ),
      ],
    );
    if (file == null) return null;
    return SelectedDocument(
      name: file.name,
      path: file.path,
      readBytes: file.readAsBytes,
      length: file.length,
    );
  }

  @override
  Future<SavedDocument?> saveDocument({
    required Future<Uint8List> Function() buildBytes,
    required String suggestedName,
    required DocumentType type,
    Future<bool> Function(String path)? confirmReplace,
  }) async {
    final destination = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        XTypeGroup(
          label: type.label,
          extensions: type.extensions,
          mimeTypes: [type.mimeType],
        ),
      ],
      confirmButtonText: 'Guardar',
    );
    if (destination == null) return null;
    final extension = type.extensions.firstOrNull;
    final path =
        extension != null &&
            !destination.path.toLowerCase().endsWith(
              '.${extension.toLowerCase()}',
            )
        ? '${destination.path}.$extension'
        : destination.path;
    if (path != destination.path &&
        await File(path).exists() &&
        (confirmReplace == null || !await confirmReplace(path))) {
      return null;
    }
    await XFile.fromData(
      await buildBytes(),
      name: suggestedName,
      mimeType: type.mimeType,
    ).saveTo(path);
    return SavedDocument(displayLocation: path);
  }

  @override
  Future<bool> printPdf({
    required Uint8List bytes,
    required String name,
    required PdfPageFormat format,
  }) async => false;

  @override
  Future<bool> sharePdf({
    required Uint8List bytes,
    required String name,
  }) async => false;
}
