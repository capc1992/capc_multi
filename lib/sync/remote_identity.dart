import 'dart:convert';
import 'dart:io';

import '../data/repository.dart';
import '../platform/platform_services.dart';
import 'secure_credentials.dart';
import 'sync_transport.dart';

class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.createdAt,
    required this.current,
    this.lastSeenAt,
    this.revokedAt,
  });
  final String id, name, platform;
  final DateTime createdAt;
  final DateTime? lastSeenAt, revokedAt;
  final bool current;

  factory RemoteDevice.fromJson(Map<String, Object?> json) => RemoteDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    lastSeenAt: json['lastSeenAt'] == null
        ? null
        : DateTime.parse(json['lastSeenAt'] as String).toUtc(),
    revokedAt: json['revokedAt'] == null
        ? null
        : DateTime.parse(json['revokedAt'] as String).toUtc(),
    current: json['current'] as bool? ?? false,
  );
}

class LinkingCode {
  const LinkingCode(this.code, this.expiresAt);
  final String code;
  final DateTime expiresAt;
}

class RemoteIdentityController {
  RemoteIdentityController({
    required this.repository,
    SecureCredentialStore? credentials,
    SyncConfiguration? configuration,
    HttpClient? client,
  }) : credentials = credentials ?? PlatformSecureCredentialStore(),
       configuration = configuration ?? SyncConfiguration.fromEnvironment(),
       _client =
           client ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  static final recommendedProductionUri = Uri.parse(
    'https://api.capcmultiservicios.site',
  );

  final CapcRepository repository;
  final SecureCredentialStore credentials;
  final SyncConfiguration configuration;
  final HttpClient _client;
  RemoteSession? _session;
  bool _identityConflict = false;

  bool get enabled => configuration.enabled;
  RemoteSession? get session => _session;
  bool get connected => _session != null;

  Future<void> initialize() async {
    if (!enabled) return;
    final saved = await credentials.read();
    if (saved != null &&
        saved.deviceId == repository.deviceId &&
        saved.businessId == repository.businessId &&
        saved.refreshExpiresAt.isAfter(DateTime.now().toUtc())) {
      _session = saved;
    } else if (saved != null &&
        saved.refreshExpiresAt.isBefore(DateTime.now().toUtc())) {
      await credentials.clear();
    } else if (saved != null) {
      _identityConflict = true;
    }
  }

  Future<String?> accessToken() async {
    if (!enabled) return null;
    _session ??= await credentials.read();
    final current = _session;
    if (current == null) return null;
    if (current.deviceId != repository.deviceId ||
        current.businessId != repository.businessId) {
      _session = null;
      _identityConflict = true;
      throw const RemoteIdentityException(
        'La credencial segura pertenece a otro negocio o dispositivo. Haz un respaldo y usa la migración explícita.',
      );
    }
    if (current.accessExpiresAt.isAfter(
      DateTime.now().toUtc().add(const Duration(seconds: 30)),
    )) {
      return current.accessToken;
    }
    final refreshed = await _post('/api/v1/identity/refresh', {
      'refresh_token': current.refreshToken,
      'device_id': repository.deviceId,
    });
    return (await _saveSession(refreshed)).accessToken;
  }

  Future<void> connectBusiness({
    required String businessName,
    required String email,
    required String password,
  }) async {
    _requireEnabled();
    _requireNoIdentityConflict();
    final device = await appPlatform.deviceSummary();
    final response = await _post('/api/v1/identity/businesses', {
      'business_id': repository.businessId,
      'business_name': businessName.trim(),
      'email': email.trim(),
      'password': password,
      'device_id': repository.deviceId,
      'device_name': device.description,
      'platform': device.platform,
    });
    await _saveSession(response);
  }

  Future<void> login({required String email, required String password}) async {
    _requireEnabled();
    _requireNoIdentityConflict();
    final response = await _post('/api/v1/identity/login', {
      'business_id': repository.businessId,
      'email': email.trim(),
      'password': password,
      'device_id': repository.deviceId,
    });
    await _saveSession(response);
  }

  Future<void> linkDevice(String code) async {
    _requireEnabled();
    final saved = await credentials.read();
    if (_identityConflict ||
        (saved != null && saved.businessId != repository.businessId)) {
      throw const RemoteIdentityException(
        'Este equipo ya pertenece a otro negocio remoto. Haz un respaldo y usa el flujo explícito de migración.',
      );
    }
    final state = await repository.remoteLinkState();
    if (state == RemoteLinkState.hasBusinessMovements) {
      throw const RemoteIdentityException(
        'Este equipo contiene movimientos de otro negocio. Haz un respaldo; no se mezclarán los datos automáticamente.',
      );
    }
    final device = await appPlatform.deviceSummary();
    final response = await _post('/api/v1/identity/link', {
      'code': code.trim().toUpperCase(),
      'device_id': repository.deviceId,
      'device_name': device.description,
      'platform': device.platform,
      'local_business_id': repository.businessId,
      'local_state': state == RemoteLinkState.newInstallation
          ? 'new'
          : 'no_movements',
    });
    final remoteBusinessId = response['business_id'] as String;
    if (remoteBusinessId != repository.businessId) {
      await repository.adoptRemoteBusinessId(remoteBusinessId);
    }
    await _saveSession(response);
  }

  Future<LinkingCode> createLinkCode() async {
    final response = await _authorized('POST', '/api/v1/identity/link-codes');
    return LinkingCode(
      response['code'] as String,
      DateTime.parse(response['expiresAt'] as String).toUtc(),
    );
  }

  Future<List<RemoteDevice>> listDevices() async {
    final response = await _authorized('GET', '/api/v1/identity/devices');
    return (response['devices'] as List)
        .map(
          (item) =>
              RemoteDevice.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<void> revokeDevice(String deviceId) async {
    await _authorized('DELETE', '/api/v1/identity/devices/$deviceId');
    if (deviceId == repository.deviceId) {
      _session = null;
      _identityConflict = false;
      await credentials.clear();
    }
  }

  Future<void> logout() async {
    final current = _session ?? await credentials.read();
    try {
      if (current != null && enabled) {
        await _authorized('POST', '/api/v1/identity/logout');
      }
    } finally {
      _session = null;
      _identityConflict = false;
      await credentials.clear();
    }
  }

  Future<RemoteSession> _saveSession(Map<String, Object?> json) async {
    final session = RemoteSession.fromJson(json);
    if (session.deviceId != repository.deviceId ||
        session.businessId != repository.businessId) {
      throw const RemoteIdentityException(
        'La identidad remota no coincide con este negocio y dispositivo.',
      );
    }
    await credentials.write(session);
    _session = session;
    return session;
  }

  Future<Map<String, Object?>> _post(String path, Map<String, Object?> body) =>
      _request('POST', path, body: body);

  Future<Map<String, Object?>> _authorized(String method, String path) async {
    final token = await accessToken();
    if (token == null) {
      throw const RemoteIdentityException(
        'Inicia sesión remota para continuar.',
      );
    }
    return _request(method, path, token: token);
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    _requireEnabled();
    final request = await _client.openUrl(
      method,
      configuration.baseUri!.resolve(path),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set('X-Business-Id', repository.businessId);
    }
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    Map<String, Object?> decoded = const {};
    if (text.isNotEmpty) {
      try {
        decoded = Map<String, Object?>.from(jsonDecode(text) as Map);
      } catch (_) {
        throw const RemoteIdentityException(
          'El servidor remoto devolvió una respuesta inválida.',
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteIdentityException(_message(decoded['error'] as String?));
    }
    return decoded;
  }

  void _requireEnabled() {
    if (!enabled) {
      throw const RemoteIdentityException(
        'La conexión remota no está habilitada en esta compilación.',
      );
    }
  }

  void _requireNoIdentityConflict() {
    if (_identityConflict) {
      throw const RemoteIdentityException(
        'La credencial segura pertenece a otro negocio. Haz un respaldo y usa la migración explícita antes de reemplazarla.',
      );
    }
  }

  static String _message(String? code) => switch (code) {
    'invalid_credentials' => 'Correo, contraseña o dispositivo no autorizados.',
    'rate_limited' =>
      'Demasiados intentos. Espera unos minutos e intenta de nuevo.',
    'link_code_used' => 'El código de vinculación ya fue utilizado.',
    'link_code_invalid_or_expired' => 'El código no es válido o ya venció.',
    'business_already_connected' =>
      'Este negocio ya tiene una identidad remota.',
    'device_belongs_to_another_business' =>
      'El dispositivo pertenece a otro negocio. Haz un respaldo y migra explícitamente.',
    'local_business_belongs_to_another_remote_business' =>
      'La base local identifica otro negocio remoto. Haz un respaldo y usa la migración explícita.',
    _ => 'No se pudo completar la operación remota.',
  };
}

class RemoteIdentityException implements Exception {
  const RemoteIdentityException(this.message);
  final String message;
  @override
  String toString() => message;
}
