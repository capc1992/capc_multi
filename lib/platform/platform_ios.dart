import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'platform_services.dart';
import 'sqflite_database_driver.dart';

class IosPlatformServices implements AppPlatformServices {
  @override
  final LocalDatabaseDriver database = SqfliteLocalDatabaseDriver();

  @override
  CapcPlatformKind get kind => CapcPlatformKind.ios;

  @override
  String get platformLabel => 'iOS';

  @override
  bool get isAndroid => false;

  @override
  bool get isIOS => true;

  @override
  bool get caseInsensitivePaths => true;

  @override
  bool get supportsDocumentSharing => true;

  @override
  Future<String> databasePath() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory(p.join(base.path, 'CAPC', 'local'));
    await directory.create(recursive: true);
    return p.join(directory.path, 'capc.sqlite3');
  }

  @override
  Future<Directory> temporaryDirectory() => getTemporaryDirectory();

  @override
  Future<DeviceSummary> deviceSummary() async => const DeviceSummary(
    platform: 'iOS',
    description: 'iPhone o iPad',
  );

  @override
  Future<void> openExternalUri(Uri uri) async {
    if (uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'uri', 'CAPC solo abre enlaces HTTPS.');
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const FileSystemException('No se pudo abrir el enlace.');
    }
  }

  @override
  Future<SelectedDocument?> openDocument(DocumentType type) async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: type.label,
          uniformTypeIdentifiers: type.uniformTypeIdentifiers.isEmpty
              ? const ['public.data']
              : type.uniformTypeIdentifiers,
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
    final directory = await getTemporaryDirectory();
    final file = File(p.join(directory.path, suggestedName));
    await file.writeAsBytes(await buildBytes(), flush: true);
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: type.mimeType, name: suggestedName)],
          title: 'Guardar o compartir $suggestedName',
          sharePositionOrigin: const Rect.fromLTWH(1, 1, 1, 1),
        ),
      );
      if (result.status == ShareResultStatus.dismissed) return null;
      return const SavedDocument(
        displayLocation: 'la ubicación elegida en iOS',
      );
    } finally {
      if (await file.exists()) await file.delete();
    }
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
    onLayout: (_) async => bytes,
  );

  @override
  Future<bool> sharePdf({required Uint8List bytes, required String name}) =>
      Printing.sharePdf(bytes: bytes, filename: name);
}
