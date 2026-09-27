import 'dart:convert';

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
  });

  final String businessId;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final List<String> permissions;

  Map<String, Object?> toJson() => {
    'business_id': businessId,
    'device_id': deviceId,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
    'permissions': permissions,
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
  );
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
