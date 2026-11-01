import 'dart:convert';

enum SyncStatus { localOnly, pending, syncing, synced, error }

extension SyncStatusWire on SyncStatus {
  String get wireName => switch (this) {
    SyncStatus.localOnly => 'local_only',
    SyncStatus.pending => 'pending',
    SyncStatus.syncing => 'syncing',
    SyncStatus.synced => 'synced',
    SyncStatus.error => 'error',
  };

  static SyncStatus parse(String value) => SyncStatus.values.firstWhere(
    (status) => status.wireName == value,
    orElse: () => SyncStatus.error,
  );
}

class SyncOperation {
  const SyncOperation({
    required this.businessId,
    required this.deviceId,
    required this.operationId,
    required this.type,
    required this.schemaVersion,
    required this.occurredAt,
    required this.content,
    this.serverCursor,
  });

  final String businessId;
  final String deviceId;
  final String operationId;
  final String type;
  final int schemaVersion;
  final DateTime occurredAt;
  final Map<String, Object?> content;
  final int? serverCursor;

  Map<String, Object?> toJson() => {
    'business_id': businessId,
    'device_id': deviceId,
    'operation_id': operationId,
    'type': type,
    'schema_version': schemaVersion,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'content': _toWireValue(content),
    if (serverCursor != null) 'server_cursor': serverCursor,
  };

  factory SyncOperation.fromJson(Map<String, Object?> json) => SyncOperation(
    businessId: json['business_id'] as String,
    deviceId: json['device_id'] as String,
    operationId: json['operation_id'] as String,
    type: json['type'] as String,
    schemaVersion: json['schema_version'] as int,
    occurredAt: DateTime.parse(json['occurred_at'] as String).toUtc(),
    content: Map<String, Object?>.from(_fromWireValue(json['content']) as Map),
    serverCursor: json['server_cursor'] as int?,
  );

  String canonicalContent() => jsonEncode(content);
}

const _maxSafeJsonInteger = 9007199254740991;

Object? _toWireValue(Object? value) {
  if (value is int &&
      (value > _maxSafeJsonInteger || value < -_maxSafeJsonInteger)) {
    return value.toString();
  }
  if (value is List) return value.map(_toWireValue).toList(growable: false);
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _toWireValue(entry.value),
    };
  }
  return value;
}

Object? _fromWireValue(Object? value, [String key = '']) {
  if (value is String &&
      key.toLowerCase().contains('micros') &&
      RegExp(r'^-?[0-9]+$').hasMatch(value)) {
    return int.parse(value);
  }
  if (value is List) {
    return value.map((item) => _fromWireValue(item)).toList(growable: false);
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _fromWireValue(entry.value, entry.key.toString()),
    };
  }
  return value;
}

class SyncPushAck {
  const SyncPushAck({
    required this.operationId,
    required this.serverCursor,
    required this.duplicate,
    this.conflicts = 0,
  });

  final String operationId;
  final int serverCursor;
  final bool duplicate;
  final int conflicts;

  factory SyncPushAck.fromJson(Map<String, Object?> json) => SyncPushAck(
    operationId: json['operation_id'] as String,
    serverCursor: json['server_cursor'] as int,
    duplicate: json['duplicate'] as bool? ?? false,
    conflicts: json['conflicts'] as int? ?? 0,
  );
}

class SyncPullPage {
  const SyncPullPage({
    required this.operations,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<SyncOperation> operations;
  final int nextCursor;
  final bool hasMore;
}

class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.status,
    required this.cursor,
    required this.pending,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.lastError,
  });

  final SyncStatus status;
  final int cursor;
  final int pending;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final String? lastError;
}

class SyncRunResult {
  const SyncRunResult({
    required this.enabled,
    required this.pushed,
    required this.received,
    required this.applied,
    required this.conflicts,
    required this.cursor,
  });

  const SyncRunResult.disabled()
    : enabled = false,
      pushed = 0,
      received = 0,
      applied = 0,
      conflicts = 0,
      cursor = 0;

  final bool enabled;
  final int pushed;
  final int received;
  final int applied;
  final int conflicts;
  final int cursor;
}

class SyncApplyResult {
  const SyncApplyResult({required this.applied, required this.conflicts});
  final int applied;
  final int conflicts;
}

class SyncConflictRecord {
  const SyncConflictRecord({
    required this.id,
    required this.operationId,
    required this.kind,
    required this.entityId,
    required this.details,
    required this.createdAt,
    this.resolvedAt,
  });

  final String id, operationId, kind, entityId;
  final Map<String, Object?> details;
  final DateTime createdAt;
  final DateTime? resolvedAt;
}
