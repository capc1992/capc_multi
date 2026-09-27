import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'ffi_database_driver.dart';
import 'platform_services.dart';

class AndroidPlatformServices implements AppPlatformServices {
  AndroidPlatformServices();

  static const _channel = MethodChannel('co.capc.multiservicio/platform');

  @override
  final LocalDatabaseDriver database = FfiLocalDatabaseDriver();

  @override
  CapcPlatformKind get kind => CapcPlatformKind.android;

  @override
  String get platformLabel => 'Android';

  @override
  bool get isAndroid => true;

  @override
  bool get caseInsensitivePaths => false;

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
  Future<DeviceSummary> deviceSummary() async {
    try {
      final description = await _channel.invokeMethod<String>('deviceInfo');
      return DeviceSummary(
        platform: platformLabel,
        description: description?.trim().isNotEmpty == true
            ? description!.trim()
            : 'Dispositivo Android',
      );
    } on PlatformException {
      return const DeviceSummary(
        platform: 'Android',
        description: 'Dispositivo Android',
      );
    } on MissingPluginException {
      return const DeviceSummary(
        platform: 'Android',
        description: 'Dispositivo Android',
      );
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
    final bytes = await buildBytes();
    final location = await _channel.invokeMethod<String>('saveDocument', {
      'bytes': bytes,
      'suggestedName': suggestedName,
      'mimeType': type.mimeType,
    });
    return location == null ? null : SavedDocument(displayLocation: location);
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
