import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'platform_factory_stub.dart'
    if (dart.library.io) 'platform_factory_io.dart'
    as platform_impl;

enum CapcPlatformKind { windows, android }

class DocumentType {
  const DocumentType({
    required this.label,
    required this.extensions,
    required this.mimeType,
  });

  final String label;
  final List<String> extensions;
  final String mimeType;
}

class SelectedDocument {
  const SelectedDocument({
    required this.name,
    required this.path,
    required this.readBytes,
    required this.length,
  });

  final String name;
  final String path;
  final Future<Uint8List> Function() readBytes;
  final Future<int> Function() length;
}

class SavedDocument {
  const SavedDocument({required this.displayLocation});

  final String displayLocation;
}

class DeviceSummary {
  const DeviceSummary({required this.platform, required this.description});

  final String platform;
  final String description;
}

abstract interface class LocalDatabaseDriver {
  Future<Database> open(String path, OpenDatabaseOptions options);
}

abstract interface class AppPlatformServices {
  CapcPlatformKind get kind;
  String get platformLabel;
  bool get isAndroid;
  bool get caseInsensitivePaths;
  bool get supportsDocumentSharing;
  LocalDatabaseDriver get database;

  Future<String> databasePath();
  Future<Directory> temporaryDirectory();
  Future<DeviceSummary> deviceSummary();

  Future<SelectedDocument?> openDocument(DocumentType type);

  Future<SavedDocument?> saveDocument({
    required Future<Uint8List> Function() buildBytes,
    required String suggestedName,
    required DocumentType type,
    Future<bool> Function(String path)? confirmReplace,
  });

  Future<bool> printPdf({
    required Uint8List bytes,
    required String name,
    required PdfPageFormat format,
  });

  Future<bool> sharePdf({required Uint8List bytes, required String name});
}

AppPlatformServices? platformServicesOverride;

AppPlatformServices get appPlatform =>
    platformServicesOverride ?? platform_impl.createPlatformServices();
