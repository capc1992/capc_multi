import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'ffi_database_driver.dart';
import 'platform_services.dart';

class WindowsPlatformServices implements AppPlatformServices {
  WindowsPlatformServices();

  @override
  final LocalDatabaseDriver database = FfiLocalDatabaseDriver();

  @override
  CapcPlatformKind get kind => CapcPlatformKind.windows;

  @override
  String get platformLabel => 'Windows';

  @override
  bool get isAndroid => false;

  @override
  bool get caseInsensitivePaths => true;

  @override
  bool get supportsDocumentSharing => false;

  @override
  Future<String> databasePath() async {
    final override = Platform.environment['CAPC_DATA_DIR'];
    final base = override == null || override.trim().isEmpty
        ? await getApplicationSupportDirectory()
        : Directory(override);
    final directory = Directory(p.join(base.path, 'CAPC', 'local'));
    await directory.create(recursive: true);
    return p.join(directory.path, 'capc.sqlite3');
  }

  @override
  Future<Directory> temporaryDirectory() => getTemporaryDirectory();

  @override
  Future<DeviceSummary> deviceSummary() async => DeviceSummary(
    platform: platformLabel,
    description: Platform.localHostname,
  );

  @override
  Future<void> openExternalUri(Uri uri) async {
    if (uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'uri', 'CAPC solo abre enlaces HTTPS.');
    }
    final process = await Process.start('explorer.exe', [
      uri.toString(),
    ], mode: ProcessStartMode.detached);
    if (process.pid <= 0) {
      throw const FileSystemException('No se pudo abrir el enlace.');
    }
  }

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
    final bytes = await buildBytes();
    await XFile.fromData(
      bytes,
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
  }) => Printing.layoutPdf(
    name: name,
    format: format,
    dynamicLayout: false,
    windowsModernDialog: true,
    onLayout: (_) async => bytes,
  );

  @override
  Future<bool> sharePdf({
    required Uint8List bytes,
    required String name,
  }) async => false;
}
