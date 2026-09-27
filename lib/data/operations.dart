part of 'repository.dart';

/// Kept in the repository library so all documents participate in the same
/// transaction, permission checks, inventory ledger and cash register.
Future<void> createOperationsSchema(DatabaseExecutor db) async {
  for (final statement in _operationsSchema) {
    await db.execute(statement);
  }
  for (final name in ['purchase', 'quote', 'work']) {
    await db.insert('counters', {
      'name': name,
      'value': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

const _operationsSchema = <String>[
  '''CREATE TABLE IF NOT EXISTS suppliers (
    id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL,
    name TEXT NOT NULL, phone TEXT NOT NULL, document TEXT NOT NULL,
    address TEXT NOT NULL, updated_at TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS purchases (
    id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
    number TEXT NOT NULL UNIQUE, supplier_id TEXT NOT NULL REFERENCES suppliers(id),
    supplier_name TEXT NOT NULL, reference TEXT NOT NULL,
    created_at TEXT NOT NULL, due_at TEXT, received_at TEXT,
    total INTEGER NOT NULL CHECK(total>=0), paid INTEGER NOT NULL CHECK(paid>=0 AND paid<=total),
    actor_id TEXT NOT NULL, operator_name TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS purchase_lines (
    id TEXT PRIMARY KEY NOT NULL, purchase_id TEXT NOT NULL REFERENCES purchases(id),
    position INTEGER NOT NULL, product_id TEXT NOT NULL REFERENCES products(id),
    code TEXT NOT NULL, name TEXT NOT NULL, unit TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK(quantity>0), total_cost INTEGER NOT NULL CHECK(total_cost>=0),
    UNIQUE(purchase_id,position))''',
  '''CREATE TABLE IF NOT EXISTS supplier_payments (
    id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
    purchase_id TEXT NOT NULL REFERENCES purchases(id), amount INTEGER NOT NULL CHECK(amount>0),
    method TEXT NOT NULL, created_at TEXT NOT NULL,
    actor_id TEXT NOT NULL, operator_name TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS quotes (
    id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
    number TEXT NOT NULL UNIQUE, customer_id TEXT NOT NULL REFERENCES customers(id),
    customer_name TEXT NOT NULL, description TEXT NOT NULL, created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL, valid_until TEXT NOT NULL, conditions TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('draft','sent','accepted','rejected','expired','converted')),
    total INTEGER NOT NULL CHECK(total>=0), sale_id TEXT UNIQUE REFERENCES sales(id),
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),
    actor_id TEXT NOT NULL, operator_name TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS quote_lines (
    id TEXT PRIMARY KEY NOT NULL, quote_id TEXT NOT NULL REFERENCES quotes(id), position INTEGER NOT NULL,
    product_id TEXT REFERENCES products(id), code TEXT NOT NULL, description TEXT NOT NULL, unit TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK(quantity>0), unit_price INTEGER NOT NULL CHECK(unit_price>=0),
    direct_cost INTEGER CHECK(direct_cost>=0), UNIQUE(quote_id,position))''',
  '''CREATE TABLE IF NOT EXISTS work_orders (
    id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
    number TEXT NOT NULL UNIQUE, customer_id TEXT NOT NULL REFERENCES customers(id),
    customer_name TEXT NOT NULL, description TEXT NOT NULL, created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('received','inProgress','ready','delivered')),
    responsible TEXT NOT NULL, delivery_at TEXT NOT NULL,
    quote_id TEXT UNIQUE REFERENCES quotes(id), sale_id TEXT REFERENCES sales(id), actor_id TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS work_advances (
    id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
    work_id TEXT NOT NULL REFERENCES work_orders(id), amount INTEGER NOT NULL CHECK(amount>0),
    received INTEGER NOT NULL CHECK(received>=amount), method TEXT NOT NULL, created_at TEXT NOT NULL,
    sale_id TEXT REFERENCES sales(id), applied_at TEXT, actor_id TEXT NOT NULL, operator_name TEXT NOT NULL,
    CHECK((sale_id IS NULL AND applied_at IS NULL) OR (sale_id IS NOT NULL AND applied_at IS NOT NULL)))''',
  'CREATE INDEX IF NOT EXISTS purchases_due ON purchases(business_id,due_at)',
  'CREATE INDEX IF NOT EXISTS suppliers_name ON suppliers(business_id,name)',
  'CREATE INDEX IF NOT EXISTS quotes_customer ON quotes(business_id,customer_id,created_at)',
  'CREATE INDEX IF NOT EXISTS work_delivery ON work_orders(business_id,delivery_at)',
  'CREATE INDEX IF NOT EXISTS advances_work ON work_advances(work_id,applied_at)',
];

extension CapcOperations on CapcRepository {
  Future<List<Supplier>> listSuppliers({String query = ''}) => _run(() async {
    await _require(Permission.managePurchases);
    final search = CapcRepository._search(query);
    final rows = await _db.query(
      'suppliers',
      where:
          'business_id = ?${query.trim().isEmpty ? '' : " AND (name LIKE ? ESCAPE '\\' OR document LIKE ? ESCAPE '\\' OR phone LIKE ? ESCAPE '\\')"}',
      whereArgs: [
        businessId,
        if (query.trim().isNotEmpty) ...[search, search, search],
      ],
      orderBy: 'name COLLATE NOCASE, id',
    );
    return rows.map(_supplierFromRow).toList(growable: false);
  });

  Future<void> saveSupplier(Supplier supplier) => _run(() async {
    final id = supplier.id.trim().isEmpty
        ? CapcRepository._uuid.v4()
        : CapcRepository._id(supplier.id);
    final name = CapcRepository._text(
      supplier.name,
      'El nombre del proveedor',
      160,
    );
    final phone = _opsOptional(supplier.phone, 'El teléfono', 80);
    final document = _opsOptional(supplier.document, 'El documento', 80);
    final address = _opsOptional(supplier.address, 'La dirección', 500);
    await _db.transaction((txn) async {
      await _require(Permission.managePurchases, txn);
      final current = await txn.query(
        'suppliers',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (current.isNotEmpty && current.single['business_id'] != businessId) {
        throw const CapcException('El proveedor no pertenece a este negocio.');
      }
      final now = CapcRepository._now();
      final record = <String, Object?>{
        'id': id,
        'business_id': businessId,
        'name': name,
        'phone': phone,
        'document': document,
        'address': address,
        'updated_at': now,
      };
      if (current.isEmpty) {
        await txn.insert('suppliers', record);
      } else {
        await txn.update('suppliers', record, where: 'id = ?', whereArgs: [id]);
      }
      await _audit(txn, 'supplier.saved', id, record, now);
      await _enqueue(txn, 'supplier.saved', record, now);
    });
  });

  Future<Purchase> createPurchase({
    required String supplierId,
    required String reference,
    required List<PurchaseItemInput> items,
    int paid = 0,
    String paymentMethod = 'Efectivo',
    DateTime? dueAt,
    String? operationId,
  }) => _run(() async {
    final supplier = CapcRepository._id(supplierId);
    final ref = CapcRepository._text(
      reference,
      'La referencia del documento',
      160,
    );
    final method = _opsMethod(paymentMethod);
    CapcRepository._money(paid, 'El pago');
    _opsLineCount(items.length);
    var total = 0;
    for (final item in items) {
      CapcRepository._id(item.productId);
      _opsQuantity(item.quantity);
      CapcRepository._money(item.totalCost, 'El costo del lote');
      total += item.totalCost;
      CapcRepository._money(total, 'El total de la compra');
    }
    if (paid > total) {
      throw const CapcException('El pago supera el total de la compra.');
    }
    if (paid < total && dueAt == null) {
      throw const CapcException(
        'Indica el vencimiento de la compra a crédito.',
      );
    }
    final op = operationId == null
        ? CapcRepository._uuid.v4()
        : CapcRepository._id(operationId);
    final request = jsonEncode({
      'businessId': businessId,
      'supplierId': supplier,
      'reference': ref,
      'items': [
        for (final item in items)
          {
            'productId': item.productId,
            'quantity': item.quantity,
            'totalCost': item.totalCost,
          },
      ],
      'paid': paid,
      'method': method,
      'dueAt': dueAt?.toUtc().toIso8601String(),
    });
    return _db.transaction((txn) async {
      final actor = await _require(Permission.managePurchases, txn);
      final previous = await _operation(txn, op, 'purchase.create', request);
      if (previous != null) return _getPurchase(txn, previous);
      final suppliers = await txn.query(
        'suppliers',
        where: 'id = ? AND business_id = ?',
        whereArgs: [supplier, businessId],
      );
      if (suppliers.isEmpty) {
        throw const CapcException('Selecciona un proveedor existente.');
      }
      final lines = <PurchaseLine>[];
      for (final item in items) {
        final product = await _getProduct(txn, item.productId);
        if (product.isService) {
          throw const CapcException(
            'Las compras de inventario admiten materiales, no servicios.',
          );
        }
        lines.add(
          PurchaseLine(
            productId: product.id,
            code: product.code,
            name: product.name,
            unit: product.unit,
            quantity: item.quantity,
            totalCost: item.totalCost,
          ),
        );
      }
      final id = CapcRepository._uuid.v4();
      final now = CapcRepository._now();
      final number = await _opsNumber(txn, 'purchase', 'C');
      await txn.insert('purchases', {
        'id': id,
        'business_id': businessId,
        'device_id': deviceId,
        'number': number,
        'supplier_id': supplier,
        'supplier_name': suppliers.single['name'],
        'reference': ref,
        'created_at': now,
        'due_at': dueAt?.toUtc().toIso8601String(),
        'total': total,
        'paid': paid,
        'actor_id': actor.id,
        'operator_name': actor.name,
      });
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        await txn.insert('purchase_lines', {
          'id': CapcRepository._uuid.v4(),
          'purchase_id': id,
          'position': index,
          'product_id': line.productId,
          'code': line.code,
          'name': line.name,
          'unit': line.unit,
          'quantity': line.quantity,
          'total_cost': line.totalCost,
        });
      }
      if (paid > 0) {
        await _supplierPaymentInTxn(txn, id, paid, method, actor, now);
      }
      await _recordOperation(txn, op, 'purchase.create', request, id, now);
      await _audit(txn, 'purchase.created', id, {
        'number': number,
        'total': total,
        'paid': paid,
      }, now);
      await _enqueue(
        txn,
        'purchase.created',
        {'purchaseId': id, 'request': jsonDecode(request)},
        now,
        operationId: op,
      );
      return _getPurchase(txn, id);
    });
  });

  Future<List<Purchase>> listPurchases({String query = ''}) => _run(
    () => _db.transaction((txn) async {
      await _require(Permission.managePurchases, txn);
      final search = CapcRepository._search(query);
      final rows = await txn.query(
        'purchases',
        where:
            'business_id = ?${query.trim().isEmpty ? '' : " AND (number LIKE ? ESCAPE '\\' OR supplier_name LIKE ? ESCAPE '\\' OR reference LIKE ? ESCAPE '\\')"}',
        whereArgs: [
          businessId,
          if (query.trim().isNotEmpty) ...[search, search, search],
        ],
        orderBy: 'created_at DESC,number DESC',
      );
      return [for (final row in rows) await _purchaseFromRow(txn, row)];
    }),
  );

  Future<Purchase> receivePurchase(
    String purchaseId, {
    required String operationId,
  }) => _run(() async {
    final id = CapcRepository._id(purchaseId);
    final op = CapcRepository._id(operationId);
    final request = jsonEncode({'businessId': businessId, 'purchaseId': id});
    return _db.transaction((txn) async {
      await _require(Permission.managePurchases, txn);
      final previous = await _operation(txn, op, 'purchase.receive', request);
      if (previous != null) return _getPurchase(txn, previous);
      final purchase = await _getPurchase(txn, id);
      final now = CapcRepository._now();
      // A different retry ID still cannot receive the same document twice.
      if (!purchase.received) {
        for (final line in purchase.lines) {
          final previousProduct = await _getProduct(txn, line.productId);
          await _changeStock(
            txn,
            productId: line.productId,
            delta: line.quantity,
            costMicros: line.totalCost * 1000000,
            reason:
                'Recepción de compra ${purchase.number} · ${purchase.reference}',
            kind: 'purchase',
            referenceId: id,
          );
          // An exact purchase can establish a new weighted-cost basis only
          // when no older units with unknown/declared valuation remain.
          if (previousProduct.stock == 0) {
            await txn.update(
              'products',
              {'cost_known': 1, 'cost_basis': 'weighted'},
              where: 'id = ?',
              whereArgs: [line.productId],
            );
          }
        }
        await txn.update(
          'purchases',
          {'received_at': now},
          where: 'id = ?',
          whereArgs: [id],
        );
        await _audit(txn, 'purchase.received', id, {
          'number': purchase.number,
        }, now);
        await _enqueue(
          txn,
          'purchase.received',
          {'purchaseId': id},
          now,
          operationId: op,
        );
      }
      await _recordOperation(txn, op, 'purchase.receive', request, id, now);
      return _getPurchase(txn, id);
    });
  });

  Future<void> addSupplierPayment(
    String purchaseId,
    int amount,
    String method, {
    required String operationId,
  }) => _run(() async {
    final id = CapcRepository._id(purchaseId);
    final op = CapcRepository._id(operationId);
    final paymentMethod = _opsMethod(method);
    CapcRepository._money(amount, 'El abono', positive: true);
    final request = jsonEncode({
      'businessId': businessId,
      'purchaseId': id,
      'amount': amount,
      'method': paymentMethod,
    });
    await _db.transaction((txn) async {
      final actor = await _require(Permission.managePurchases, txn);
      if (await _operation(txn, op, 'supplier.payment', request) != null) {
        return;
      }
      final purchase = await _getPurchase(txn, id);
      if (amount > purchase.balance) {
        throw const CapcException(
          'El abono supera el saldo pendiente de la compra.',
        );
      }
      final now = CapcRepository._now();
      final payment = await _supplierPaymentInTxn(
        txn,
        id,
        amount,
        paymentMethod,
        actor,
        now,
      );
      await txn.rawUpdate('UPDATE purchases SET paid = paid + ? WHERE id = ?', [
        amount,
        id,
      ]);
      await _recordOperation(
        txn,
        op,
        'supplier.payment',
        request,
        payment,
        now,
      );
      await _audit(txn, 'supplier.payment', id, {
        'paymentId': payment,
        'amount': amount,
        'method': paymentMethod,
      }, now);
      await _enqueue(
        txn,
        'supplier.payment',
        {
          'purchaseId': id,
          'paymentId': payment,
          'amount': amount,
          'method': paymentMethod,
        },
        now,
        operationId: op,
      );
    });
  });

  Future<List<PurchasePayment>> listSupplierPayments({
    String? purchaseId,
  }) => _run(() async {
    await _require(Permission.managePurchases);
    final rows = await _db.query(
      'supplier_payments',
      where:
          'business_id = ?${purchaseId == null ? '' : ' AND purchase_id = ?'}',
      whereArgs: [
        businessId,
        if (purchaseId != null) CapcRepository._id(purchaseId),
      ],
      orderBy: 'created_at DESC,rowid DESC',
    );
    return rows
        .map(
          (row) => PurchasePayment(
            id: row['id'] as String,
            purchaseId: row['purchase_id'] as String,
            amount: row['amount'] as int,
            method: row['method'] as String,
            createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
            operatorName: row['operator_name'] as String,
          ),
        )
        .toList(growable: false);
  });

  Future<String> _supplierPaymentInTxn(
    DatabaseExecutor txn,
    String purchaseId,
    int amount,
    String method,
    LocalUser actor,
    String now,
  ) async {
    final id = CapcRepository._uuid.v4();
    await _recordCash(
      txn,
      -amount,
      method,
      'supplier.payment',
      purchaseId,
      now,
      reason: 'Pago de compra a proveedor',
    );
    await txn.insert('supplier_payments', {
      'id': id,
      'business_id': businessId,
      'device_id': deviceId,
      'purchase_id': purchaseId,
      'amount': amount,
      'method': method,
      'created_at': now,
      'actor_id': actor.id,
      'operator_name': actor.name,
    });
    return id;
  }

  Future<Purchase> _getPurchase(DatabaseExecutor txn, String id) async {
    final rows = await txn.query(
      'purchases',
      where: 'id = ? AND business_id = ?',
      whereArgs: [id, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('La compra seleccionada no existe.');
    }
    return _purchaseFromRow(txn, rows.single);
  }

  Future<Purchase> _purchaseFromRow(
    DatabaseExecutor txn,
    Map<String, Object?> row,
  ) async {
    final lines = await txn.query(
      'purchase_lines',
      where: 'purchase_id = ?',
      whereArgs: [row['id']],
      orderBy: 'position',
    );
    return Purchase(
      id: row['id'] as String,
      number: row['number'] as String,
      supplierId: row['supplier_id'] as String,
      supplierName: row['supplier_name'] as String,
      reference: row['reference'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      dueAt: _opsDate(row['due_at']),
      receivedAt: _opsDate(row['received_at']),
      total: row['total'] as int,
      paid: row['paid'] as int,
      operatorName: row['operator_name'] as String,
      lines: lines
          .map(
            (line) => PurchaseLine(
              productId: line['product_id'] as String,
              code: line['code'] as String,
              name: line['name'] as String,
              unit: line['unit'] as String,
              quantity: line['quantity'] as int,
              totalCost: line['total_cost'] as int,
            ),
          )
          .toList(),
    );
  }

  Future<Quote> createQuote({
    required String customerId,
    required String description,
    required List<QuoteLineInput> items,
    required DateTime validUntil,
    String conditions = '',
    String? operationId,
  }) => _run(() async {
    final customer = CapcRepository._id(customerId);
    final desc = CapcRepository._text(description, 'La descripción', 2000);
    final terms = _opsOptional(conditions, 'Las condiciones', 4000);
    final expiry = validUntil.toUtc().toIso8601String();
    _opsValidateQuoteInput(items);
    final op = operationId == null
        ? CapcRepository._uuid.v4()
        : CapcRepository._id(operationId);
    final request = jsonEncode({
      'businessId': businessId,
      'customerId': customer,
      'description': desc,
      'validUntil': expiry,
      'conditions': terms,
      'items': items.map(_opsQuoteInput).toList(),
    });
    return _db.transaction((txn) async {
      final actor = await _require(Permission.manageQuotes, txn);
      final previous = await _operation(txn, op, 'quote.create', request);
      if (previous != null) return _getQuote(txn, previous);
      if (validUntil.toUtc().isBefore(DateTime.now().toUtc())) {
        throw const CapcException(
          'La vigencia de la cotización debe estar en el futuro.',
        );
      }
      final customerName = await _opsCustomerName(txn, customer);
      final lines = await _opsQuoteLines(txn, items);
      final total = lines.fold<int>(0, (sum, line) => sum + line.total);
      final id = CapcRepository._uuid.v4();
      final now = CapcRepository._now();
      final number = await _opsNumber(txn, 'quote', 'CT');
      await txn.insert('quotes', {
        'id': id,
        'business_id': businessId,
        'device_id': deviceId,
        'number': number,
        'customer_id': customer,
        'customer_name': customerName,
        'description': desc,
        'created_at': now,
        'updated_at': now,
        'valid_until': expiry,
        'conditions': terms,
        'status': QuoteStatus.draft.name,
        'total': total,
        'actor_id': actor.id,
        'operator_name': actor.name,
      });
      await _insertQuoteLines(txn, id, lines);
      await _recordOperation(txn, op, 'quote.create', request, id, now);
      await _audit(txn, 'quote.created', id, {
        'number': number,
        'total': total,
      }, now);
      await _enqueue(
        txn,
        'quote.created',
        {
          'quoteId': id,
          'revision': 1,
          'status': QuoteStatus.draft.name,
          'request': jsonDecode(request),
        },
        now,
        operationId: op,
      );
      return _getQuote(txn, id);
    });
  });

  /// Only drafts may be revised. Accepted terms remain immutable.
  Future<Quote> updateQuote(
    String quoteId, {
    required String description,
    required List<QuoteLineInput> items,
    required DateTime validUntil,
    String conditions = '',
  }) => _run(() async {
    final id = CapcRepository._id(quoteId);
    final desc = CapcRepository._text(description, 'La descripción', 2000);
    final terms = _opsOptional(conditions, 'Las condiciones', 4000);
    _opsValidateQuoteInput(items);
    return _db.transaction((txn) async {
      await _require(Permission.manageQuotes, txn);
      final quote = await _getQuote(txn, id);
      if (quote.status != QuoteStatus.draft) {
        throw const CapcException(
          'Solo se pueden editar cotizaciones en borrador.',
        );
      }
      if (validUntil.toUtc().isBefore(DateTime.now().toUtc())) {
        throw const CapcException('Indica una vigencia futura.');
      }
      final lines = await _opsQuoteLines(txn, items);
      final total = lines.fold<int>(0, (sum, line) => sum + line.total);
      final works = await txn.query(
        'work_orders',
        columns: ['id'],
        where: 'quote_id = ?',
        whereArgs: [id],
      );
      if (works.isNotEmpty) {
        final work = await _getWork(txn, works.single['id'] as String);
        if (work.advancesTotal > total) {
          throw const CapcException(
            'El nuevo total es inferior a los anticipos registrados.',
          );
        }
      }
      final now = CapcRepository._now();
      final revision =
          ((await txn.query(
                'quotes',
                columns: ['revision'],
                where: 'id = ?',
                whereArgs: [id],
              )).single['revision']
              as int) +
          1;
      await txn.update(
        'quotes',
        {
          'description': desc,
          'valid_until': validUntil.toUtc().toIso8601String(),
          'conditions': terms,
          'total': total,
          'updated_at': now,
          'revision': revision,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.delete('quote_lines', where: 'quote_id = ?', whereArgs: [id]);
      await _insertQuoteLines(txn, id, lines);
      await _audit(txn, 'quote.updated', id, {
        'previousTotal': quote.total,
        'total': total,
      }, now);
      await _enqueue(txn, 'quote.updated', {
        'quoteId': id,
        'description': desc,
        'validUntil': validUntil.toUtc().toIso8601String(),
        'conditions': terms,
        'revision': revision,
        'items': items.map(_opsQuoteInput).toList(),
      }, now);
      return _getQuote(txn, id);
    });
  });

  Future<List<Quote>> listQuotes({String query = ''}) => _run(
    () => _db.transaction((txn) async {
      await _require(Permission.manageQuotes, txn);
      final search = CapcRepository._search(query);
      final rows = await txn.query(
        'quotes',
        where:
            'business_id = ?${query.trim().isEmpty ? '' : " AND (number LIKE ? ESCAPE '\\' OR customer_name LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\')"}',
        whereArgs: [
          businessId,
          if (query.trim().isNotEmpty) ...[search, search, search],
        ],
        orderBy: 'created_at DESC,number DESC',
      );
      return [for (final row in rows) await _quoteFromRow(txn, row)];
    }),
  );

  Future<void> updateQuoteStatus(
    String quoteId,
    QuoteStatus status,
  ) => _run(() async {
    final id = CapcRepository._id(quoteId);
    await _db.transaction((txn) async {
      await _require(Permission.manageQuotes, txn);
      final quote = await _getQuote(txn, id);
      if (quote.status == status) return;
      if (status == QuoteStatus.converted || quote.saleId != null) {
        throw const CapcException(
          'El estado Convertida se asigna al crear la venta.',
        );
      }
      final allowed = <QuoteStatus, Set<QuoteStatus>>{
        QuoteStatus.draft: {
          QuoteStatus.sent,
          QuoteStatus.accepted,
          QuoteStatus.rejected,
          QuoteStatus.expired,
        },
        QuoteStatus.sent: {
          QuoteStatus.accepted,
          QuoteStatus.rejected,
          QuoteStatus.expired,
        },
        QuoteStatus.accepted: {QuoteStatus.rejected, QuoteStatus.expired},
        QuoteStatus.rejected: {},
        QuoteStatus.expired: {},
        QuoteStatus.converted: {},
      };
      if (!allowed[quote.status]!.contains(status)) {
        throw const CapcException(
          'Ese cambio de estado de cotización no está permitido.',
        );
      }
      if (status == QuoteStatus.expired && !quote.isExpired) {
        throw const CapcException('La cotización aún está vigente.');
      }
      if ((status == QuoteStatus.sent || status == QuoteStatus.accepted) &&
          quote.isExpired) {
        throw const CapcException(
          'La cotización está vencida. Crea una nueva con las condiciones actualizadas.',
        );
      }
      if (status == QuoteStatus.expired || status == QuoteStatus.rejected) {
        final works = await txn.query(
          'work_orders',
          where: 'quote_id = ?',
          whereArgs: [id],
        );
        if (works.isNotEmpty) {
          final work = await _workFromRow(txn, works.single);
          if (work.unappliedAdvances > 0) {
            throw const CapcException(
              'La cotización tiene anticipos. Conviértela en venta y registra su anulación para reintegrarlos.',
            );
          }
          if (status == QuoteStatus.expired &&
              quote.status == QuoteStatus.accepted &&
              work.status != WorkStatus.delivered) {
            throw const CapcException(
              'La cotización aceptada tiene un trabajo pendiente y conserva sus condiciones.',
            );
          }
        }
      }
      final now = CapcRepository._now();
      final revision =
          ((await txn.query(
                'quotes',
                columns: ['revision'],
                where: 'id = ?',
                whereArgs: [id],
              )).single['revision']
              as int) +
          1;
      await txn.update(
        'quotes',
        {'status': status.name, 'updated_at': now, 'revision': revision},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _audit(txn, 'quote.status', id, {
        'from': quote.status.name,
        'to': status.name,
      }, now);
      await _enqueue(txn, 'quote.status', {
        'quoteId': id,
        'status': status.name,
        'revision': revision,
      }, now);
    });
  });

  Future<Sale> convertQuote(
    String quoteId, {
    required int paid,
    required String paymentMethod,
    int? received,
    DateTime? dueAt,
    required String operationId,
  }) => _run(() async {
    final id = CapcRepository._id(quoteId);
    final op = CapcRepository._id(operationId);
    final method = _opsMethod(paymentMethod);
    CapcRepository._money(paid, 'El pago');
    if (received != null) CapcRepository._money(received, 'El dinero recibido');
    final request = jsonEncode({
      'businessId': businessId,
      'quoteId': id,
      'paid': paid,
      'paymentMethod': method,
      'received': received,
      'dueAt': dueAt?.toUtc().toIso8601String(),
    });
    return _db.transaction((txn) async {
      await _require(Permission.manageQuotes, txn);
      final previous = await _operation(txn, op, 'quote.convert', request);
      if (previous != null) return _getSale(txn, previous);
      final quote = await _getQuote(txn, id);
      // A second click with a fresh ID returns the existing sale, without a new charge.
      if (quote.saleId != null) {
        await _recordOperation(
          txn,
          op,
          'quote.convert',
          request,
          quote.saleId!,
          CapcRepository._now(),
        );
        return _getSale(txn, quote.saleId!);
      }
      if (quote.status != QuoteStatus.accepted) {
        throw const CapcException(
          'Acepta la cotización antes de convertirla en venta.',
        );
      }
      // Validity limits acceptance. An accepted quotation remains a committed
      // price even when its work is completed after the original deadline.
      final works = await txn.query(
        'work_orders',
        where: 'quote_id = ? AND business_id = ?',
        whereArgs: [id, businessId],
      );
      var prepaid = 0;
      WorkOrder? work;
      if (works.isNotEmpty) {
        work = await _workFromRow(txn, works.single);
        if (work.saleId != null) {
          throw const CapcException(
            'El trabajo ya está asociado a otra venta.',
          );
        }
        prepaid = work.unappliedAdvances;
      }
      if (paid + prepaid > quote.total) {
        throw const CapcException(
          'El pago más los anticipos supera el total de la cotización.',
        );
      }
      final sale = await _createSaleInTxn(
        txn,
        items: [
          for (final line in quote.lines)
            if (line.productId != null)
              CartLine(
                productId: line.productId!,
                quantity: line.quantity,
                unitPrice: line.unitPrice,
                name: line.description,
                code: line.code,
                unit: line.unit,
              ),
        ],
        customItems: [
          for (final line in quote.lines)
            if (line.productId == null)
              CustomSaleItem(
                description: line.description,
                quantity: line.quantity,
                unitPrice: line.unitPrice,
                unitCost: line.directCost,
                unit: line.unit,
              ),
        ],
        customerId: quote.customerId,
        paid: paid,
        paymentMethod: method,
        received: received,
        dueAt: dueAt,
        prepaid: prepaid,
        sourceQuoteId: id,
      );
      final now = CapcRepository._now();
      final revision =
          ((await txn.query(
                'quotes',
                columns: ['revision'],
                where: 'id = ?',
                whereArgs: [id],
              )).single['revision']
              as int) +
          1;
      await txn.update(
        'quotes',
        {
          'sale_id': sale.id,
          'status': QuoteStatus.converted.name,
          'updated_at': now,
          'revision': revision,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (work != null) {
        await _markAdvancesApplied(txn, work.id, sale.id, now);
        await txn.update(
          'work_orders',
          {'sale_id': sale.id, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [work.id],
        );
      }
      await _recordOperation(txn, op, 'quote.convert', request, sale.id, now);
      await _audit(txn, 'quote.converted', id, {
        'saleId': sale.id,
        'prepaid': prepaid,
      }, now);
      await _enqueue(
        txn,
        'quote.converted',
        {
          'quoteId': id,
          'saleId': sale.id,
          'prepaid': prepaid,
          'status': QuoteStatus.converted.name,
          'revision': revision,
        },
        now,
        operationId: op,
      );
      return sale;
    });
  });

  Future<Quote> _getQuote(DatabaseExecutor txn, String id) async {
    final rows = await txn.query(
      'quotes',
      where: 'id = ? AND business_id = ?',
      whereArgs: [id, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('La cotización seleccionada no existe.');
    }
    return _quoteFromRow(txn, rows.single);
  }

  Future<Quote> _quoteFromRow(
    DatabaseExecutor txn,
    Map<String, Object?> row,
  ) async {
    final lines = await txn.query(
      'quote_lines',
      where: 'quote_id = ?',
      whereArgs: [row['id']],
      orderBy: 'position',
    );
    return Quote(
      id: row['id'] as String,
      number: row['number'] as String,
      customerId: row['customer_id'] as String,
      customerName: row['customer_name'] as String,
      description: row['description'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      validUntil: DateTime.parse(row['valid_until'] as String).toUtc(),
      conditions: row['conditions'] as String,
      status: QuoteStatus.values.byName(row['status'] as String),
      total: row['total'] as int,
      saleId: row['sale_id'] as String?,
      operatorName: row['operator_name'] as String,
      lines: lines
          .map(
            (line) => QuoteLine(
              productId: line['product_id'] as String?,
              code: line['code'] as String,
              description: line['description'] as String,
              unit: line['unit'] as String,
              quantity: line['quantity'] as int,
              unitPrice: line['unit_price'] as int,
              directCost: line['direct_cost'] as int?,
            ),
          )
          .toList(),
    );
  }

  Future<List<QuoteLine>> _opsQuoteLines(
    DatabaseExecutor txn,
    List<QuoteLineInput> items,
  ) async {
    final result = <QuoteLine>[];
    for (final item in items) {
      final product = item.productId == null
          ? null
          : await _getProduct(txn, CapcRepository._id(item.productId!));
      if (product == null || item.unitPrice != product.salePrice) {
        await _require(Permission.setPrices, txn);
      }
      result.add(
        QuoteLine(
          productId: product?.id,
          code: product?.code ?? 'PERSONALIZADO',
          description: item.description.trim(),
          unit: item.unit.trim(),
          quantity: item.quantity,
          unitPrice: item.unitPrice,
          directCost: product == null ? item.directCost : null,
        ),
      );
    }
    return result;
  }

  Future<void> _insertQuoteLines(
    DatabaseExecutor txn,
    String id,
    List<QuoteLine> lines,
  ) async {
    for (var position = 0; position < lines.length; position++) {
      final line = lines[position];
      await txn.insert('quote_lines', {
        'id': CapcRepository._uuid.v4(),
        'quote_id': id,
        'position': position,
        'product_id': line.productId,
        'code': line.code,
        'description': line.description,
        'unit': line.unit,
        'quantity': line.quantity,
        'unit_price': line.unitPrice,
        'direct_cost': line.directCost,
      });
    }
  }

  Future<WorkOrder> createWorkOrder({
    required String customerId,
    required String description,
    required String responsible,
    required DateTime deliveryAt,
    String? quoteId,
    String? operationId,
  }) => _run(() async {
    final customer = CapcRepository._id(customerId);
    final desc = CapcRepository._text(
      description,
      'La descripción del trabajo',
      2000,
    );
    final person = CapcRepository._text(responsible, 'El responsable', 160);
    final quote = quoteId == null ? null : CapcRepository._id(quoteId);
    final op = operationId == null
        ? CapcRepository._uuid.v4()
        : CapcRepository._id(operationId);
    final request = jsonEncode({
      'businessId': businessId,
      'customerId': customer,
      'description': desc,
      'responsible': person,
      'deliveryAt': deliveryAt.toUtc().toIso8601String(),
      'quoteId': quote,
    });
    return _db.transaction((txn) async {
      final actor = await _require(Permission.manageJobs, txn);
      final previous = await _operation(txn, op, 'work.create', request);
      if (previous != null) return _getWork(txn, previous);
      final customerName = await _opsCustomerName(txn, customer);
      String? saleId;
      if (quote != null) {
        final document = await _getQuote(txn, quote);
        if (document.customerId != customer) {
          throw const CapcException(
            'La cotización corresponde a otro cliente.',
          );
        }
        if (document.status == QuoteStatus.rejected ||
            document.status == QuoteStatus.expired) {
          throw const CapcException(
            'La cotización no está disponible para un trabajo.',
          );
        }
        saleId = document.saleId;
        final existing = await txn.query(
          'work_orders',
          columns: ['id'],
          where: 'quote_id = ?',
          whereArgs: [quote],
        );
        if (existing.isNotEmpty) {
          throw const CapcException(
            'La cotización ya tiene un trabajo asociado.',
          );
        }
      }
      final id = CapcRepository._uuid.v4();
      final now = CapcRepository._now();
      final number = await _opsNumber(txn, 'work', 'T');
      await txn.insert('work_orders', {
        'id': id,
        'business_id': businessId,
        'device_id': deviceId,
        'number': number,
        'customer_id': customer,
        'customer_name': customerName,
        'description': desc,
        'created_at': now,
        'updated_at': now,
        'status': WorkStatus.received.name,
        'responsible': person,
        'delivery_at': deliveryAt.toUtc().toIso8601String(),
        'quote_id': quote,
        'sale_id': saleId,
        'actor_id': actor.id,
      });
      await _recordOperation(txn, op, 'work.create', request, id, now);
      await _audit(txn, 'work.created', id, {
        'number': number,
        'request': jsonDecode(request),
      }, now);
      await _enqueue(
        txn,
        'work.created',
        {'workId': id, 'request': jsonDecode(request)},
        now,
        operationId: op,
      );
      return _getWork(txn, id);
    });
  });

  Future<List<WorkOrder>> listWorkOrders({String query = ''}) => _run(
    () => _db.transaction((txn) async {
      await _require(Permission.manageJobs, txn);
      final search = CapcRepository._search(query);
      final rows = await txn.query(
        'work_orders',
        where:
            'business_id = ?${query.trim().isEmpty ? '' : " AND (number LIKE ? ESCAPE '\\' OR customer_name LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\' OR responsible LIKE ? ESCAPE '\\')"}',
        whereArgs: [
          businessId,
          if (query.trim().isNotEmpty) ...[search, search, search, search],
        ],
        orderBy: 'created_at DESC,number DESC',
      );
      return [for (final row in rows) await _workFromRow(txn, row)];
    }),
  );

  Future<void> updateWorkOrder(
    String workId, {
    required WorkStatus status,
    required String responsible,
    required DateTime deliveryAt,
  }) => _run(() async {
    final id = CapcRepository._id(workId);
    final person = CapcRepository._text(responsible, 'El responsable', 160);
    await _db.transaction((txn) async {
      await _require(Permission.manageJobs, txn);
      final work = await _getWork(txn, id);
      if (status.index < work.status.index ||
          status.index > work.status.index + 1) {
        throw const CapcException(
          'Avanza el trabajo en orden: recibido, en proceso, listo y entregado.',
        );
      }
      if (status == WorkStatus.delivered && work.unappliedAdvances > 0) {
        throw const CapcException(
          'Aplica los anticipos a una venta antes de entregar el trabajo.',
        );
      }
      final now = CapcRepository._now();
      final changes = <String, Object?>{
        'status': status.name,
        'responsible': person,
        'delivery_at': deliveryAt.toUtc().toIso8601String(),
        'updated_at': now,
      };
      await txn.update(
        'work_orders',
        changes,
        where: 'id = ?',
        whereArgs: [id],
      );
      await _audit(txn, 'work.updated', id, {
        'previousStatus': work.status.name,
        ...changes,
      }, now);
      await _enqueue(txn, 'work.updated', {'workId': id, ...changes}, now);
    });
  });

  Future<WorkAdvance> addWorkAdvance(
    String workId,
    int amount,
    String method, {
    required String operationId,
    int? received,
  }) => _run(() async {
    final id = CapcRepository._id(workId);
    final op = CapcRepository._id(operationId);
    final paymentMethod = _opsMethod(method);
    CapcRepository._money(amount, 'El anticipo', positive: true);
    final moneyReceived = received ?? amount;
    CapcRepository._money(moneyReceived, 'El dinero recibido');
    if (moneyReceived < amount ||
        (paymentMethod != 'Efectivo' && moneyReceived != amount)) {
      throw const CapcException(
        'El importe recibido es insuficiente o el cambio no corresponde a efectivo.',
      );
    }
    final request = jsonEncode({
      'businessId': businessId,
      'workId': id,
      'amount': amount,
      'method': paymentMethod,
      'received': moneyReceived,
    });
    return _db.transaction((txn) async {
      await _require(Permission.manageJobs, txn);
      final actor = await _require(Permission.collect, txn);
      final previous = await _operation(txn, op, 'work.advance', request);
      if (previous != null) {
        final rows = await txn.query(
          'work_advances',
          where: 'id = ? AND business_id = ?',
          whereArgs: [previous, businessId],
        );
        return _advanceFromRow(rows.single);
      }
      final work = await _getWork(txn, id);
      if (work.saleId != null) {
        throw const CapcException(
          'El trabajo ya tiene venta. Registra el abono directamente en esa venta.',
        );
      }
      if (work.status == WorkStatus.delivered) {
        throw const CapcException('El trabajo ya fue entregado.');
      }
      if (work.quoteId != null) {
        final quote = await _getQuote(txn, work.quoteId!);
        if (quote.status != QuoteStatus.accepted) {
          throw const CapcException(
            'Acepta la cotización del trabajo antes de registrar anticipos.',
          );
        }
        if (work.advancesTotal + amount > quote.total) {
          throw const CapcException(
            'Los anticipos superan el total de la cotización.',
          );
        }
      }
      CapcRepository._money(
        work.advancesTotal + amount,
        'Los anticipos acumulados',
      );
      final advance = CapcRepository._uuid.v4();
      final now = CapcRepository._now();
      await _recordCash(
        txn,
        amount,
        paymentMethod,
        'work.advance',
        advance,
        now,
        reason: 'Anticipo de trabajo ${work.number}',
      );
      final record = <String, Object?>{
        'id': advance,
        'business_id': businessId,
        'device_id': deviceId,
        'work_id': id,
        'amount': amount,
        'received': moneyReceived,
        'method': paymentMethod,
        'created_at': now,
        'actor_id': actor.id,
        'operator_name': actor.name,
      };
      await txn.insert('work_advances', record);
      await _recordOperation(txn, op, 'work.advance', request, advance, now);
      await _audit(txn, 'work.advance', id, {
        'advanceId': advance,
        'amount': amount,
        'method': paymentMethod,
        'received': moneyReceived,
      }, now);
      await _enqueue(txn, 'work.advance', record, now, operationId: op);
      return _advanceFromRow(record);
    });
  });

  Future<List<WorkAdvance>> listWorkAdvances({String? workId}) => _run(
    () async {
      await _require(Permission.manageJobs);
      final rows = await _db.query(
        'work_advances',
        where: 'business_id = ?${workId == null ? '' : ' AND work_id = ?'}',
        whereArgs: [businessId, if (workId != null) CapcRepository._id(workId)],
        orderBy: 'created_at DESC,rowid DESC',
      );
      return rows.map(_advanceFromRow).toList(growable: false);
    },
  );

  Future<Sale> applyWorkAdvances(
    String workId,
    String saleId, {
    required String operationId,
  }) => _run(() async {
    final id = CapcRepository._id(workId);
    final sale = CapcRepository._id(saleId);
    final op = CapcRepository._id(operationId);
    final request = jsonEncode({
      'businessId': businessId,
      'workId': id,
      'saleId': sale,
    });
    return _db.transaction((txn) async {
      await _require(Permission.manageJobs, txn);
      await _require(Permission.collect, txn);
      final previous = await _operation(txn, op, 'work.apply', request);
      if (previous != null) return _getSale(txn, previous);
      final work = await _getWork(txn, id);
      final document = await _getSale(txn, sale);
      if (document.customerId != work.customerId) {
        throw const CapcException('La venta corresponde a otro cliente.');
      }
      if (work.saleId != null && work.saleId != sale) {
        throw const CapcException(
          'Los anticipos del trabajo ya se aplicaron a otra venta.',
        );
      }
      if (work.quoteId != null) {
        final quote = await _getQuote(txn, work.quoteId!);
        if (quote.saleId != sale) {
          throw const CapcException(
            'Convierte la cotización del trabajo para aplicar sus anticipos a la venta correspondiente.',
          );
        }
      }
      final now = CapcRepository._now();
      if (work.unappliedAdvances > 0) {
        await _applyPrepaidInTxn(txn, sale, work.unappliedAdvances);
        await _markAdvancesApplied(txn, id, sale, now);
        await _audit(txn, 'work.advanceApplied', id, {
          'saleId': sale,
          'amount': work.unappliedAdvances,
        }, now);
        await _enqueue(
          txn,
          'work.advanceApplied',
          {'workId': id, 'saleId': sale, 'amount': work.unappliedAdvances},
          now,
          operationId: op,
        );
      }
      await txn.update(
        'work_orders',
        {'sale_id': sale, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _recordOperation(txn, op, 'work.apply', request, sale, now);
      return _getSale(txn, sale);
    });
  });

  Future<void> _markAdvancesApplied(
    DatabaseExecutor txn,
    String work,
    String sale,
    String now,
  ) => txn
      .update(
        'work_advances',
        {'sale_id': sale, 'applied_at': now},
        where: 'work_id = ? AND sale_id IS NULL',
        whereArgs: [work],
      )
      .then((_) {});

  Future<WorkOrder> _getWork(DatabaseExecutor txn, String id) async {
    final rows = await txn.query(
      'work_orders',
      where: 'id = ? AND business_id = ?',
      whereArgs: [id, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('El trabajo seleccionado no existe.');
    }
    return _workFromRow(txn, rows.single);
  }

  Future<WorkOrder> _workFromRow(
    DatabaseExecutor txn,
    Map<String, Object?> row,
  ) async {
    final advances = await txn.rawQuery(
      'SELECT COALESCE(SUM(amount),0) AS total, COALESCE(SUM(CASE WHEN sale_id IS NULL THEN amount ELSE 0 END),0) AS unapplied FROM work_advances WHERE work_id = ?',
      [row['id']],
    );
    return WorkOrder(
      id: row['id'] as String,
      number: row['number'] as String,
      customerId: row['customer_id'] as String,
      customerName: row['customer_name'] as String,
      description: row['description'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      status: WorkStatus.values.byName(row['status'] as String),
      responsible: row['responsible'] as String,
      deliveryAt: DateTime.parse(row['delivery_at'] as String).toUtc(),
      quoteId: row['quote_id'] as String?,
      saleId: row['sale_id'] as String?,
      advancesTotal: advances.single['total'] as int,
      unappliedAdvances: advances.single['unapplied'] as int,
    );
  }

  Future<String> _opsCustomerName(DatabaseExecutor txn, String customer) async {
    final rows = await txn.query(
      'customers',
      where: 'id = ? AND business_id = ?',
      whereArgs: [customer, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('Selecciona un cliente existente.');
    }
    return rows.single['name'] as String;
  }
}

Supplier _supplierFromRow(Map<String, Object?> row) => Supplier(
  id: row['id'] as String,
  name: row['name'] as String,
  phone: row['phone'] as String,
  document: row['document'] as String,
  address: row['address'] as String,
);

WorkAdvance _advanceFromRow(Map<String, Object?> row) => WorkAdvance(
  id: row['id'] as String,
  workId: row['work_id'] as String,
  amount: row['amount'] as int,
  received: row['received'] as int,
  method: row['method'] as String,
  createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
  operatorName: row['operator_name'] as String,
  saleId: row['sale_id'] as String?,
  appliedAt: _opsDate(row['applied_at']),
);

DateTime? _opsDate(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

String _opsOptional(String value, String label, int maximum) {
  final clean = value.trim();
  if (clean.length > maximum || clean.contains('\u0000')) {
    throw CapcException('$label admite hasta $maximum caracteres.');
  }
  return clean;
}

String _opsMethod(String method) {
  if (!const ['Efectivo', 'Transferencia', 'Tarjeta'].contains(method)) {
    throw const CapcException('Selecciona Efectivo, Transferencia o Tarjeta.');
  }
  return method;
}

void _opsQuantity(int quantity) {
  if (quantity <= 0 || quantity > CapcRepository._maxQuantity) {
    throw const CapcException(
      'La cantidad debe ser un entero mayor que cero y hasta 1000000000.',
    );
  }
}

void _opsLineCount(int length) {
  if (length < 1 || length > 1000) {
    throw const CapcException(
      'El documento requiere entre 1 y 1000 conceptos.',
    );
  }
}

void _opsValidateQuoteInput(List<QuoteLineInput> items) {
  _opsLineCount(items.length);
  var total = 0;
  for (final item in items) {
    if (item.productId != null) CapcRepository._id(item.productId!);
    CapcRepository._text(item.description, 'La descripción del concepto', 500);
    CapcRepository._text(item.unit, 'La unidad', 40);
    _opsQuantity(item.quantity);
    CapcRepository._money(item.unitPrice, 'El precio unitario');
    if (item.directCost != null) {
      CapcRepository._money(item.directCost!, 'El costo directo unitario');
      CapcRepository._multiply(item.quantity, item.directCost!, scale: 1000000);
    }
    if (item.unitPrice > 0 &&
        item.quantity > CapcRepository._maxMoney ~/ item.unitPrice) {
      throw const CapcException(
        'El total del concepto supera el límite permitido.',
      );
    }
    total += item.unitPrice * item.quantity;
    CapcRepository._money(total, 'El total de la cotización');
  }
}

Map<String, Object?> _opsQuoteInput(QuoteLineInput item) => {
  'productId': item.productId,
  'description': item.description.trim(),
  'unit': item.unit.trim(),
  'quantity': item.quantity,
  'unitPrice': item.unitPrice,
  'directCost': item.directCost,
};

Future<String> _opsNumber(
  DatabaseExecutor txn,
  String counter,
  String prefix,
) async {
  await txn.rawUpdate('UPDATE counters SET value = value + 1 WHERE name = ?', [
    counter,
  ]);
  final values = await txn.query(
    'counters',
    where: 'name = ?',
    whereArgs: [counter],
  );
  return '$prefix-${(values.single['value'] as int).toString().padLeft(6, '0')}';
}
