import 'dart:convert';

enum UpdateChannel {
  stable('stable', 'Estable'),
  beta('beta', 'Beta'),
  testing('testing', 'Pruebas');

  const UpdateChannel(this.slug, this.label);
  final String slug;
  final String label;

  static UpdateChannel parse(String value) => switch (value.toLowerCase()) {
    'stable' => stable,
    'beta' => beta,
    'testing' || 'pruebas' => testing,
    _ => throw const UpdateException('Canal de actualización desconocido.'),
  };
}

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  readyToInstall,
  offline,
  error,
}

enum UpdatePlatform { windows, android }

enum PlatformUpdatePhase {
  downloading,
  downloaded,
  installing,
  failed,
  canceled,
}

class PlatformUpdateEvent {
  const PlatformUpdateEvent(this.phase, {this.progress});
  final PlatformUpdatePhase phase;
  final double? progress;
}

class AppVersion implements Comparable<AppVersion> {
  AppVersion({
    required this.versionName,
    required this.buildNumber,
    required this.packageName,
  }) : _parts = _parseVersion(versionName);

  final String versionName;
  final int buildNumber;
  final String packageName;
  final List<int> _parts;

  static List<int> _parseVersion(String value) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?$',
    ).firstMatch(value.trim());
    if (match == null) {
      throw const UpdateException('La versión instalada no es válida.');
    }
    return [
      for (var index = 1; index <= 3; index++) int.parse(match.group(index)!),
    ];
  }

  @override
  int compareTo(AppVersion other) {
    for (var index = 0; index < _parts.length; index++) {
      final compared = _parts[index].compareTo(other._parts[index]);
      if (compared != 0) return compared;
    }
    return buildNumber.compareTo(other.buildNumber);
  }

  bool isOlderThan(AppVersion other) => compareTo(other) < 0;

  @override
  String toString() => '$versionName+$buildNumber';
}

class UpdateArtifact {
  const UpdateArtifact({
    required this.url,
    required this.sha256,
    required this.sizeBytes,
  });

  final Uri url;
  final String sha256;
  final int sizeBytes;

  factory UpdateArtifact.fromJson(Map<String, Object?> json) {
    _exactKeys(json, const {'url', 'sha256', 'sizeBytes'}, 'artifact');
    final rawUrl = _string(json, 'url');
    final uri = Uri.tryParse(rawUrl);
    final hash = _string(json, 'sha256').toUpperCase();
    final size = _integer(json, 'sizeBytes');
    if (uri == null || !uri.hasAuthority) {
      throw const UpdateException('La dirección del instalador no es válida.');
    }
    if (!RegExp(r'^[A-F0-9]{64}$').hasMatch(hash)) {
      throw const UpdateException('El SHA-256 publicado no es válido.');
    }
    if (size <= 0) {
      throw const UpdateException(
        'El tamaño publicado debe ser mayor que cero.',
      );
    }
    return UpdateArtifact(url: uri, sha256: hash, sizeBytes: size);
  }

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'sha256': sha256,
    'sizeBytes': sizeBytes,
  };
}

class UpdateRelease {
  const UpdateRelease({
    required this.platform,
    required this.channel,
    required this.versionName,
    required this.buildNumber,
    required this.mandatory,
    required this.minimumSupportedBuild,
    required this.releaseNotes,
    this.publishedAt,
    this.artifact,
  });

  final String platform;
  final UpdateChannel channel;
  final String versionName;
  final int buildNumber;
  final DateTime? publishedAt;
  final bool mandatory;
  final int minimumSupportedBuild;
  final List<String> releaseNotes;
  final UpdateArtifact? artifact;

  AppVersion asVersion(String packageName) => AppVersion(
    versionName: versionName,
    buildNumber: buildNumber,
    packageName: packageName,
  );

  bool isMandatoryFor(AppVersion installed) =>
      mandatory || installed.buildNumber < minimumSupportedBuild;

  factory UpdateRelease.fromWindowsJson(Map<String, Object?> json) {
    _exactKeys(json, const {
      'schemaVersion',
      'platform',
      'channel',
      'versionName',
      'buildNumber',
      'publishedAt',
      'mandatory',
      'minimumSupportedBuild',
      'releaseNotes',
      'artifact',
    }, 'latest.json');
    if (_integer(json, 'schemaVersion') != 1) {
      throw const UpdateException(
        'El esquema de actualización no es compatible.',
      );
    }
    final platform = _string(json, 'platform');
    if (platform != 'windows-x64') {
      throw const UpdateException(
        'La actualización no corresponde a Windows x64.',
      );
    }
    final versionName = _string(json, 'versionName');
    AppVersion(
      versionName: versionName,
      buildNumber: 0,
      packageName: 'validate',
    );
    final publishedAt = DateTime.tryParse(
      _string(json, 'publishedAt'),
    )?.toUtc();
    if (publishedAt == null) {
      throw const UpdateException('La fecha de publicación no es válida.');
    }
    final notes = json['releaseNotes'];
    if (notes is! List || notes.isEmpty || notes.length > 50) {
      throw const UpdateException('Las notas de la versión no son válidas.');
    }
    final releaseNotes = notes
        .map((value) {
          if (value is! String || value.trim().isEmpty || value.length > 500) {
            throw const UpdateException(
              'Las notas de la versión no son válidas.',
            );
          }
          return value.trim();
        })
        .toList(growable: false);
    final artifact = json['artifact'];
    if (artifact is! Map) {
      throw const UpdateException('Falta el instalador de la actualización.');
    }
    return UpdateRelease(
      platform: platform,
      channel: UpdateChannel.parse(_string(json, 'channel')),
      versionName: versionName,
      buildNumber: _positiveInteger(json, 'buildNumber'),
      publishedAt: publishedAt,
      mandatory: _boolean(json, 'mandatory'),
      minimumSupportedBuild: _positiveInteger(json, 'minimumSupportedBuild'),
      releaseNotes: releaseNotes,
      artifact: UpdateArtifact.fromJson(Map<String, Object?>.from(artifact)),
    );
  }

  static UpdateRelease decodeWindows(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const UpdateException('El servidor devolvió un JSON incorrecto.');
    }
    if (decoded is! Map) {
      throw const UpdateException('El servidor devolvió un JSON incorrecto.');
    }
    return UpdateRelease.fromWindowsJson(Map<String, Object?>.from(decoded));
  }
}

class PreparedUpdate {
  const PreparedUpdate({required this.release, required this.path});
  final UpdateRelease release;
  final String path;
}

class UpdateException implements Exception {
  const UpdateException(this.message, {this.offline = false});
  final String message;
  final bool offline;

  @override
  String toString() => message;
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw UpdateException('El campo $key no es válido.');
  }
  return value.trim();
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw UpdateException('El campo $key no es válido.');
  return value;
}

int _positiveInteger(Map<String, Object?> json, String key) {
  final value = _integer(json, key);
  if (value <= 0) throw UpdateException('El campo $key no es válido.');
  return value;
}

bool _boolean(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw UpdateException('El campo $key no es válido.');
  return value;
}

void _exactKeys(Map<String, Object?> json, Set<String> keys, String context) {
  if (json.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(json.keys.toSet()).isNotEmpty) {
    throw UpdateException('La estructura de $context no es válida.');
  }
}
