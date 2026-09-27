import 'dart:convert';
import 'dart:io';

import 'sync_models.dart';

typedef SyncTokenProvider = Future<String?> Function();

class SyncConfiguration {
  const SyncConfiguration({this.baseUri, this.tokenProvider});

  factory SyncConfiguration.fromEnvironment({
    SyncTokenProvider? tokenProvider,
  }) {
    const raw = String.fromEnvironment('CAPC_SYNC_URL');
    final uri = raw.trim().isEmpty ? null : Uri.tryParse(raw.trim());
    return SyncConfiguration(baseUri: uri, tokenProvider: tokenProvider);
  }

  final Uri? baseUri;
  final SyncTokenProvider? tokenProvider;

  bool get enabled =>
      baseUri != null &&
      (baseUri!.scheme == 'https' ||
          (baseUri!.scheme == 'http' && baseUri!.host == 'localhost'));
}

abstract interface class SyncTransport {
  Future<List<SyncPushAck>> push(List<SyncOperation> operations);

  Future<SyncPullPage> pull({
    required String businessId,
    required String deviceId,
    required int afterCursor,
    int limit = 200,
  });
}

class JsonHttpSyncTransport implements SyncTransport {
  JsonHttpSyncTransport(this.configuration, {HttpClient? client})
    : _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final SyncConfiguration configuration;
  final HttpClient _client;

  Uri _endpoint(String path, [Map<String, String>? query]) =>
      configuration.baseUri!.resolve(path).replace(queryParameters: query);

  Future<HttpClientRequest> _request(
    String method,
    Uri uri, {
    required String businessId,
  }) async {
    final request = await _client.openUrl(method, uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    request.headers.set('X-Business-Id', businessId);
    final token = await configuration.tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request;
  }

  Future<Map<String, Object?>> _decode(HttpClientResponse response) async {
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncTransportException('El servidor rechazó la sincronización.');
    }
    try {
      return Map<String, Object?>.from(jsonDecode(body) as Map);
    } on FormatException {
      throw SyncTransportException(
        'El servidor devolvió una respuesta inválida.',
      );
    }
  }

  @override
  Future<List<SyncPushAck>> push(List<SyncOperation> operations) async {
    if (!configuration.enabled) return const [];
    final request = await _request(
      'POST',
      _endpoint('/api/v1/sync/push'),
      businessId: operations.first.businessId,
    );
    request.write(
      jsonEncode({'operations': operations.map((e) => e.toJson()).toList()}),
    );
    final decoded = await _decode(await request.close());
    return (decoded['accepted'] as List)
        .map(
          (item) =>
              SyncPushAck.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }

  @override
  Future<SyncPullPage> pull({
    required String businessId,
    required String deviceId,
    required int afterCursor,
    int limit = 200,
  }) async {
    if (!configuration.enabled) {
      return SyncPullPage(
        operations: const [],
        nextCursor: afterCursor,
        hasMore: false,
      );
    }
    final request = await _request(
      'GET',
      _endpoint('/api/v1/sync/pull', {
        'business_id': businessId,
        'device_id': deviceId,
        'after': '$afterCursor',
        'limit': '$limit',
      }),
      businessId: businessId,
    );
    final decoded = await _decode(await request.close());
    return SyncPullPage(
      operations: (decoded['operations'] as List)
          .map(
            (item) =>
                SyncOperation.fromJson(Map<String, Object?>.from(item as Map)),
          )
          .toList(growable: false),
      nextCursor: decoded['next_cursor'] as int,
      hasMore: decoded['has_more'] as bool,
    );
  }
}

class SyncTransportException implements Exception {
  const SyncTransportException(this.message);
  final String message;
  @override
  String toString() => message;
}
