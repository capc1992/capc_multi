part of '../data/repository.dart';

class _SyncDependencyException implements Exception {
  const _SyncDependencyException(this.message);
  final String message;
}

extension CapcSyncStore on CapcRepository {
  Future<int> pendingSyncOperations() => _run(() async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS amount FROM outbox WHERE business_id=? AND state!='acknowledged'",
      [businessId],
    );
    return rows.single['amount'] as int;
  });

  Future<SyncStatusSnapshot> syncStatus() => _run(() async {
    final rows = await _db.query(
      'sync_state',
      where: 'business_id = ?',
      whereArgs: [businessId],
    );
    final pending = await pendingSyncOperations();
    final row = rows.isEmpty
        ? <String, Object?>{'cursor': 0, 'status': 'local_only'}
        : rows.single;
    DateTime? date(String key) =>
        row[key] == null ? null : DateTime.parse(row[key] as String).toUtc();
    return SyncStatusSnapshot(
      status: SyncStatusWire.parse(row['status'] as String),
      cursor: row['cursor'] as int,
      pending: pending,
      lastAttemptAt: date('last_attempt_at'),
      lastSuccessAt: date('last_success_at'),
      lastError: row['last_error'] as String?,
    );
  });

  Future<void> setSyncStatus(
    SyncStatus status, {
    String? error,
    bool successful = false,
  }) => _run(() async {
    final now = CapcRepository._now();
    await _db.insert('sync_state', {
      'business_id': businessId,
      'cursor': 0,
      'status': status.wireName,
      'last_attempt_at': status == SyncStatus.localOnly ? null : now,
      'last_success_at': successful ? now : null,
      'last_error': error == null ? null : CapcSyncStore._syncError(error),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _db.update(
      'sync_state',
      {
        'status': status.wireName,
        if (status != SyncStatus.localOnly) 'last_attempt_at': now,
        if (successful) 'last_success_at': now,
        'last_error': error == null ? null : CapcSyncStore._syncError(error),
      },
      where: 'business_id = ?',
      whereArgs: [businessId],
    );
  });

  Future<List<SyncOperation>> prepareSyncPush({int limit = 100}) =>
      _run(() async {
        if (limit < 1 || limit > 500) {
          throw const CapcException(
            'El tamaño del lote de sincronización no es válido.',
          );
        }
        return _db.transaction((txn) async {
          final rows = await txn.query(
            'outbox',
            where: "business_id=? AND state!='acknowledged'",
            whereArgs: [businessId],
            orderBy: 'created_at,id',
            limit: limit,
          );
          final now = CapcRepository._now();
          final result = <SyncOperation>[];
          for (final row in rows) {
            final payload = Map<String, Object?>.from(
              jsonDecode(row['payload'] as String) as Map,
            );
            if (CapcSyncStore._containsSyncSecret(payload)) {
              await txn.update(
                'outbox',
                {
                  'state': 'error',
                  'last_error':
                      'El evento contiene campos que no se pueden sincronizar.',
                },
                where: 'id = ?',
                whereArgs: [row['id']],
              );
              continue;
            }
            await txn.update(
              'outbox',
              {
                'state': 'sending',
                'retry_count': (row['retry_count'] as int) + 1,
                'last_attempt_at': now,
                'last_error': null,
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
            result.add(
              SyncOperation(
                businessId: row['business_id'] as String,
                deviceId: row['device_id'] as String,
                operationId: row['operation_id'] as String,
                type: row['kind'] as String,
                schemaVersion: row['schema_version'] as int,
                occurredAt: DateTime.parse(row['created_at'] as String).toUtc(),
                content: payload,
              ),
            );
          }
          return result;
        });
      });

  Future<void> acknowledgeSyncPush(Iterable<SyncPushAck> acknowledgements) =>
      _run(() async {
        final now = CapcRepository._now();
        await _db.transaction((txn) async {
          for (final ack in acknowledgements) {
            await txn.update(
              'outbox',
              {
                'state': 'acknowledged',
                'acknowledged_at': now,
                'server_cursor': ack.serverCursor,
                'last_error': null,
              },
              where: 'business_id=? AND operation_id=?',
              whereArgs: [businessId, ack.operationId],
            );
          }
        });
      });

  Future<void> failSyncPush(
    Iterable<String> operationIds,
    String error,
  ) => _run(() async {
    final ids = operationIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      "UPDATE outbox SET state='error',last_error=? WHERE business_id=? AND operation_id IN ($placeholders)",
      [CapcSyncStore._syncError(error), businessId, ...ids],
    );
  });

  Future<SyncApplyResult> receiveSyncOperations(
    Iterable<SyncOperation> operations, {
    required int nextCursor,
  }) => _run(() async {
    if (nextCursor < 0) {
      throw const CapcException('El cursor remoto no es válido.');
    }
    return _db.transaction((txn) async {
      final now = CapcRepository._now();
      for (final operation in operations) {
        if (operation.businessId != businessId ||
            operation.serverCursor == null ||
            operation.serverCursor! < 1 ||
            operation.schemaVersion != 1 ||
            CapcSyncStore._containsSyncSecret(operation.content)) {
          throw const CapcException(
            'El servidor devolvió una operación no válida.',
          );
        }
        await txn.insert('inbox', {
          'id': CapcRepository._uuid.v4(),
          'business_id': businessId,
          'device_id': operation.deviceId,
          'operation_id': operation.operationId,
          'server_cursor': operation.serverCursor,
          'kind': operation.type,
          'schema_version': operation.schemaVersion,
          'payload': jsonEncode(operation.content),
          'occurred_at': operation.occurredAt.toIso8601String(),
          'received_at': now,
          'state': 'received',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final pending = (await txn.query(
        'inbox',
        where: "business_id=? AND state='received'",
        whereArgs: [businessId],
      )).toList(growable: true);
      pending.sort((a, b) {
        final type = CapcSyncStore._syncPriority(
          a['kind'] as String,
        ).compareTo(CapcSyncStore._syncPriority(b['kind'] as String));
        return type != 0
            ? type
            : (a['server_cursor'] as int).compareTo(b['server_cursor'] as int);
      });
      var applied = 0, conflicts = 0;
      for (final row in pending) {
        final operation = SyncOperation(
          businessId: businessId,
          deviceId: row['device_id'] as String,
          operationId: row['operation_id'] as String,
          type: row['kind'] as String,
          schemaVersion: row['schema_version'] as int,
          occurredAt: DateTime.parse(row['occurred_at'] as String).toUtc(),
          content: Map<String, Object?>.from(
            jsonDecode(row['payload'] as String) as Map,
          ),
          serverCursor: row['server_cursor'] as int,
        );
        try {
          final conflict = await _applySyncOperation(txn, operation);
          await txn.update(
            'inbox',
            {
              'state': conflict ? 'conflict' : 'applied',
              'applied_at': CapcRepository._now(),
              'last_error': null,
            },
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          if (conflict) {
            conflicts++;
          } else {
            applied++;
          }
        } on _SyncDependencyException catch (error) {
          await txn.update(
            'inbox',
            {'last_error': CapcSyncStore._syncError(error.message)},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        } on DatabaseException catch (_) {
          await _recordSyncConflict(
            txn,
            operation,
            'apply.failed',
            operation.operationId,
            {'reason': 'La operación entra en conflicto con datos locales.'},
          );
          await txn.update(
            'inbox',
            {
              'state': 'conflict',
              'applied_at': CapcRepository._now(),
              'last_error':
                  'La operación entra en conflicto con datos locales.',
            },
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          conflicts++;
        }
      }
      final state = await txn.query(
        'sync_state',
        where: 'business_id = ?',
        whereArgs: [businessId],
      );
      final previous = state.isEmpty ? 0 : state.single['cursor'] as int;
      await txn.insert('sync_state', {
        'business_id': businessId,
        'cursor': previous > nextCursor ? previous : nextCursor,
        'status': 'syncing',
        'last_attempt_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return SyncApplyResult(applied: applied, conflicts: conflicts);
    });
  });

  static int _syncPriority(String type) {
    if (type == 'product.saved' ||
        type == 'customer.saved' ||
        type == 'supplier.saved') {
      return 0;
    }
    if (type == 'cash.opened' || type.startsWith('quote.')) return 1;
    if (type == 'purchase.created' || type.startsWith('work.')) return 2;
    if (type == 'stock.adjusted' ||
        type == 'purchase.received' ||
        type == 'sale.created') {
      return 3;
    }
    return 4;
  }

  Future<bool> _applySyncOperation(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    switch (operation.type) {
      case 'product.saved':
        return _applySyncProduct(txn, operation);
      case 'customer.saved':
        return _applySyncCustomer(txn, operation);
      case 'supplier.saved':
        return _applySyncSupplier(txn, operation);
      case 'purchase.created':
      case 'purchase.received':
      case 'supplier.payment':
        return _applySyncPurchase(txn, operation);
      case 'sale.return':
      case 'sale.cancel':
        return _applySyncReturn(txn, operation);
      case 'cash.opened':
      case 'cash.closed':
      case 'cash.adjustment':
      case 'expense':
        return _applySyncCash(txn, operation);
      case 'quote.created':
      case 'quote.updated':
      case 'quote.status':
      case 'quote.converted':
        return _applySyncQuote(txn, operation);
      case 'work.created':
      case 'work.updated':
      case 'work.advance':
      case 'work.advanceApplied':
        return _applySyncWork(txn, operation);
      case 'sale.created':
        return _applySyncSale(txn, operation);
      case 'payment.added':
        return _applySyncPayment(txn, operation);
      case 'stock.adjusted':
        return _applySyncMovement(
          txn,
          operation,
          operation.content['movement'],
        );
      default:
        // The canonical event is retained in inbox even when this client
        // version has no materializer yet. No financial event is overwritten.
        return false;
    }
  }

  Future<bool> _applySyncProduct(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final data = operation.content;
    final id = data['id'] as String;
    final revision = data['revision'] as int? ?? 1;
    final rows = await txn.query(
      'products',
      where: 'id=? AND business_id=?',
      whereArgs: [id, businessId],
    );
    if (rows.isNotEmpty) {
      final local = rows.single;
      final localRevision = local['revision'] as int;
      if (revision < localRevision ||
          (revision == localRevision &&
              local['updated_at'] != data['updated_at'])) {
        await _recordSyncConflict(txn, operation, 'revision.stale', id, {
          'local_revision': localRevision,
          'remote_revision': revision,
        });
        return true;
      }
      if (revision == localRevision) return false;
      await txn.update(
        'products',
        {
          for (final key in const [
            'code',
            'name',
            'unit',
            'category',
            'is_service',
            'purchase_price',
            'sale_price',
            'minimum_stock',
            'cost_known',
            'updated_at',
            'revision',
          ])
            if (data.containsKey(key)) key: data[key],
          'device_id': operation.deviceId,
        },
        where: 'id=? AND business_id=?',
        whereArgs: [id, businessId],
      );
      return false;
    }
    await txn.insert('products', {
      'id': id,
      'business_id': businessId,
      'device_id': operation.deviceId,
      'code': data['code'],
      'name': data['name'],
      'unit': data['unit'],
      'category': data['category'] ?? '',
      'is_service': data['is_service'],
      'purchase_price': data['purchase_price'],
      'sale_price': data['sale_price'],
      'stock': 0,
      'minimum_stock': data['minimum_stock'] ?? 0,
      'inventory_value_micros': 0,
      'cost_known': data['cost_known'] ?? 1,
      'cost_basis': 'weighted',
      'updated_at': data['updated_at'],
      'revision': revision,
    });
    return false;
  }

  Future<bool> _applySyncCustomer(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final data = operation.content;
    final id = data['id'] as String;
    final revision = data['revision'] as int? ?? 1;
    final rows = await txn.query(
      'customers',
      where: 'id=? AND business_id=?',
      whereArgs: [id, businessId],
    );
    if (rows.isNotEmpty) {
      final local = rows.single;
      final localRevision = local['revision'] as int;
      if (revision < localRevision ||
          (revision == localRevision &&
              local['updated_at'] != data['updated_at'])) {
        await _recordSyncConflict(txn, operation, 'revision.stale', id, {
          'local_revision': localRevision,
          'remote_revision': revision,
        });
        return true;
      }
      if (revision == localRevision) return false;
      await txn.update(
        'customers',
        {
          'name': data['name'],
          'phone': data['phone'] ?? '',
          'updated_at': data['updated_at'],
          'revision': revision,
          'device_id': operation.deviceId,
        },
        where: 'id=? AND business_id=?',
        whereArgs: [id, businessId],
      );
      return false;
    }
    await txn.insert('customers', {
      'id': id,
      'business_id': businessId,
      'device_id': operation.deviceId,
      'name': data['name'],
      'phone': data['phone'] ?? '',
      'updated_at': data['updated_at'],
      'revision': revision,
    });
    return false;
  }

  Future<bool> _applySyncSupplier(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final data = operation.content;
    final id = data['id'] as String;
    final revision = data['revision'] as int? ?? 1;
    final existing = await txn.query(
      'suppliers',
      where: 'id=? AND business_id=?',
      whereArgs: [id, businessId],
    );
    if (existing.isNotEmpty) {
      final localRevision = existing.single['revision'] as int;
      if (revision < localRevision ||
          (revision == localRevision &&
              existing.single['updated_at'] != data['updated_at'])) {
        await _recordSyncConflict(txn, operation, 'revision.stale', id, {
          'local_revision': localRevision,
          'remote_revision': revision,
        });
        return true;
      }
      if (revision == localRevision) return false;
      await txn.update(
        'suppliers',
        {
          for (final key in const [
            'name',
            'phone',
            'document',
            'address',
            'updated_at',
            'revision',
          ])
            key: data[key],
        },
        where: 'id=? AND business_id=?',
        whereArgs: [id, businessId],
      );
      return false;
    }
    await txn.insert('suppliers', {...data, 'business_id': businessId});
    return false;
  }

  Future<bool> _applySyncPurchase(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final payload = operation.content;
    if (operation.type == 'purchase.created') {
      final raw = payload['purchase'];
      if (raw is! Map) return false;
      final purchase = Map<String, Object?>.from(raw);
      final id = purchase['id'] as String;
      if ((await txn.query(
        'purchases',
        where: 'id=?',
        whereArgs: [id],
      )).isEmpty) {
        final supplierId = purchase['supplier_id'] as String;
        if ((await txn.query(
          'suppliers',
          where: 'id=?',
          whereArgs: [supplierId],
        )).isEmpty) {
          throw const _SyncDependencyException(
            'Falta el proveedor de la compra.',
          );
        }
        final lines = _syncMaps(payload['purchaseLines']);
        for (final line in lines) {
          if ((await txn.query(
            'products',
            where: 'id=?',
            whereArgs: [line['product_id']],
          )).isEmpty) {
            throw const _SyncDependencyException(
              'Falta un producto de la compra.',
            );
          }
        }
        await txn.insert('purchases', {
          ...purchase,
          'business_id': businessId,
          'device_id': operation.deviceId,
        });
        for (final line in lines) {
          await txn.insert('purchase_lines', line);
        }
        for (final payment in _syncMaps(payload['payments'])) {
          await txn.insert('supplier_payments', {
            ...payment,
            'business_id': businessId,
            'device_id': operation.deviceId,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final movement in _syncMaps(payload['cashMovements'])) {
          await _applySyncCashMovement(txn, operation, movement);
        }
      }
      return false;
    }
    final purchaseId = payload['purchaseId'] as String;
    if ((await txn.query(
      'purchases',
      where: 'id=?',
      whereArgs: [purchaseId],
    )).isEmpty) {
      throw const _SyncDependencyException('Falta la compra del evento.');
    }
    if (operation.type == 'purchase.received') {
      await txn.update(
        'purchases',
        {'received_at': payload['receivedAt']},
        where: 'id=? AND received_at IS NULL',
        whereArgs: [purchaseId],
      );
      var conflict = false;
      for (final movement in _syncMaps(payload['stockMovements'])) {
        conflict =
            await _applySyncMovement(txn, operation, movement) || conflict;
      }
      return conflict;
    }
    final rawPayment = payload['payment'];
    if (rawPayment is Map) {
      final payment = Map<String, Object?>.from(rawPayment);
      final exists = await txn.query(
        'supplier_payments',
        where: 'id=?',
        whereArgs: [payment['id']],
      );
      if (exists.isEmpty) {
        await txn.insert('supplier_payments', {
          ...payment,
          'business_id': businessId,
          'device_id': operation.deviceId,
        });
        await txn.rawUpdate('UPDATE purchases SET paid=paid+? WHERE id=?', [
          payment['amount'],
          purchaseId,
        ]);
      }
    }
    await _applySyncCashMovement(txn, operation, payload['cashMovement']);
    return false;
  }

  Future<bool> _applySyncReturn(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final payload = operation.content;
    final saleId = payload['saleId'] as String;
    if ((await txn.query(
      'sales',
      where: 'id=?',
      whereArgs: [saleId],
    )).isEmpty) {
      throw const _SyncDependencyException('Falta la venta de la devolución.');
    }
    final rawReturn = payload['return'];
    if (rawReturn is Map) {
      final record = Map<String, Object?>.from(rawReturn);
      final id = record['id'] as String;
      if ((await txn.query(
        'sale_returns',
        where: 'id=?',
        whereArgs: [id],
      )).isEmpty) {
        await txn.insert('sale_returns', {
          ...record,
          'business_id': businessId,
          'device_id': operation.deviceId,
        });
        for (final line in _syncMaps(payload['lines'])) {
          await txn.insert('sale_return_lines', {
            ...line,
            'business_id': businessId,
          });
          await txn.rawUpdate(
            'UPDATE sale_lines SET returned_quantity=returned_quantity+?,recovered_cost_micros=recovered_cost_micros+? WHERE id=?',
            [
              line['quantity'],
              line['cost_reversed_micros'],
              line['sale_line_id'],
            ],
          );
        }
        await txn.rawUpdate(
          'UPDATE sales SET returned_total=returned_total+?,paid=paid-?,refunded=refunded+?,cancelled=? WHERE id=?',
          [
            payload['amount'],
            payload['refund'],
            payload['refund'],
            record['cancelled'],
            saleId,
          ],
        );
        for (final payment in _syncMaps(payload['refundPayments'])) {
          await txn.insert('payments', {
            ...payment,
            'business_id': businessId,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    }
    var conflict = false;
    for (final movement in _syncMaps(payload['stockMovements'])) {
      conflict = await _applySyncMovement(txn, operation, movement) || conflict;
    }
    for (final movement in _syncMaps(payload['cashMovements'])) {
      await _applySyncCashMovement(txn, operation, movement);
    }
    return conflict;
  }

  Future<bool> _applySyncCash(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final payload = operation.content;
    if (operation.type == 'cash.opened') {
      final raw = payload['session'];
      if (raw is Map) {
        await txn.insert('cash_sessions', {
          ...Map<String, Object?>.from(raw),
          'business_id': businessId,
          'device_id': operation.deviceId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return false;
    }
    if (operation.type == 'cash.closed') {
      final raw = payload['session'];
      if (raw is Map) {
        final session = Map<String, Object?>.from(raw);
        await txn.update(
          'cash_sessions',
          session,
          where: 'id=? AND business_id=?',
          whereArgs: [session['id'], businessId],
        );
      }
      return false;
    }
    await _applySyncCashMovement(txn, operation, payload['cashMovement']);
    final rawExpense = payload['expense'];
    if (rawExpense is Map) {
      await txn.insert('expenses', {
        ...Map<String, Object?>.from(rawExpense),
        'business_id': businessId,
        'device_id': operation.deviceId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    return false;
  }

  Future<void> _applySyncCashMovement(
    DatabaseExecutor txn,
    SyncOperation operation,
    Object? raw,
  ) async {
    if (raw is! Map) return;
    final movement = Map<String, Object?>.from(raw);
    if ((await txn.query(
      'cash_sessions',
      where: 'id=?',
      whereArgs: [movement['session_id']],
    )).isEmpty) {
      throw const _SyncDependencyException(
        'Falta la sesión de caja del movimiento.',
      );
    }
    await txn.insert('cash_movements', {
      ...movement,
      'business_id': businessId,
      'device_id': operation.deviceId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<bool> _applySyncQuote(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final payload = operation.content;
    final raw = payload['quote'];
    if (raw is! Map) {
      final id = payload['quoteId'] as String;
      if ((await txn.query('quotes', where: 'id=?', whereArgs: [id])).isEmpty) {
        throw const _SyncDependencyException('Falta la cotización del evento.');
      }
      await txn.update(
        'quotes',
        {
          if (payload.containsKey('status')) 'status': payload['status'],
          if (payload.containsKey('saleId')) 'sale_id': payload['saleId'],
          if (payload.containsKey('revision')) 'revision': payload['revision'],
          'updated_at': operation.occurredAt.toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      return false;
    }
    final quote = Map<String, Object?>.from(raw);
    final id = quote['id'] as String;
    final revision = quote['revision'] as int;
    final existing = await txn.query('quotes', where: 'id=?', whereArgs: [id]);
    if (existing.isNotEmpty) {
      final localRevision = existing.single['revision'] as int;
      final terminal = const {
        'converted',
        'rejected',
        'expired',
      }.contains(existing.single['status']);
      if (terminal && existing.single['status'] != quote['status']) {
        await _recordSyncConflict(txn, operation, 'quote.terminal', id, {
          'local_status': existing.single['status'],
          'remote_status': quote['status'],
        });
        return true;
      }
      if (revision <= localRevision) return false;
      await txn.update(
        'quotes',
        {...quote, 'business_id': businessId},
        where: 'id=?',
        whereArgs: [id],
      );
      if (payload['quoteLines'] is List) {
        await txn.delete('quote_lines', where: 'quote_id=?', whereArgs: [id]);
        for (final line in _syncMaps(payload['quoteLines'])) {
          await txn.insert('quote_lines', line);
        }
      }
      return false;
    }
    if ((await txn.query(
      'customers',
      where: 'id=?',
      whereArgs: [quote['customer_id']],
    )).isEmpty) {
      throw const _SyncDependencyException(
        'Falta el cliente de la cotización.',
      );
    }
    await txn.insert('quotes', {
      ...quote,
      'business_id': businessId,
      'device_id': operation.deviceId,
    });
    for (final line in _syncMaps(payload['quoteLines'])) {
      await txn.insert('quote_lines', line);
    }
    return false;
  }

  Future<bool> _applySyncWork(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final payload = operation.content;
    if (operation.type == 'work.advance') {
      final raw = payload['advance'];
      if (raw is! Map) return false;
      final advance = Map<String, Object?>.from(raw);
      if ((await txn.query(
        'work_orders',
        where: 'id=?',
        whereArgs: [advance['work_id']],
      )).isEmpty) {
        throw const _SyncDependencyException('Falta el trabajo del anticipo.');
      }
      await txn.insert('work_advances', {
        ...advance,
        'business_id': businessId,
        'device_id': operation.deviceId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await _applySyncCashMovement(txn, operation, payload['cashMovement']);
      return false;
    }
    if (operation.type == 'work.advanceApplied') {
      final workId = payload['workId'] as String;
      final saleId = payload['saleId'] as String;
      if ((await txn.query(
            'work_orders',
            where: 'id=?',
            whereArgs: [workId],
          )).isEmpty ||
          (await txn.query(
            'sales',
            where: 'id=?',
            whereArgs: [saleId],
          )).isEmpty) {
        throw const _SyncDependencyException(
          'Falta el trabajo o la venta del anticipo.',
        );
      }
      for (final id in (payload['advanceIds'] as List? ?? const [])) {
        await txn.update(
          'work_advances',
          {
            'sale_id': saleId,
            'applied_at': operation.occurredAt.toIso8601String(),
          },
          where: 'id=?',
          whereArgs: [id],
        );
      }
      await txn.rawUpdate('UPDATE sales SET prepaid=prepaid+? WHERE id=?', [
        payload['amount'],
        saleId,
      ]);
      await txn.update(
        'work_orders',
        {
          'sale_id': saleId,
          'updated_at': operation.occurredAt.toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [workId],
      );
      return false;
    }
    final raw = payload['work'];
    if (raw is! Map) return false;
    final work = Map<String, Object?>.from(raw);
    final id = work['id'] as String;
    final revision =
        work['revision'] as int? ?? payload['revision'] as int? ?? 1;
    final existing = await txn.query(
      'work_orders',
      where: 'id=?',
      whereArgs: [id],
    );
    if (existing.isNotEmpty) {
      final localRevision = existing.single['revision'] as int;
      if (revision <= localRevision) return false;
      await txn.update(
        'work_orders',
        {...work, 'business_id': businessId},
        where: 'id=?',
        whereArgs: [id],
      );
      return false;
    }
    if ((await txn.query(
      'customers',
      where: 'id=?',
      whereArgs: [work['customer_id']],
    )).isEmpty) {
      throw const _SyncDependencyException('Falta el cliente del trabajo.');
    }
    await txn.insert('work_orders', {
      ...work,
      'revision': revision,
      'business_id': businessId,
      'device_id': operation.deviceId,
    });
    return false;
  }

  Future<bool> _applySyncSale(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final payload = operation.content;
    final rawSale = payload['sale'];
    if (rawSale is! Map) return false;
    final sale = Map<String, Object?>.from(rawSale);
    final saleId = sale['id'] as String;
    final existing = await txn.query(
      'sales',
      where: 'id=?',
      whereArgs: [saleId],
    );
    if (existing.isEmpty) {
      final customerId = sale['customer_id'] as String?;
      if (customerId != null &&
          (await txn.query(
            'customers',
            where: 'id=?',
            whereArgs: [customerId],
          )).isEmpty) {
        throw const _SyncDependencyException('Falta el cliente de la venta.');
      }
      final saleLines = _syncMaps(payload['saleLines']);
      for (final line in saleLines) {
        final productId = line['product_id'] as String?;
        if (productId != null &&
            (await txn.query(
              'products',
              where: 'id=?',
              whereArgs: [productId],
            )).isEmpty) {
          throw const _SyncDependencyException(
            'Falta un producto de la venta.',
          );
        }
      }
      await txn.insert('sales', {...sale, 'business_id': businessId});
      for (final line in saleLines) {
        await txn.insert('sale_lines', {...line, 'business_id': businessId});
      }
      for (final consumption in _syncMaps(payload['consumptions'])) {
        await txn.insert('sale_consumptions', {
          ...consumption,
          'business_id': businessId,
        });
      }
      for (final payment in _syncMaps(payload['payments'])) {
        await txn.insert('payments', {...payment, 'business_id': businessId});
      }
      for (final movement in _syncMaps(payload['cashMovements'])) {
        await _applySyncCashMovement(txn, operation, movement);
      }
    }
    var conflict = false;
    for (final movement in _syncMaps(payload['stockMovements'])) {
      conflict = await _applySyncMovement(txn, operation, movement) || conflict;
    }
    return conflict;
  }

  Future<bool> _applySyncPayment(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final raw = operation.content['payment'];
    if (raw is! Map) return false;
    final payment = Map<String, Object?>.from(raw);
    final id = payment['id'] as String;
    if ((await txn.query(
      'payments',
      where: 'id=?',
      whereArgs: [id],
    )).isNotEmpty) {
      return false;
    }
    final saleId = payment['sale_id'] as String;
    if ((await txn.query(
      'sales',
      where: 'id=?',
      whereArgs: [saleId],
    )).isEmpty) {
      throw const _SyncDependencyException('Falta la venta del abono.');
    }
    await txn.insert('payments', {...payment, 'business_id': businessId});
    await txn.rawUpdate('UPDATE sales SET paid=paid+? WHERE id=?', [
      payment['amount'],
      saleId,
    ]);
    await _applySyncCashMovement(
      txn,
      operation,
      operation.content['cashMovement'],
    );
    return false;
  }

  Future<bool> _applySyncMovement(
    DatabaseExecutor txn,
    SyncOperation operation,
    Object? raw,
  ) async {
    if (raw is! Map) return false;
    final movement = Map<String, Object?>.from(raw);
    final id = movement['id'] as String;
    if ((await txn.query(
      'stock_movements',
      where: 'id=?',
      whereArgs: [id],
    )).isNotEmpty) {
      return false;
    }
    final productId = movement['product_id'] as String;
    final products = await txn.query(
      'products',
      where: 'id=?',
      whereArgs: [productId],
    );
    if (products.isEmpty) {
      throw const _SyncDependencyException('Falta el producto del movimiento.');
    }
    await txn.insert('stock_movements', {
      ...movement,
      'business_id': businessId,
      'device_id': operation.deviceId,
    });
    final product = products.single;
    final delta = movement['delta'] as int;
    final next = (product['stock'] as int) + delta;
    if (next < 0) {
      await _recordSyncConflict(
        txn,
        operation,
        'inventory.negative',
        productId,
        {
          'local_stock': product['stock'],
          'delta': delta,
          'result': next,
          'movement_id': id,
        },
      );
      return true;
    }
    final value = product['inventory_value_micros'] as int;
    final cost = movement['cost_micros'] as int? ?? 0;
    final nextValue = delta > 0 ? value + cost : (value - cost).clamp(0, value);
    await txn.update(
      'products',
      {'stock': next, 'inventory_value_micros': nextValue},
      where: 'id=?',
      whereArgs: [productId],
    );
    return false;
  }

  Future<void> _recordSyncConflict(
    DatabaseExecutor txn,
    SyncOperation operation,
    String kind,
    String entityId,
    Map<String, Object?> details,
  ) async {
    await txn.insert('sync_conflicts', {
      'id': CapcRepository._uuid.v4(),
      'business_id': businessId,
      'operation_id': operation.operationId,
      'kind': kind,
      'entity_id': entityId,
      'details': jsonEncode(details),
      'created_at': CapcRepository._now(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static List<Map<String, Object?>> _syncMaps(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((item) => Map<String, Object?>.from(item))
            .toList(growable: false)
      : const [];

  static bool _containsSyncSecret(Object? value) {
    const forbidden = {
      'password',
      'password_hash',
      'password_salt',
      'recovery_code',
      'recovery_hash',
      'token',
      'access_token',
      'refresh_token',
      'secret',
    };
    if (value is Map) {
      for (final entry in value.entries) {
        if (forbidden.contains(entry.key.toString().toLowerCase()) ||
            CapcSyncStore._containsSyncSecret(entry.value)) {
          return true;
        }
      }
    } else if (value is Iterable) {
      return value.any(_containsSyncSecret);
    }
    return false;
  }

  static String _syncError(String value) {
    final normalized = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    return normalized.length <= 500 ? normalized : normalized.substring(0, 500);
  }
}
