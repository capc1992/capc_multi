import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RemoteSession {
  const RemoteSession({
    required this.businessId,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required this.permissions,
    this.userId,
    this.principalName,
    this.username,
    this.roleType,
    this.offlineGrant,
    this.offlineGrantPublicKey,
    this.offlineGrantExpiresAt,
  });

  final String businessId;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final List<String> permissions;
  final String? userId;
  final String? principalName, username, roleType;
  final String? offlineGrant, offlineGrantPublicKey;
  final DateTime? offlineGrantExpiresAt;

  Map<String, Object?> toJson() => {
    'business_id': businessId,
    'device_id': deviceId,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
    'permissions': permissions,
    'user_id': userId,
    'principal_name': principalName,
    'username': username,
    'role_type': roleType,
    'offline_grant': offlineGrant,
    'offline_grant_public_key': offlineGrantPublicKey,
    'offline_grant_expires_at': offlineGrantExpiresAt
        ?.toUtc()
        .toIso8601String(),
  };

  factory RemoteSession.fromJson(Map<String, Object?> json) => RemoteSession(
    businessId: json['business_id'] as String,
    deviceId: json['device_id'] as String,
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
    accessExpiresAt: DateTime.parse(
      json['access_expires_at'] as String,
    ).toUtc(),
    refreshExpiresAt: DateTime.parse(
      json['refresh_expires_at'] as String,
    ).toUtc(),
    permissions: (json['permissions'] as List).cast<String>(),
    userId: json['user_id'] as String?,
    principalName: json['principal_name'] as String?,
    username: json['username'] as String?,
    roleType: json['role_type'] as String?,
    offlineGrant: json['offline_grant'] as String?,
    offlineGrantPublicKey: json['offline_grant_public_key'] as String?,
    offlineGrantExpiresAt: json['offline_grant_expires_at'] == null
        ? null
        : DateTime.parse(json['offline_grant_expires_at'] as String).toUtc(),
  );

  Future<OfflineAuthorization?> verifyOfflineAuthorization({
    DateTime? now,
  }) async {
    final token = offlineGrant;
    final publicKey = offlineGrantPublicKey;
    if (token == null || publicKey == null || userId == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 2) return null;
      final payloadBytes = base64Url.decode(base64Url.normalize(parts[0]));
      final payload = Map<String, Object?>.from(
        jsonDecode(utf8.decode(payloadBytes)) as Map,
      );
      final valid = await Ed25519().verify(
        utf8.encode(parts[0]),
        signature: Signature(
          base64Url.decode(base64Url.normalize(parts[1])),
          publicKey: SimplePublicKey(
            base64Url.decode(base64Url.normalize(publicKey)),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!valid ||
          payload['business_id'] != businessId ||
          payload['device_id'] != deviceId ||
          payload['principal_id'] != userId ||
          !const {
            'administrator',
            'operational',
          }.contains(payload['role_type'])) {
        return null;
      }
      final issuedAt = DateTime.parse(payload['issued_at'] as String).toUtc();
      final expiresAt = DateTime.parse(payload['expires_at'] as String).toUtc();
      final checkedAt = (now ?? DateTime.now()).toUtc();
      if (issuedAt.isAfter(checkedAt.add(const Duration(minutes: 5))) ||
          !expiresAt.isAfter(checkedAt) ||
          expiresAt.difference(issuedAt) > const Duration(hours: 72)) {
        return null;
      }
      return OfflineAuthorization(
        businessId: businessId,
        deviceId: deviceId,
        userId: userId!,
        principalName: payload['principal_name'] as String,
        username: payload['username'] as String,
        roleType: payload['role_type'] as String,
        permissions: (payload['permissions'] as List).cast<String>(),
        securityVersion: payload['security_version'] as int,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );
    } catch (_) {
      return null;
    }
  }
}

class OfflineAuthorization {
  const OfflineAuthorization({
    required this.businessId,
    required this.deviceId,
    required this.userId,
    required this.principalName,
    required this.username,
    required this.roleType,
    required this.permissions,
    required this.securityVersion,
    required this.issuedAt,
    required this.expiresAt,
  });
  final String businessId, deviceId, userId, principalName, username, roleType;
  final List<String> permissions;
  final int securityVersion;
  final DateTime issuedAt, expiresAt;
  bool can(String permission) => permissions.contains(permission);
}

abstract interface class SecureCredentialStore {
  Future<RemoteSession?> read();
  Future<void> write(RemoteSession session);
  Future<void> clear();
}

class PlatformSecureCredentialStore implements SecureCredentialStore {
  PlatformSecureCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            wOptions: WindowsOptions(useBackwardCompatibility: false),
          );

  static const _key = 'capc.remote.session.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<RemoteSession?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null || value.isEmpty) return null;
    try {
      return RemoteSession.fromJson(
        Map<String, Object?>.from(jsonDecode(value) as Map),
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(RemoteSession session) =>
      _storage.write(key: _key, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryCredentialStore implements SecureCredentialStore {
  RemoteSession? value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<RemoteSession?> read() async => value;
  @override
  Future<void> write(RemoteSession session) async => value = session;
}
