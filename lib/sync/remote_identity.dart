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

class RemotePermission {
  const RemotePermission({
    required this.key,
    required this.module,
    required this.action,
    required this.description,
  });
  final String key, module, action, description;
  factory RemotePermission.fromJson(Map<String, Object?> json) =>
      RemotePermission(
        key: json['key'] as String,
        module: json['module'] as String,
        action: json['action'] as String,
        description: json['description'] as String,
      );
}

class RemoteAccessRole {
  const RemoteAccessRole({
    required this.id,
    required this.name,
    required this.roleType,
    required this.permissions,
    required this.system,
    required this.version,
  });
  final String id, name;
  final String roleType;
  final List<String> permissions;
  final bool system;
  final int version;
  factory RemoteAccessRole.fromJson(Map<String, Object?> json) =>
      RemoteAccessRole(
        id: json['id'] as String,
        name: json['name'] as String,
        roleType: json['roleType'] as String,
        permissions: (json['permissions'] as List).cast<String>(),
        system: json['system'] as bool,
        version: json['version'] as int,
      );
}

class RemoteAccessRoleRef {
  const RemoteAccessRoleRef(this.id, this.name);
  final String id, name;
  factory RemoteAccessRoleRef.fromJson(Map<String, Object?> json) =>
      RemoteAccessRoleRef(json['id'] as String, json['name'] as String);
}

class RemoteAccessUser {
  const RemoteAccessUser({
    required this.id,
    required this.name,
    required this.username,
    required this.active,
    required this.activated,
    required this.roles,
    required this.securityVersion,
    this.email,
  });
  final String id, name, username;
  final String? email;
  final bool active, activated;
  final List<RemoteAccessRoleRef> roles;
  final int securityVersion;
  factory RemoteAccessUser.fromJson(Map<String, Object?> json) =>
      RemoteAccessUser(
        id: json['id'] as String,
        name: json['name'] as String,
        username: json['username'] as String,
        email: json['email'] as String?,
        active: json['active'] as bool,
        activated: json['activated'] as bool,
        roles: (json['roles'] as List)
            .map(
              (item) => RemoteAccessRoleRef.fromJson(
                Map<String, Object?>.from(item as Map),
              ),
            )
            .toList(growable: false),
        securityVersion: json['securityVersion'] as int,
      );
}

class CreatedRemoteAccessUser {
  const CreatedRemoteAccessUser(
    this.user,
    this.activationCode,
    this.activationExpiresAt,
  );
  final RemoteAccessUser user;
  final String activationCode;
  final DateTime activationExpiresAt;
}

class RemoteSecurityAudit {
  const RemoteSecurityAudit({
    required this.id,
    required this.event,
    required this.actorName,
    required this.details,
    required this.createdAt,
    this.deviceId,
    this.deviceName,
    this.ownerId,
    this.userId,
  });

  final String id, event, actorName;
  final String? deviceId, deviceName, ownerId, userId;
  final Map<String, Object?> details;
  final DateTime createdAt;

  factory RemoteSecurityAudit.fromJson(Map<String, Object?> json) =>
      RemoteSecurityAudit(
        id: json['id'] as String,
        event: json['event'] as String,
        actorName: json['actorName'] as String,
        deviceId: json['deviceId'] as String?,
        deviceName: json['deviceName'] as String?,
        ownerId: json['ownerId'] as String?,
        userId: json['userId'] as String?,
        details: Map<String, Object?>.from(json['details'] as Map),
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      );
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
  Uri get privacyUri => (configuration.baseUri ?? recommendedProductionUri)
      .resolve('/privacidad');
  Uri get accountDeletionUri =>
      (configuration.baseUri ?? recommendedProductionUri).resolve(
        '/eliminar-cuenta',
      );

  Future<OfflineAuthorization?> offlineAuthorization() async {
    final current = _session ?? await credentials.read();
    if (current == null ||
        current.businessId != repository.businessId ||
        current.deviceId != repository.deviceId) {
      return null;
    }
    return current.verifyOfflineAuthorization();
  }

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
    final saved = await _saveSession(refreshed);
    if (repository.currentUser?.central == true &&
        repository.currentUser?.id == saved.userId) {
      final authorization = await saved.verifyOfflineAuthorization();
      if (authorization != null) {
        await repository.refreshCentralAuthorization(authorization);
      }
    }
    return saved.accessToken;
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

  Future<void> activateAccessUser({
    required String username,
    required String activationCode,
    required String password,
  }) async {
    _requireEnabled();
    await _post('/api/v1/access/activate', {
      'business_id': repository.businessId,
      'username': username.trim(),
      'activation_code': activationCode.trim(),
      'password': password,
    });
  }

  Future<void> loginAccessUser({
    required String username,
    required String password,
    bool authenticateLocally = false,
  }) async {
    _requireEnabled();
    _requireNoIdentityConflict();
    final response = await _post('/api/v1/access/login', {
      'business_id': repository.businessId,
      'username': username.trim(),
      'password': password,
      'device_id': repository.deviceId,
    });
    final session = await _saveSession(response);
    if (authenticateLocally) {
      final authorization = await session.verifyOfflineAuthorization();
      if (authorization == null) {
        throw const RemoteIdentityException(
          'El servidor no entregó una autorización offline válida.',
        );
      }
      await repository.cacheCentralLogin(authorization, password);
    }
  }

  Future<void> loginAccessUserOffline({
    required String username,
    required String password,
  }) async {
    final authorization = await offlineAuthorization();
    if (authorization == null) {
      throw const RemoteIdentityException(
        'Conéctate a internet para renovar la autorización de este usuario.',
      );
    }
    await repository.loginCentralOffline(username, password, authorization);
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

  Future<List<RemotePermission>> listAccessPermissions() async {
    final response = await _authorized('GET', '/api/v1/access/permissions');
    return (response['permissions'] as List)
        .map(
          (item) =>
              RemotePermission.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<List<RemoteAccessRole>> listAccessRoles() async {
    final response = await _authorized('GET', '/api/v1/access/roles');
    return (response['roles'] as List)
        .map(
          (item) =>
              RemoteAccessRole.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<RemoteAccessRole> saveAccessRole({
    String? id,
    required String name,
    required String roleType,
    required List<String> permissions,
    int? expectedVersion,
  }) async {
    final response = await _authorized(
      id == null ? 'POST' : 'PATCH',
      id == null ? '/api/v1/access/roles' : '/api/v1/access/roles/$id',
      body: {
        'name': name.trim(),
        'role_type': roleType,
        'permissions': permissions,
        'expected_version': ?expectedVersion,
      },
    );
    return RemoteAccessRole.fromJson(
      Map<String, Object?>.from(response['role'] as Map),
    );
  }

  Future<List<RemoteAccessUser>> listAccessUsers() async {
    final response = await _authorized('GET', '/api/v1/access/users');
    return (response['users'] as List)
        .map(
          (item) =>
              RemoteAccessUser.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<CreatedRemoteAccessUser> createAccessUser({
    required String name,
    required String username,
    String? email,
    required List<String> roleIds,
  }) async {
    final response = await _authorized(
      'POST',
      '/api/v1/access/users',
      body: {
        'name': name.trim(),
        'username': username.trim(),
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        'role_ids': roleIds,
      },
    );
    return CreatedRemoteAccessUser(
      RemoteAccessUser.fromJson(
        Map<String, Object?>.from(response['user'] as Map),
      ),
      response['activation_code'] as String,
      DateTime.parse(response['activation_expires_at'] as String).toUtc(),
    );
  }

  Future<RemoteAccessUser> updateAccessUser({
    required String id,
    required String name,
    required String username,
    String? email,
    required bool active,
    required List<String> roleIds,
  }) async {
    final response = await _authorized(
      'PATCH',
      '/api/v1/access/users/$id',
      body: {
        'name': name.trim(),
        'username': username.trim(),
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        'active': active,
        'role_ids': roleIds,
      },
    );
    return RemoteAccessUser.fromJson(
      Map<String, Object?>.from(response['user'] as Map),
    );
  }

  Future<List<RemoteSecurityAudit>> listSecurityAudit({int limit = 200}) async {
    if (limit < 1 || limit > 500) {
      throw const RemoteIdentityException(
        'El límite de auditoría no es válido.',
      );
    }
    final response = await _authorized(
      'GET',
      '/api/v1/access/audit?limit=$limit',
    );
    return (response['audit'] as List)
        .map(
          (item) => RemoteSecurityAudit.fromJson(
            Map<String, Object?>.from(item as Map),
          ),
        )
        .toList(growable: false);
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

  Future<void> deleteAccount({
    required String email,
    required String password,
  }) async {
    _requireEnabled();
    final current = _session ?? await credentials.read();
    if (current == null || current.businessId != repository.businessId) {
      throw const RemoteIdentityException(
        'Inicia sesión remota para eliminar la cuenta.',
      );
    }
    await _post('/api/v1/identity/delete-account', {
      'business_id': current.businessId,
      'email': email.trim(),
      'password': password,
      'confirmation': 'ELIMINAR',
    });
    _session = null;
    _identityConflict = false;
    await credentials.clear();
  }

  Future<void> openPrivacyPolicy() => appPlatform.openExternalUri(privacyUri);

  Future<void> openExternalDeletion() =>
      appPlatform.openExternalUri(accountDeletionUri);

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

  Future<Map<String, Object?>> _authorized(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final token = await accessToken();
    if (token == null) {
      throw const RemoteIdentityException(
        'Inicia sesión remota para continuar.',
      );
    }
    return _request(method, path, token: token, body: body);
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
    // Fastify rejects an empty body advertised as JSON (link codes/logout).
    if (body != null) request.headers.contentType = ContentType.json;
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
    'business_id_required' =>
      'Este correo administra más de un negocio. Verifica el identificador del negocio.',
    'business_unavailable' => 'La cuenta remota ya no está disponible.',
    'unknown_permission' =>
      'El rol contiene un permiso que el servidor no reconoce.',
    'role_name_exists' => 'Ya existe un rol con ese nombre.',
    'role_not_found' => 'El rol no existe o pertenece a otro negocio.',
    'system_role_immutable' =>
      'El rol del administrador principal está protegido.',
    'role_version_conflict' =>
      'El rol cambió en otro dispositivo. Actualiza e intenta de nuevo.',
    'user_identity_exists' => 'El usuario o correo ya está registrado.',
    'user_not_found' => 'El usuario no existe o pertenece a otro negocio.',
    'cannot_deactivate_current_owner' =>
      'No puedes desactivar al administrador principal actual.',
    'owner_role_required' =>
      'El administrador principal debe conservar su rol protegido.',
    'activation_invalid_or_expired' =>
      'El código de activación no es válido, ya fue usado o venció.',
    'remote_owner_required' =>
      'Esta acción requiere la cuenta del administrador principal.',
    _ => 'No se pudo completar la operación remota.',
  };
}

class RemoteIdentityException implements Exception {
  const RemoteIdentityException(this.message);
  final String message;
  @override
  String toString() => message;
}
