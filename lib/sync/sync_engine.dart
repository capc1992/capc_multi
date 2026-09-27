import '../data/repository.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

class SyncEngine {
  SyncEngine({
    required this.repository,
    required this.configuration,
    SyncTransport? transport,
  }) : _transport =
           transport ??
           (configuration.enabled
               ? JsonHttpSyncTransport(configuration)
               : null);

  final CapcRepository repository;
  final SyncConfiguration configuration;
  final SyncTransport? _transport;
  bool _running = false;

  Future<SyncRunResult> runOnce({int batchSize = 100}) async {
    if (!configuration.enabled || _transport == null) {
      await repository.setSyncStatus(SyncStatus.localOnly);
      return const SyncRunResult.disabled();
    }
    if (_running) {
      throw const SyncTransportException('Ya hay una sincronización en curso.');
    }
    _running = true;
    var pushed = 0, received = 0, applied = 0, conflicts = 0;
    try {
      await repository.setSyncStatus(SyncStatus.syncing);
      final outgoing = await repository.prepareSyncPush(limit: batchSize);
      if (outgoing.isNotEmpty) {
        try {
          final acknowledgements = await _transport.push(outgoing);
          await repository.acknowledgeSyncPush(acknowledgements);
          pushed = acknowledgements.length;
        } catch (error) {
          await repository.failSyncPush(
            outgoing.map((event) => event.operationId),
            _safeError(error),
          );
          rethrow;
        }
      }
      var cursor = (await repository.syncStatus()).cursor;
      var more = true;
      while (more) {
        final page = await _transport.pull(
          businessId: repository.businessId,
          deviceId: repository.deviceId,
          afterCursor: cursor,
          limit: batchSize,
        );
        if (page.nextCursor < cursor ||
            (page.hasMore && page.nextCursor == cursor)) {
          throw const SyncTransportException(
            'El servidor devolvió un cursor de sincronización inválido.',
          );
        }
        final result = await repository.receiveSyncOperations(
          page.operations,
          nextCursor: page.nextCursor,
        );
        received += page.operations.length;
        applied += result.applied;
        conflicts += result.conflicts;
        cursor = page.nextCursor;
        more = page.hasMore;
      }
      await repository.setSyncStatus(
        (await repository.pendingSyncOperations()) == 0
            ? SyncStatus.synced
            : SyncStatus.pending,
        successful: true,
      );
      return SyncRunResult(
        enabled: true,
        pushed: pushed,
        received: received,
        applied: applied,
        conflicts: conflicts,
        cursor: cursor,
      );
    } catch (error) {
      await repository.setSyncStatus(
        SyncStatus.error,
        error: _safeError(error),
      );
      rethrow;
    } finally {
      _running = false;
    }
  }

  static String _safeError(Object error) {
    if (error is SyncTransportException) return error.message;
    return 'No se pudo completar la sincronización. Intenta de nuevo.';
  }
}
