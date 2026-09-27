import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'update_models.dart';

class UpdateSecurityPolicy {
  UpdateSecurityPolicy({required Iterable<String> allowedHosts})
    : allowedHosts = allowedHosts.map((value) => value.toLowerCase()).toSet();

  final Set<String> allowedHosts;

  void validate(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https') {
      throw const UpdateException('Las actualizaciones requieren HTTPS.');
    }
    if (!allowedHosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty) {
      throw const UpdateException(
        'El dominio de actualización no está autorizado.',
      );
    }
    if (uri.port != 443) {
      throw const UpdateException(
        'El puerto de actualización no está autorizado.',
      );
    }
  }

  Uri validateRedirect(Uri source, String? location) {
    if (location == null || location.trim().isEmpty) {
      throw const UpdateException(
        'El servidor devolvió una redirección inválida.',
      );
    }
    final target = source.resolve(location);
    validate(target);
    return target;
  }
}

abstract interface class UpdateTransport {
  Future<Uint8List> getBytes(Uri uri, {required int maximumBytes});

  Future<int> download(
    Uri uri,
    File destination, {
    required int maximumBytes,
    required void Function(int received, int? total) onProgress,
  });
}

class HttpUpdateTransport implements UpdateTransport {
  HttpUpdateTransport({
    required this.policy,
    this.timeout = const Duration(seconds: 20),
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final UpdateSecurityPolicy policy;
  final Duration timeout;
  final HttpClient _client;

  @override
  Future<Uint8List> getBytes(Uri uri, {required int maximumBytes}) async {
    final response = await _open(uri);
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in response.timeout(timeout)) {
        length += chunk.length;
        if (length > maximumBytes) {
          throw const UpdateException(
            'La respuesta de actualización es demasiado grande.',
          );
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on SocketException {
      throw const UpdateException(
        'No hay conexión para buscar actualizaciones.',
        offline: true,
      );
    } on TimeoutException {
      throw const UpdateException(
        'La comprobación de actualizaciones agotó el tiempo de espera.',
      );
    }
  }

  @override
  Future<int> download(
    Uri uri,
    File destination, {
    required int maximumBytes,
    required void Function(int received, int? total) onProgress,
  }) async {
    final response = await _open(uri);
    final advertised = response.contentLength >= 0
        ? response.contentLength
        : null;
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    var received = 0;
    try {
      await for (final chunk in response.timeout(timeout)) {
        received += chunk.length;
        if (received > maximumBytes) {
          throw const UpdateException(
            'La descarga superó el tamaño publicado.',
          );
        }
        sink.add(chunk);
        onProgress(received, advertised);
      }
      await sink.flush();
      await sink.close();
      return received;
    } on SocketException {
      await sink.close();
      throw const UpdateException(
        'La descarga se interrumpió por falta de conexión.',
        offline: true,
      );
    } on TimeoutException {
      await sink.close();
      throw const UpdateException('La descarga agotó el tiempo de espera.');
    } catch (_) {
      await sink.close();
      rethrow;
    }
  }

  Future<HttpClientResponse> _open(Uri initial) async {
    var current = initial;
    for (var redirects = 0; redirects <= 3; redirects++) {
      policy.validate(current);
      try {
        final request = await _client.getUrl(current).timeout(timeout);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/json, application/octet-stream',
        );
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'CAPC-MULTISERVICIO-Updater/1',
        );
        final response = await request.close().timeout(timeout);
        if (response.isRedirect) {
          await response.drain<void>().timeout(timeout);
          if (redirects == 3) {
            throw const UpdateException(
              'El servidor excedió el límite de redirecciones.',
            );
          }
          current = policy.validateRedirect(
            current,
            response.headers.value(HttpHeaders.locationHeader),
          );
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>().timeout(timeout);
          throw UpdateException(
            'El servidor de actualizaciones respondió ${response.statusCode}.',
          );
        }
        return response;
      } on SocketException {
        throw const UpdateException(
          'No hay conexión para buscar actualizaciones.',
          offline: true,
        );
      } on TimeoutException {
        throw const UpdateException(
          'La conexión de actualización agotó el tiempo de espera.',
        );
      } on HandshakeException {
        throw const UpdateException(
          'No se pudo verificar la conexión HTTPS del actualizador.',
        );
      }
    }
    throw const UpdateException(
      'No se pudo abrir la dirección de actualización.',
    );
  }
}
