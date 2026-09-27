import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqlite3/sqlite3.dart' as native;
import 'package:uuid/uuid.dart';

import '../platform/platform_services.dart';
import '../sync/sync_models.dart';
import 'models.dart';
export 'models.dart';
part 'operations.dart';
part 'recovery.dart';
part '../sync/local_sync_store.dart';

enum RemoteLinkState { newInstallation, noMovements, hasBusinessMovements }

/// All interactive writes stay transactional and local. Remote exchange is
/// delegated to the optional sync engine and never blocks offline operation.
class CapcRepository {
  CapcRepository._(
    this._db,
    this.databasePath,
    this._businessId,
    this._deviceId,
  );
  static const _uuid = Uuid();
  static const _maxMoney = 999999999999;
  static const _maxQuantity = 1000000000;
  static const _maxMicros = 9000000000000000000;
  static const _schemaVersion = 4;
  static const _applicationId = 1128353859;
  static final _passwordAlgorithm = Argon2id(
    memory: 19456,
    parallelism: 1,
    iterations: 2,
    hashLength: 32,
  );
  Database _db;
  final String databasePath;
  String _businessId, _deviceId;
  LocalUser? _session;
  int _sessionVersion = 0;
  int _sessionEpoch = 0;
  static final Object _epochKey = Object();
  bool _closed = false, _maintenance = false;
  int _activeOperations = 0;
  Completer<void>? _drained;
  LocalUser? get currentUser => _session;
  bool get isAuthenticated => _session != null;
  String get businessId => _businessId;
  String get deviceId => _deviceId;
  LocalUser get _actor {
    final epoch = Zone.current[_epochKey] as int?;
    if (_session == null || (epoch != null && epoch != _sessionEpoch)) {
      throw const CapcException(
        'La sesión cambió durante la operación. Vuelve a intentarlo.',
      );
    }
    return _session!;
  }

  static Future<CapcRepository> open(String path) async {
    if (path.trim().isEmpty) {
      throw const CapcException('Selecciona una ubicación para los datos.');
    }
    final resolved = path == inMemoryDatabasePath
        ? path
        : p.normalize(p.absolute(path));
    if (resolved != inMemoryDatabasePath) {
      await Directory(p.dirname(resolved)).create(recursive: true);
    }
    final recovery = resolved == inMemoryDatabasePath
        ? null
        : await _recoverInterruptedRestore(resolved);
    final db = await _openDatabase(resolved);
    try {
      final settings = await db.query('settings');
      String value(String key) =>
          settings.singleWhere((r) => r['key'] == key)['value'] as String;
      final repository = CapcRepository._(
        db,
        resolved,
        value('business_id'),
        value('device_id'),
      );
      if (recovery != null) {
        await db.insert('audit', {
          'id': _uuid.v4(),
          'action': 'backup.interruption_recovered',
          'entity_id': repository.businessId,
          'actor_id': 'system-recovery',
          'actor_name': 'Recuperación automática',
          'created_at': _now(),
          'details': jsonEncode(recovery),
          'business_id': repository.businessId,
          'device_id': repository.deviceId,
        });
      }
      return repository;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  static Future<Database> _openDatabase(String path) async {
    return appPlatform.database.open(
      path,
      OpenDatabaseOptions(
        version: _schemaVersion,
        singleInstance: false,
        onConfigure: (db) async {
          // Migrations rebuild FK parents atomically; enforcement resumes before use.
          await db.execute('PRAGMA foreign_keys = OFF');
          await db.execute('PRAGMA busy_timeout = 5000');
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = FULL');
        },
        onCreate: (db, _) async => _createSchema(db),
        onUpgrade: (db, oldVersion, newVersion) async {
          var current = oldVersion;
          if (current == 1) {
            await _migrateV1(db);
            current = 2;
          }
          if (current == 2) {
            await _migrateV2ToV3(db);
            current = 3;
          }
          if (current == 3) {
            await _migrateV3ToV4(db);
            current = 4;
          }
          if (current != newVersion) {
            throw const CapcException('Versión de datos no compatible.');
          }
        },
        onDowngrade: (db, oldVersion, newVersion) async {
          throw const CapcException(
            'Estos datos requieren una versión más reciente de CAPC.',
          );
        },
        onOpen: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          final violations = await db.rawQuery('PRAGMA foreign_key_check');
          if (violations.isNotEmpty) {
            throw const CapcException(
              'Los datos tienen referencias dañadas. Restaura un respaldo válido.',
            );
          }
        },
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _maintenance = true;
    await _waitForOperations();
    await _db.close();
    _closed = true;
    logout();
  }

  Future<void> _waitForOperations() async {
    if (_activeOperations > 0) {
      _drained ??= Completer<void>();
      await _drained!.future;
    }
  }

  Future<T> _run<T>(Future<T> Function() work) async {
    if (_closed) throw const CapcException('La base de datos está cerrada.');
    if (_maintenance) {
      throw const CapcException(
        'Espera a que termine el mantenimiento de los datos.',
      );
    }
    _activeOperations++;
    try {
      return await runZoned(work, zoneValues: {_epochKey: _sessionEpoch});
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw const CapcException(
          'Ya existe un registro con ese código o identificador.',
        );
      }
      throw const CapcException(
        'No se pudo guardar o consultar la operación. Revisa el espacio disponible y vuelve a intentarlo.',
      );
    } on FileSystemException {
      throw const CapcException(
        'No se pudo acceder al archivo. Revisa la ubicación, permisos y espacio disponible.',
      );
    } finally {
      _activeOperations--;
      if (_activeOperations == 0 && _drained != null) {
        _drained!.complete();
        _drained = null;
      }
    }
  }

  Future<bool> needsSetup() => _run(
    () async => (await _db.query('users', columns: ['id'], limit: 1)).isEmpty,
  );

  static void _validatePassword(String value) {
    if (value.length < 10 || value.length > 256 || value.trim() != value) {
      throw const CapcException(
        'La contraseña debe tener entre 10 y 256 caracteres, sin espacios al inicio o al final.',
      );
    }
  }

  static Future<Map<String, String>> _hashPassword(String value) async {
    _validatePassword(value);
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final key = await _passwordAlgorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(value)),
      nonce: salt,
    );
    return {
      'password_salt': base64Encode(salt),
      'password_hash': base64Encode(await key.extractBytes()),
    };
  }

  static Future<bool> _verifyPassword(
    String value,
    Map<String, Object?> row,
  ) async {
    if (value.length > 256) return false;
    final key = await _passwordAlgorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(value)),
      nonce: base64Decode(row['password_salt'] as String),
    );
    final actual = await key.extractBytes();
    final expected = base64Decode(row['password_hash'] as String);
    var difference = expected.length ^ actual.length;
    for (var i = 0; i < actual.length; i++) {
      difference |= actual[i] ^ (i < expected.length ? expected[i] : 0);
    }
    return difference == 0;
  }

  Future<LocalUser> setupOwner({
    required String name,
    required String username,
    required String password,
  }) => _run(() async {
    final displayName = _text(name, 'El nombre', 160);
    final loginName = _text(username, 'El usuario', 80).toLowerCase();
    final credentials = await _hashPassword(password);
    final id = _uuid.v4();
    final user = LocalUser(
      id: id,
      name: displayName,
      username: loginName,
      role: UserRole.owner,
    );
    await _db.transaction((txn) async {
      if ((await txn.query('users', columns: ['id'], limit: 1)).isNotEmpty) {
        throw const CapcException(
          'Ya se configuró el primer propietario. Inicia sesión.',
        );
      }
      final now = _now();
      await txn.insert('users', {
        'id': id,
        'name': displayName,
        'username': loginName,
        'role': 'owner',
        'active': 1,
        ...credentials,
        'created_at': now,
        'business_id': businessId,
        'device_id': deviceId,
      });
      await txn.insert('audit', {
        'id': _uuid.v4(),
        'action': 'user.owner_created',
        'entity_id': id,
        'actor_id': id,
        'actor_name': displayName,
        'created_at': now,
        'details': '{}',
        'business_id': businessId,
        'device_id': deviceId,
      });
    });
    _session = user;
    _sessionEpoch++;
    _sessionVersion = 0;
    return user;
  });

  Future<LocalUser> login(String username, String password) => _run(() async {
    final epoch = _sessionEpoch;
    await _requireOwnerConfigurationComplete(_db);
    final name = _text(username, 'El usuario', 80).toLowerCase();
    final rows = await _db.query(
      'users',
      where: 'username = ? COLLATE NOCASE AND business_id = ?',
      whereArgs: [name, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('Usuario o contraseña incorrectos.');
    }
    final row = rows.single;
    final locked = row['locked_until'] as String?;
    if (locked != null &&
        DateTime.parse(locked).isAfter(DateTime.now().toUtc())) {
      throw const CapcException(
        'Demasiados intentos. Espera cinco minutos e inténtalo otra vez.',
      );
    }
    final valid = row['active'] == 1 && await _verifyPassword(password, row);
    final result = await _db.transaction((txn) async {
      if (epoch != _sessionEpoch) {
        throw const CapcException('La sesión cambió. Vuelve a iniciar sesión.');
      }
      await _requireOwnerConfigurationComplete(txn);
      final fresh = (await txn.query(
        'users',
        where: 'id = ?',
        whereArgs: [row['id']],
      )).single;
      if (!valid ||
          fresh['password_hash'] != row['password_hash'] ||
          fresh['active'] != 1) {
        final attempts = (fresh['failed_login'] as int) + 1;
        await txn.update(
          'users',
          {
            'failed_login': attempts,
            'locked_until': attempts >= 5
                ? DateTime.now()
                      .toUtc()
                      .add(const Duration(minutes: 5))
                      .toIso8601String()
                : null,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        return null;
      }
      await txn.update(
        'users',
        {'failed_login': 0, 'locked_until': null},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      return fresh;
    });
    if (result == null) {
      throw const CapcException('Usuario o contraseña incorrectos.');
    }
    if (epoch != _sessionEpoch) {
      throw const CapcException('La sesión cambió. Vuelve a iniciar sesión.');
    }
    _session = _user(result);
    _sessionEpoch++;
    _sessionVersion = result['session_version'] as int;
    return _session!;
  });

  void logout() {
    _session = null;
    _sessionVersion = 0;
    _sessionEpoch++;
  }

  Future<LocalUser> _require(
    Permission permission, [
    DatabaseExecutor? executor,
  ]) async {
    await _requireOwnerConfigurationComplete(executor ?? _db);
    if (_session == null) {
      throw const CapcException('Inicia sesión para continuar.');
    }
    final session = _actor;
    final epoch = _sessionEpoch;
    final rows = await (executor ?? _db).query(
      'users',
      where: 'id = ? AND business_id = ?',
      whereArgs: [session.id, businessId],
    );
    if (epoch != _sessionEpoch) {
      throw const CapcException('La sesión cambió durante la operación.');
    }
    if (rows.isEmpty ||
        rows.single['active'] != 1 ||
        rows.single['session_version'] != _sessionVersion) {
      logout();
      throw const CapcException(
        'La sesión ya no es válida. Inicia sesión otra vez.',
      );
    }
    final actor = _user(rows.single);
    _session = actor;
    if (!actor.can(permission)) {
      throw const CapcException(
        'Tu usuario no tiene permiso para realizar esta operación.',
      );
    }
    return actor;
  }

  Future<List<LocalUser>> listUsers() => _run(() async {
    await _require(Permission.manageUsers);
    return (await _db.query(
      'users',
      where: 'business_id = ?',
      whereArgs: [businessId],
      orderBy: 'name',
    )).map(_user).toList();
  });

  Future<void> saveUser({
    String? id,
    required String name,
    required String username,
    required UserRole role,
    String? password,
    bool active = true,
  }) => _run(() async {
    await _require(Permission.manageUsers);
    final userId = id == null || id.isEmpty ? _uuid.v4() : _id(id);
    final displayName = _text(name, 'El nombre', 160);
    final loginName = _text(username, 'El usuario', 80).toLowerCase();
    final credentials = password == null || password.isEmpty
        ? null
        : await _hashPassword(password);
    await _db.transaction((txn) async {
      final actor = await _require(Permission.manageUsers, txn);
      final rows = await txn.query(
        'users',
        where: 'id = ? AND business_id = ?',
        whereArgs: [userId, businessId],
      );
      if (rows.isEmpty && credentials == null) {
        throw const CapcException(
          'Escribe una contraseña para el nuevo usuario.',
        );
      }
      if (actor.id == userId && (!active || role != UserRole.owner)) {
        throw const CapcException(
          'No puedes desactivar ni quitar el rol a tu propia cuenta propietaria.',
        );
      }
      final record = <String, Object?>{
        'name': displayName,
        'username': loginName,
        'role': role.name,
        'active': active ? 1 : 0,
        ...?credentials,
      };
      if (rows.isEmpty) {
        await txn.insert('users', {
          'id': userId,
          ...record,
          'created_at': _now(),
          'business_id': businessId,
          'device_id': deviceId,
        });
      } else {
        if (rows.single['role'] == 'owner' &&
            (!active || role != UserRole.owner)) {
          final owners = await txn.query(
            'users',
            columns: ['id'],
            where: "role = 'owner' AND active = 1 AND business_id = ?",
            whereArgs: [businessId],
          );
          if (owners.length <= 1) {
            throw const CapcException(
              'Debe existir al menos un propietario activo.',
            );
          }
        }
        if (credentials != null ||
            !active ||
            rows.single['role'] != role.name) {
          record['session_version'] =
              (rows.single['session_version'] as int) + 1;
        }
        await txn.update('users', record, where: 'id = ?', whereArgs: [userId]);
        if (credentials != null ||
            !active ||
            rows.single['role'] != role.name) {
          await _clearRecovery(txn, userId);
        }
      }
      await _audit(txn, 'user.saved', userId, {
        'name': displayName,
        'role': role.name,
        'active': active,
      }, _now());
    });
  });

  static LocalUser _user(Map<String, Object?> row) => LocalUser(
    id: row['id'] as String,
    name: row['name'] as String,
    username: row['username'] as String,
    role: UserRole.values.byName(row['role'] as String),
    active: row['active'] == 1,
  );

  Future<List<Product>> listProducts({String query = ''}) => _run(() async {
    await _require(Permission.read);
    final rows = await _db.query(
      'products',
      where:
          "business_id = ? AND (code LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\')",
      whereArgs: [businessId, _search(query), _search(query)],
      orderBy: 'name COLLATE NOCASE, code',
    );
    return rows.map(_product).toList();
  });

  Future<void> saveProduct(Product product) => _run(() async {
    await _db.transaction((txn) async {
      await _require(Permission.manageCatalog, txn);
      await _saveProductTxn(txn, product);
    });
  });

  /// Imports new catalog entries atomically. [sourceRows] preserves row numbers
  /// when the spreadsheet contains blank rows; otherwise row 1 is the header.
  Future<int> importProducts(
    List<Product> products, {
    List<int>? sourceRows,
  }) => _run(() async {
    if (products.isEmpty || products.length > 5000) {
      throw const CapcException(
        'El archivo debe contener entre 1 y 5000 productos o servicios.',
      );
    }
    final entries = List<Product>.of(products, growable: false);
    final rows = sourceRows == null
        ? List<int>.generate(entries.length, (index) => index + 2)
        : List<int>.of(sourceRows, growable: false);
    if (rows.length != entries.length || rows.any((row) => row < 2)) {
      throw const CapcException(
        'Las filas de origen del archivo no coinciden con los registros.',
      );
    }
    return _db.transaction((txn) async {
      await _require(Permission.manageCatalog, txn);
      for (var index = 0; index < entries.length; index++) {
        try {
          await _saveProductTxn(txn, entries[index], insertOnly: true);
        } on CapcException catch (error) {
          throw CapcException('Fila ${rows[index]}: ${error.message}');
        } on DatabaseException catch (error) {
          if (error.isUniqueConstraintError()) {
            throw CapcException(
              'Fila ${rows[index]}: el código "${entries[index].code.trim()}" '
              'ya existe o está repetido en el archivo.',
            );
          }
          rethrow;
        }
      }
      await _require(Permission.manageCatalog, txn);
      await _audit(txn, 'catalog.imported', businessId, {
        'count': entries.length,
      }, _now());
      return entries.length;
    });
  });

  Future<void> _saveProductTxn(
    DatabaseExecutor txn,
    Product product, {
    bool insertOnly = false,
  }) async {
    if (insertOnly && product.id.trim().isNotEmpty) {
      throw const CapcException(
        'La importación solo permite registros nuevos, sin identificador.',
      );
    }
    final id = product.id.trim().isEmpty ? _uuid.v4() : _id(product.id);
    final code = _text(product.code, 'El código', 80).toUpperCase();
    final name = _text(product.name, 'El nombre', 160);
    final unit = _text(product.unit, 'La unidad', 40);
    final category = _optionalText(product.category, 'La categoría', 80);
    _money(product.purchasePrice, 'El costo de compra');
    _money(product.salePrice, 'El precio de venta');
    _stock(product.stock);
    _stock(product.minimumStock);
    if (product.isService &&
        (product.stock != 0 || product.minimumStock != 0)) {
      throw const CapcException(
        'Los servicios no manejan stock ni mínimo propios.',
      );
    }
    final current = insertOnly
        ? const <Map<String, Object?>>[]
        : await txn.query(
            'products',
            where: 'id = ? AND business_id = ?',
            whereArgs: [id, businessId],
          );
    if (current.isNotEmpty && current.first['stock'] != product.stock) {
      throw const CapcException(
        'Las existencias cambiaron. Actualiza el catálogo y usa Ajustar stock con un motivo.',
      );
    }
    if (current.isNotEmpty &&
        current.first['is_service'] != (product.isService ? 1 : 0)) {
      throw const CapcException(
        'El tipo de un registro existente no se puede cambiar. Crea un código nuevo.',
      );
    }
    final now = _now();
    final revision = current.isEmpty
        ? 1
        : (current.single['revision'] as int) + 1;
    final record = <String, Object?>{
      'code': code,
      'name': name,
      'unit': unit,
      'category': category,
      'is_service': product.isService ? 1 : 0,
      'purchase_price': product.purchasePrice,
      'sale_price': product.salePrice,
      'minimum_stock': product.minimumStock,
      'updated_at': now,
      'revision': revision,
    };
    if (current.isEmpty) {
      await txn.insert('products', {
        'id': id,
        ...record,
        'stock': 0,
        'inventory_value_micros': 0,
        'cost_known': product.costKnown ? 1 : 0,
        'cost_basis': 'weighted',
        'business_id': businessId,
        'device_id': deviceId,
      });
      if (!product.isService && product.stock > 0) {
        await _changeStock(
          txn,
          productId: id,
          delta: product.stock,
          costMicros: _multiply(
            product.stock,
            product.purchasePrice,
            scale: 1000000,
          ),
          reason: 'Stock inicial',
          kind: 'Inicial',
        );
      }
    } else {
      // Catalog cost edits are a reference for future receipts, never a revaluation.
      if (product.isService) record['cost_known'] = product.costKnown ? 1 : 0;
      await txn.update('products', record, where: 'id = ?', whereArgs: [id]);
    }
    await _audit(txn, 'product.saved', id, record, now);
    await _enqueue(txn, 'product.saved', {'id': id, ...record}, now);
  }

  Future<void> setServiceRecipe(
    String serviceId,
    List<ServiceMaterial> items,
  ) => _run(() async {
    final id = _id(serviceId);
    final grouped = <String, int>{};
    for (final item in items) {
      _quantity(item.quantity);
      grouped[_id(item.productId)] =
          (grouped[item.productId] ?? 0) + item.quantity;
      _quantity(grouped[item.productId]!);
    }
    await _db.transaction((txn) async {
      await _require(Permission.manageCatalog, txn);
      if (!(await _getProduct(txn, id)).isService) {
        throw const CapcException('La receta corresponde a un servicio.');
      }
      for (final materialId in grouped.keys) {
        if ((await _getProduct(txn, materialId)).isService) {
          throw const CapcException(
            'Una receta solo puede consumir materiales, no otros servicios.',
          );
        }
      }
      await txn.delete(
        'service_materials',
        where: 'service_id = ?',
        whereArgs: [id],
      );
      for (final entry in grouped.entries) {
        await txn.insert('service_materials', {
          'service_id': id,
          'product_id': entry.key,
          'quantity': entry.value,
          'business_id': businessId,
        });
      }
      await _audit(txn, 'service.recipe_saved', id, {
        'materials': grouped,
      }, _now());
    });
  });

  Future<List<ServiceMaterial>> listServiceRecipe(String serviceId) =>
      _run(() async {
        await _require(Permission.read);
        return (await _db.query(
              'service_materials',
              where: 'service_id = ? AND business_id = ?',
              whereArgs: [_id(serviceId), businessId],
              orderBy: 'product_id',
            ))
            .map(
              (row) => ServiceMaterial(
                productId: row['product_id'] as String,
                quantity: row['quantity'] as int,
              ),
            )
            .toList();
      });

  Future<void> adjustStock(
    String productId,
    int delta,
    String reason, {
    int? totalCost,
    String? operationId,
  }) => _run(() async {
    final id = _id(productId);
    final explanation = _text(reason, 'El motivo', 500);
    if (delta == 0 || delta.abs() > _maxQuantity) {
      throw const CapcException('La cantidad del ajuste no es válida.');
    }
    if (totalCost != null) _money(totalCost, 'El costo total de entrada');
    final opId = operationId == null ? _uuid.v4() : _id(operationId);
    final request = jsonEncode({
      'productId': id,
      'delta': delta,
      'reason': explanation,
      'totalCost': totalCost,
    });
    await _db.transaction((txn) async {
      await _require(Permission.adjustStock, txn);
      if (await _operation(txn, opId, 'stock.adjust', request) != null) return;
      final product = await _getProduct(txn, id);
      if (delta > 0 && totalCost == null && !product.costKnown) {
        throw const CapcException(
          'Escribe el costo total de los materiales que entran.',
        );
      }
      final cost = delta > 0
          ? totalCost == null
                ? _multiply(delta, product.purchasePrice, scale: 1000000)
                : _multiply(totalCost, 1000000)
          : null;
      final movement = await _changeStock(
        txn,
        productId: id,
        delta: delta,
        costMicros: cost,
        reason: explanation,
        kind: delta > 0 ? 'Entrada' : 'Salida',
        referenceId: opId,
      );
      if (delta > 0 && product.stock == 0 && totalCost != null) {
        await txn.update(
          'products',
          {'cost_known': 1, 'cost_basis': 'weighted'},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await _recordOperation(
        txn,
        opId,
        'stock.adjust',
        request,
        movement.id,
        _now(),
      );
      await _enqueue(
        txn,
        'stock.adjusted',
        {
          'movementId': movement.id,
          'productId': id,
          'delta': delta,
          'costMicros': movement.costMicros,
          'reason': explanation,
          'movement': (await txn.query(
            'stock_movements',
            where: 'id = ?',
            whereArgs: [movement.id],
          )).single,
        },
        _now(),
        operationId: opId,
      );
    });
  });

  Future<StockMovement> _changeStock(
    DatabaseExecutor txn, {
    required String productId,
    required int delta,
    int? costMicros,
    required String reason,
    required String kind,
    String? referenceId,
    DateTime? date,
  }) async {
    final product = await _getProduct(txn, productId);
    if (product.isService) {
      throw const CapcException('Los servicios no tienen existencias propias.');
    }
    if (delta == 0 || delta.abs() > _maxQuantity) {
      throw const CapcException('La cantidad del movimiento no es válida.');
    }
    final next = product.stock + delta;
    if (next < 0) {
      throw CapcException(
        'Stock insuficiente para ${product.name}. Disponible: ${product.stock}.',
      );
    }
    _stock(next);
    int cost;
    if (delta < 0) {
      cost =
          costMicros ??
          _proportion(product.inventoryValueMicros, -delta, product.stock);
      if (cost > product.inventoryValueMicros) {
        throw const CapcException(
          'El movimiento supera el valor disponible del inventario.',
        );
      }
    } else {
      if (costMicros == null) {
        throw const CapcException('La entrada requiere un costo.');
      }
      cost = costMicros;
    }
    _micros(cost);
    final value = product.inventoryValueMicros + (delta > 0 ? cost : -cost);
    _micros(value);
    if (next == 0 && value != 0) {
      throw const CapcException(
        'La última salida debe consumir el valor restante del inventario.',
      );
    }
    final now = (date ?? DateTime.now()).toUtc().toIso8601String();
    await txn.update(
      'products',
      {'stock': next, 'inventory_value_micros': value, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [productId],
    );
    final actor = _actor;
    final id = _uuid.v4();
    await txn.insert('stock_movements', {
      'id': id,
      'product_id': productId,
      'product_name': product.name,
      'delta': delta,
      'cost_micros': cost,
      'reason': reason,
      'kind': kind,
      'created_at': now,
      'reference_id': referenceId,
      'actor_id': actor.id,
      'actor_name': actor.name,
      'business_id': businessId,
      'device_id': deviceId,
    });
    await _audit(txn, 'stock.moved', id, {
      'productId': productId,
      'delta': delta,
      'costMicros': cost,
      'reason': reason,
      'kind': kind,
      'referenceId': referenceId,
    }, now);
    return StockMovement(
      id: id,
      productId: productId,
      productName: product.name,
      delta: delta,
      costMicros: cost,
      reason: reason,
      kind: kind,
      createdAt: DateTime.parse(now),
      actorName: actor.name,
      referenceId: referenceId,
    );
  }

  Future<List<StockMovement>> listStockMovements({
    String? productId,
  }) => _run(() async {
    await _require(Permission.adjustStock);
    return (await _db.query(
          'stock_movements',
          where:
              'business_id = ?${productId == null ? '' : ' AND product_id = ?'}',
          whereArgs: [businessId, if (productId != null) _id(productId)],
          orderBy: 'created_at DESC, rowid DESC',
        ))
        .map(
          (r) => StockMovement(
            id: r['id'] as String,
            productId: r['product_id'] as String,
            productName: r['product_name'] as String,
            delta: r['delta'] as int,
            costMicros: r['cost_micros'] as int,
            reason: r['reason'] as String,
            kind: r['kind'] as String,
            createdAt: DateTime.parse(r['created_at'] as String).toUtc(),
            actorName: r['actor_name'] as String,
            referenceId: r['reference_id'] as String?,
          ),
        )
        .toList();
  });

  Future<List<Customer>> listCustomers({String query = ''}) => _run(() async {
    await _require(Permission.read);
    return (await _db.query(
          'customers',
          where:
              "business_id = ? AND (name LIKE ? ESCAPE '\\' OR phone LIKE ? ESCAPE '\\')",
          whereArgs: [businessId, _search(query), _search(query)],
          orderBy: 'name COLLATE NOCASE, id',
        ))
        .map(
          (r) => Customer(
            id: r['id'] as String,
            name: r['name'] as String,
            phone: r['phone'] as String,
          ),
        )
        .toList();
  });

  Future<void> saveCustomer(Customer customer) => _run(() async {
    final id = customer.id.trim().isEmpty ? _uuid.v4() : _id(customer.id);
    await _db.transaction((txn) async {
      await _require(Permission.manageCustomers, txn);
      final current = await txn.query(
        'customers',
        where: 'id = ? AND business_id = ?',
        whereArgs: [id, businessId],
      );
      final record = <String, Object?>{
        'name': _text(customer.name, 'El nombre del cliente', 160),
        'phone': _optionalText(customer.phone, 'El teléfono', 80),
        'updated_at': _now(),
        'revision': current.isEmpty
            ? 1
            : (current.single['revision'] as int) + 1,
      };
      if (current.isEmpty) {
        await txn.insert('customers', {
          'id': id,
          ...record,
          'business_id': businessId,
          'device_id': deviceId,
        });
      } else {
        await txn.update('customers', record, where: 'id = ?', whereArgs: [id]);
      }
      await _audit(txn, 'customer.saved', id, record, _now());
      await _enqueue(txn, 'customer.saved', {'id': id, ...record}, _now());
    });
  });

  Future<void> loadExampleCatalog() => _run(() async {
    await _db.transaction((txn) async {
      await _require(Permission.manageCatalog, txn);
      if ((await txn.query(
        'products',
        columns: ['id'],
        where: 'business_id = ?',
        whereArgs: [businessId],
        limit: 1,
      )).isNotEmpty) {
        throw const CapcException(
          'El catálogo de ejemplo solo se carga cuando no hay productos.',
        );
      }
      const examples = [
        ['MAT-001', 'Papel carta (hoja)', 'Hoja', false, 50, 100, 500, 100],
        ['MAT-002', 'Sobre manila carta', 'Unidad', false, 300, 700, 30, 10],
        ['MAT-003', 'Memoria USB 32 GB', 'Unidad', false, 16000, 25000, 8, 3],
        ['SER-001', 'Internet por hora', 'Hora', true, 0, 3000, 0, 0],
        ['SER-002', 'Digitación de documentos', 'Página', true, 0, 4000, 0, 0],
        [
          'SER-003',
          'Asesoría en trámites digitales',
          'Servicio',
          true,
          0,
          10000,
          0,
          0,
        ],
      ];
      for (final example in examples) {
        final id = _uuid.v4();
        final record = <String, Object?>{
          'id': id,
          'code': example[0],
          'name': example[1],
          'unit': example[2],
          'is_service': example[3] == true ? 1 : 0,
          'purchase_price': example[4],
          'sale_price': example[5],
          'stock': 0,
          'minimum_stock': example[7],
          'updated_at': _now(),
          'business_id': businessId,
          'device_id': deviceId,
        };
        await txn.insert('products', record);
        final stock = example[6] as int;
        if (stock > 0) {
          await _changeStock(
            txn,
            productId: id,
            delta: stock,
            costMicros: _multiply(stock, example[4] as int, scale: 1000000),
            reason: 'Stock de catálogo de ejemplo',
            kind: 'Inicial',
          );
        }
        await _enqueue(txn, 'product.saved', record, _now());
      }
      await _audit(txn, 'catalog.example_loaded', businessId, {}, _now());
    });
  });
  Future<List<Sale>> listSales({String query = ''}) => _run(() async {
    await _require(Permission.read);
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'sales',
        where:
            "business_id = ? AND (number LIKE ? ESCAPE '\\' OR customer_name LIKE ? ESCAPE '\\' OR operator_name LIKE ? ESCAPE '\\' OR id IN (SELECT sale_id FROM sale_lines WHERE code LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\'))",
        whereArgs: [businessId, ...List.filled(5, _search(query))],
        orderBy: 'created_at DESC, sequence DESC',
      );
      return [for (final row in rows) await _saleFromRow(txn, row)];
    });
  });

  Future<Sale> createSale({
    required List<CartLine> items,
    String? customerId,
    required int paid,
    required String paymentMethod,
    String operatorName = 'Caja principal',
    String? operationId,
    int? received,
    DateTime? dueAt,
    List<CustomSaleItem> customItems = const [],
  }) => _run(() async {
    return _db.transaction((txn) async {
      await _require(Permission.sell, txn);
      if (items.any((line) => line.unitPrice != null) ||
          customItems.isNotEmpty) {
        await _require(Permission.setPrices, txn);
      }
      return _createSaleInTxn(
        txn,
        items: items,
        customerId: customerId,
        paid: paid,
        paymentMethod: paymentMethod,
        operationId: operationId,
        received: received,
        dueAt: dueAt,
        customItems: customItems,
      );
    });
  });

  Future<Sale> _createSaleInTxn(
    DatabaseExecutor txn, {
    required List<CartLine> items,
    String? customerId,
    required int paid,
    required String paymentMethod,
    String? operationId,
    int? received,
    DateTime? dueAt,
    List<CustomSaleItem> customItems = const [],
    int prepaid = 0,
    String? sourceQuoteId,
  }) async {
    final actor = await _require(Permission.sell, txn);
    if (items.isEmpty && customItems.isEmpty) {
      throw const CapcException('Agrega al menos un producto o servicio.');
    }
    if (items.length + customItems.length > 1000) {
      throw const CapcException('Un documento admite hasta 1000 conceptos.');
    }
    _money(paid, 'El pago');
    _money(prepaid, 'El anticipo aplicado');
    final method = _method(paymentMethod, allowCredit: paid == 0);
    final tendered = _received(paid, received, method);
    final customer = customerId == null || customerId.trim().isEmpty
        ? null
        : _id(customerId);
    final opId = operationId == null ? _uuid.v4() : _id(operationId);
    final grouped = <String, CartLine>{};
    for (final item in items) {
      final id = _id(item.productId);
      _quantity(item.quantity);
      if (item.unitPrice != null) _money(item.unitPrice!, 'El precio');
      final key = jsonEncode([
        id,
        item.unitPrice,
        item.name,
        item.code,
        item.unit,
      ]);
      final quantity = (grouped[key]?.quantity ?? 0) + item.quantity;
      _quantity(quantity);
      grouped[key] = CartLine(
        productId: id,
        quantity: quantity,
        unitPrice: item.unitPrice,
        name: item.name,
        code: item.code,
        unit: item.unit,
      );
    }
    final keys = grouped.keys.toList()..sort();
    final request = jsonEncode({
      'items': [
        for (final key in keys)
          {'key': key, 'quantity': grouped[key]!.quantity},
      ],
      'custom': [
        for (final line in customItems)
          {
            'description': line.description,
            'unit': line.unit,
            'quantity': line.quantity,
            'price': line.unitPrice,
            'cost': line.unitCost,
          },
      ],
      'customerId': customer,
      'paid': paid,
      'received': tendered,
      'method': method,
      'dueAt': dueAt?.toUtc().toIso8601String(),
      'prepaid': prepaid,
      'quote': sourceQuoteId,
    });
    final previous = await _operation(txn, opId, 'sale.create', request);
    if (previous != null) return _getSale(txn, previous);
    await _openCashInTxn(txn);
    String customerName = 'Consumidor final';
    if (customer != null) {
      final rows = await txn.query(
        'customers',
        where: 'id = ? AND business_id = ?',
        whereArgs: [customer, businessId],
      );
      if (rows.isEmpty) {
        throw const CapcException('El cliente seleccionado no existe.');
      }
      customerName = rows.single['name'] as String;
    }
    final pendingLines = <Map<String, Object?>>[];
    final consumptions = <String, List<Map<String, Object?>>>{};
    final demand = <String, int>{};
    var total = 0;
    for (final key in keys) {
      final item = grouped[key]!;
      final product = await _getProduct(txn, item.productId);
      final lineId = _uuid.v4();
      final price = item.unitPrice ?? product.salePrice;
      final subtotal = _multiply(item.quantity, price, limit: _maxMoney);
      total = _sumMoney(total, subtotal);
      final consumption = <Map<String, Object?>>[];
      if (product.isService) {
        final recipe = await txn.query(
          'service_materials',
          where: 'service_id = ?',
          whereArgs: [product.id],
          orderBy: 'product_id',
        );
        for (final ingredient in recipe) {
          final quantity = _multiply(
            ingredient['quantity'] as int,
            item.quantity,
            limit: _maxQuantity,
          );
          consumption.add({
            'productId': ingredient['product_id'],
            'quantity': quantity,
          });
        }
      } else {
        consumption.add({'productId': product.id, 'quantity': item.quantity});
      }
      for (final material in consumption) {
        final materialId = material['productId'] as String;
        demand[materialId] =
            (demand[materialId] ?? 0) + (material['quantity'] as int);
        _quantity(demand[materialId]!);
      }
      consumptions[lineId] = consumption;
      pendingLines.add({
        'id': lineId,
        'product_id': product.id,
        'code': item.code == null
            ? product.code
            : _text(item.code!, 'El código', 80),
        'name': item.name == null
            ? product.name
            : _text(item.name!, 'El nombre', 500),
        'unit': item.unit == null
            ? product.unit
            : _text(item.unit!, 'La unidad', 40),
        'is_service': product.isService ? 1 : 0,
        'quantity': item.quantity,
        'unit_price': price,
        'unit_cost': product.purchasePrice,
        'direct_cost_micros': product.isService
            ? _multiply(item.quantity, product.purchasePrice, scale: 1000000)
            : 0,
        'cost_known': product.costKnown ? 1 : 0,
        'cost_basis': product.isService && product.costBasis == 'weighted'
            ? 'service'
            : product.costBasis,
      });
    }
    for (final item in customItems) {
      _quantity(item.quantity);
      _money(item.unitPrice, 'El precio');
      if (item.unitCost != null) _money(item.unitCost!, 'El costo');
      total = _sumMoney(
        total,
        _multiply(item.quantity, item.unitPrice, limit: _maxMoney),
      );
      pendingLines.add({
        'id': _uuid.v4(),
        'product_id': null,
        'code': 'PERSONALIZADO',
        'name': _text(item.description, 'La descripción', 500),
        'unit': _text(item.unit, 'La unidad', 40),
        'is_service': 1,
        'quantity': item.quantity,
        'unit_price': item.unitPrice,
        'unit_cost': item.unitCost ?? 0,
        'direct_cost_micros': _multiply(
          item.quantity,
          item.unitCost ?? 0,
          scale: 1000000,
        ),
        'cost_known': item.unitCost == null ? 0 : 1,
        'cost_basis': 'direct',
      });
    }
    for (final entry in demand.entries) {
      final material = await _getProduct(txn, entry.key);
      if (material.isService || material.stock < entry.value) {
        throw CapcException(
          'Stock insuficiente para ${material.name}. Disponible: ${material.stock}; requerido: ${entry.value}.',
        );
      }
    }
    final applied = _sumMoney(paid, prepaid);
    if (applied > total) {
      throw const CapcException(
        'El importe aplicado supera el total de la venta.',
      );
    }
    if (applied < total && customer == null) {
      throw const CapcException(
        'Selecciona un cliente para registrar una deuda.',
      );
    }
    if (applied < total && dueAt == null) {
      throw const CapcException('Indica el vencimiento de la venta a crédito.');
    }
    await txn.rawUpdate(
      "UPDATE counters SET value = value + 1 WHERE name = 'sale'",
    );
    final sequence =
        (await txn.query(
              'counters',
              where: 'name = ?',
              whereArgs: ['sale'],
            )).single['value']
            as int;
    final number = 'V-${sequence.toString().padLeft(6, '0')}';
    final saleId = _uuid.v4();
    final now = _now();
    await txn.insert('sales', {
      'id': saleId,
      'number': number,
      'sequence': sequence,
      'created_at': now,
      'customer_id': customer,
      'customer_name': customerName,
      'operator_name': actor.name,
      'actor_id': actor.id,
      'total': total,
      'paid': applied,
      'payment_method': method,
      'received': tendered,
      'change_amount': tendered - paid,
      'due_at': dueAt?.toUtc().toIso8601String(),
      'prepaid': prepaid,
      'source_quote_id': sourceQuoteId,
      'business_id': businessId,
      'device_id': deviceId,
    });
    var position = 0, saleCostMicros = 0;
    for (final line in pendingLines) {
      final lineId = line['id'] as String;
      var cost = line['direct_cost_micros'] as int;
      var known = line['cost_known'] == 1;
      final savedConsumption = <Map<String, Object?>>[];
      for (final material in consumptions[lineId] ?? <Map<String, Object?>>[]) {
        final materialId = material['productId'] as String;
        final product = await _getProduct(txn, materialId);
        known = known && product.costKnown;
        if (product.costBasis != 'weighted') {
          line['cost_basis'] = product.costBasis;
        }
        final movement = await _changeStock(
          txn,
          productId: materialId,
          delta: -(material['quantity'] as int),
          reason: 'Venta $number',
          kind: 'Venta',
          referenceId: saleId,
        );
        cost = _sumMicros(cost, movement.costMicros);
        savedConsumption.add({
          'id': _uuid.v4(),
          'sale_line_id': lineId,
          'product_id': materialId,
          'quantity': material['quantity'],
          'cost_micros': movement.costMicros,
          'cost_known': product.costKnown ? 1 : 0,
          'business_id': businessId,
        });
      }
      line['cost_total_micros'] = cost;
      saleCostMicros = _sumMicros(saleCostMicros, cost);
      line['cost_known'] = known ? 1 : 0;
      // Legacy whole-peso unit_cost is retained only as a display fallback.
      line['unit_cost'] = cost ~/ (line['quantity'] as int) ~/ 1000000;
      await txn.insert('sale_lines', {
        ...line,
        'sale_id': saleId,
        'position': position++,
        'business_id': businessId,
      });
      for (final consumption in savedConsumption) {
        await txn.insert('sale_consumptions', consumption);
      }
    }
    String? paymentId;
    if (paid > 0) {
      paymentId = await _insertPayment(
        txn,
        saleId,
        paid,
        method,
        tendered,
        now,
      );
      await _recordCash(
        txn,
        paid,
        method,
        'sale.payment',
        saleId,
        now,
        reason: 'Cobro de venta $number',
      );
    }
    await _recordOperation(txn, opId, 'sale.create', request, saleId, now);
    final sale = await _getSale(txn, saleId);
    final saleRecord = (await txn.query(
      'sales',
      where: 'id = ?',
      whereArgs: [saleId],
    )).single;
    final lineRecords = await txn.query(
      'sale_lines',
      where: 'sale_id = ?',
      whereArgs: [saleId],
      orderBy: 'position',
    );
    final lineIds = lineRecords.map((line) => line['id'] as String).toList();
    final consumptionRecords = <Map<String, Object?>>[];
    for (final lineId in lineIds) {
      consumptionRecords.addAll(
        await txn.query(
          'sale_consumptions',
          where: 'sale_line_id = ?',
          whereArgs: [lineId],
        ),
      );
    }
    final paymentRecords = await txn.query(
      'payments',
      where: 'sale_id = ? AND created_at = ?',
      whereArgs: [saleId, now],
    );
    final movementRecords = await txn.query(
      'stock_movements',
      where: 'reference_id = ?',
      whereArgs: [saleId],
    );
    await _enqueue(
      txn,
      'sale.created',
      {
        'saleId': saleId,
        'number': number,
        'total': total,
        'paid': applied,
        'received': tendered,
        'prepaid': prepaid,
        'paymentId': paymentId,
        'lines': sale.lines.map(_lineRecord).toList(),
        'sale': saleRecord,
        'saleLines': lineRecords,
        'consumptions': consumptionRecords,
        'payments': paymentRecords,
        'stockMovements': movementRecords,
        'cashMovements': await txn.query(
          'cash_movements',
          where: 'reference_id = ? AND created_at = ?',
          whereArgs: [saleId, now],
        ),
      },
      now,
      operationId: opId,
    );
    await _audit(txn, 'sale.created', saleId, {
      'number': number,
      'total': total,
      'paid': applied,
    }, now);
    return sale;
  }

  Future<void> addPayment(
    String saleId,
    int amount,
    String method, {
    String? operationId,
    int? received,
  }) => _run(() async {
    final id = _id(saleId);
    _money(amount, 'El abono', positive: true);
    final paymentMethod = _method(method);
    final tendered = _received(amount, received, paymentMethod);
    final opId = operationId == null ? _uuid.v4() : _id(operationId);
    final request = jsonEncode({
      'saleId': id,
      'amount': amount,
      'method': paymentMethod,
      'received': tendered,
    });
    await _db.transaction((txn) async {
      await _require(Permission.collect, txn);
      if (await _operation(txn, opId, 'payment.add', request) != null) return;
      final sale = await _getSale(txn, id);
      if (sale.cancelled || amount > sale.balance) {
        throw const CapcException(
          'El abono supera el saldo pendiente o la venta está anulada.',
        );
      }
      final now = _now();
      final paymentId = await _insertPayment(
        txn,
        id,
        amount,
        paymentMethod,
        tendered,
        now,
      );
      await _recordCash(
        txn,
        amount,
        paymentMethod,
        'sale.payment',
        id,
        now,
        reason: 'Abono a venta ${sale.number}',
      );
      await txn.rawUpdate('UPDATE sales SET paid = paid + ? WHERE id = ?', [
        amount,
        id,
      ]);
      await _recordOperation(txn, opId, 'payment.add', request, paymentId, now);
      await _audit(txn, 'payment.added', paymentId, {
        'saleId': id,
        'amount': amount,
        'received': tendered,
      }, now);
      await _enqueue(
        txn,
        'payment.added',
        {
          'paymentId': paymentId,
          'saleId': id,
          'amount': amount,
          'method': paymentMethod,
          'createdAt': now,
          'payment': (await txn.query(
            'payments',
            where: 'id = ?',
            whereArgs: [paymentId],
          )).single,
          'cashMovement': (await txn.query(
            'cash_movements',
            where: 'reference_id = ? AND created_at = ?',
            whereArgs: [id, now],
          )).single,
        },
        now,
        operationId: opId,
      );
    });
  });

  Future<String> _insertPayment(
    DatabaseExecutor txn,
    String saleId,
    int amount,
    String method,
    int received,
    String now,
  ) async {
    final id = _uuid.v4();
    await txn.insert('payments', {
      'id': id,
      'sale_id': saleId,
      'amount': amount,
      'created_at': now,
      'method': method,
      'received': received,
      'change_amount': received - amount,
      'actor_id': _actor.id,
      'actor_name': _actor.name,
      'business_id': businessId,
      'device_id': deviceId,
    });
    return id;
  }

  Future<void> _applyPrepaidInTxn(
    DatabaseExecutor txn,
    String saleId,
    int amount,
  ) async {
    await _require(Permission.collect, txn);
    _money(amount, 'El anticipo aplicado', positive: true);
    final sale = await _getSale(txn, saleId);
    if (sale.cancelled || amount > sale.balance) {
      throw const CapcException(
        'El anticipo supera el saldo de la venta o está anulada.',
      );
    }
    await txn.rawUpdate(
      'UPDATE sales SET paid = paid + ?, prepaid = prepaid + ? WHERE id = ?',
      [amount, amount, saleId],
    );
    await _audit(txn, 'advance.applied', saleId, {'amount': amount}, _now());
  }

  Future<List<Payment>> listPayments({String? saleId}) => _run(() async {
    await _require(Permission.read);
    final rows = await _db.query(
      'payments',
      where: 'business_id = ?${saleId == null ? '' : ' AND sale_id = ?'}',
      whereArgs: [businessId, if (saleId != null) _id(saleId)],
      orderBy: 'created_at DESC, rowid DESC',
    );
    return rows
        .map(
          (r) => Payment(
            id: r['id'] as String,
            saleId: r['sale_id'] as String,
            amount: r['amount'] as int,
            method: r['method'] as String,
            createdAt: DateTime.parse(r['created_at'] as String).toUtc(),
            received: r['received'] as int,
            change: r['change_amount'] as int,
            actorName: r['actor_name'] as String,
            kind: r['kind'] as String,
          ),
        )
        .toList();
  });
  Future<Sale> returnSale(
    String saleId,
    List<SaleReturnItem> items, {
    required String reason,
    String method = 'Efectivo',
    String? operationId,
  }) => _returnSale(
    saleId,
    items,
    reason: reason,
    method: method,
    operationId: operationId,
    cancel: false,
    restoreMaterials: true,
  );

  Future<Sale> cancelSale(
    String saleId, {
    required String reason,
    String method = 'Efectivo',
    bool restoreMaterials = true,
    String? operationId,
  }) => _returnSale(
    saleId,
    const [],
    reason: reason,
    method: method,
    operationId: operationId,
    cancel: true,
    restoreMaterials: restoreMaterials,
  );

  Future<Sale> _returnSale(
    String saleId,
    List<SaleReturnItem> items, {
    required String reason,
    required String method,
    String? operationId,
    required bool cancel,
    required bool restoreMaterials,
  }) => _run(() async {
    final id = _id(saleId);
    final explanation = _text(reason, 'El motivo', 500);
    final paymentMethod = _method(method);
    final opId = operationId == null ? _uuid.v4() : _id(operationId);
    final ordered = items.toList()
      ..sort((a, b) => a.saleLineId.compareTo(b.saleLineId));
    final request = jsonEncode({
      'saleId': id,
      'reason': explanation,
      'method': paymentMethod,
      'cancel': cancel,
      'restoreMaterials': restoreMaterials,
      'items': [
        for (final i in ordered)
          {'line': i.saleLineId, 'quantity': i.quantity, 'restock': i.restock},
      ],
    });
    return _db.transaction((txn) async {
      await _require(Permission.returns, txn);
      final kind = cancel ? 'sale.cancel' : 'sale.return';
      if (await _operation(txn, opId, kind, request) != null) {
        return _getSale(txn, id);
      }
      final sale = await _getSale(txn, id);
      if (sale.cancelled) {
        throw const CapcException('La venta ya está anulada.');
      }
      final actual = cancel
          ? [
              for (final line in sale.lines)
                if (line.remainingQuantity > 0)
                  SaleReturnItem(
                    saleLineId: line.id,
                    quantity: line.remainingQuantity,
                    restock: restoreMaterials,
                  ),
            ]
          : ordered;
      if (!cancel && actual.isEmpty) {
        throw const CapcException(
          'Selecciona al menos un concepto para devolver.',
        );
      }
      final seen = <String>{};
      var credit = 0, recovered = 0;
      final now = _now();
      final returnId = _uuid.v4();
      await txn.rawUpdate(
        "UPDATE counters SET value = value + 1 WHERE name = 'return'",
      );
      final sequence =
          (await txn.query(
                'counters',
                where: 'name = ?',
                whereArgs: ['return'],
              )).single['value']
              as int;
      final number = 'D-${sequence.toString().padLeft(6, '0')}';
      final details = <Map<String, Object?>>[];
      for (final item in actual) {
        _quantity(item.quantity);
        if (!seen.add(item.saleLineId)) {
          throw const CapcException(
            'Una línea aparece más de una vez en la devolución.',
          );
        }
        final matches = sale.lines.where((line) => line.id == item.saleLineId);
        if (matches.isEmpty) {
          throw const CapcException('El concepto no pertenece a esta venta.');
        }
        final line = matches.single;
        if (item.quantity > line.remainingQuantity) {
          throw const CapcException(
            'La cantidad a devolver supera la cantidad pendiente.',
          );
        }
        final amount = _multiply(
          item.quantity,
          line.unitPrice,
          limit: _maxMoney,
        );
        credit = _sumMoney(credit, amount);
        var lineRecovered = 0;
        if (item.restock) {
          final consumed = await txn.query(
            'sale_consumptions',
            where: 'sale_line_id = ?',
            whereArgs: [line.id],
          );
          for (final material in consumed) {
            final materialQuantity = material['quantity'] as int;
            // Each service recipe is an integer quantity per unit.
            final quantity = _proportion(
              materialQuantity,
              item.quantity,
              line.quantity,
            );
            if (quantity == 0) continue;
            final restored = (material['restored_quantity'] as int) + quantity;
            if (restored > materialQuantity) {
              throw const CapcException('Los materiales ya fueron devueltos.');
            }
            final cumulativeCost = _proportion(
              material['cost_micros'] as int,
              restored,
              materialQuantity,
            );
            final cost =
                cumulativeCost - (material['restored_cost_micros'] as int);
            final product = await _getProduct(
              txn,
              material['product_id'] as String,
            );
            await _changeStock(
              txn,
              productId: product.id,
              delta: quantity,
              costMicros: cost,
              reason: '$number · $explanation',
              kind: cancel ? 'Anulación' : 'Devolución',
              referenceId: returnId,
            );
            await txn.update(
              'products',
              {
                'cost_known':
                    (product.stock == 0
                        ? material['cost_known'] == 1
                        : product.costKnown && material['cost_known'] == 1)
                    ? 1
                    : 0,
                'cost_basis':
                    {'legacy', 'declared'}.contains(line.costBasis) ||
                        (product.stock > 0 &&
                            {'legacy', 'declared'}.contains(product.costBasis))
                    ? 'legacy'
                    : 'weighted',
              },
              where: 'id = ?',
              whereArgs: [product.id],
            );
            await txn.update(
              'sale_consumptions',
              {
                'restored_quantity': restored,
                'restored_cost_micros': cumulativeCost,
              },
              where: 'id = ?',
              whereArgs: [material['id']],
            );
            lineRecovered = _sumMicros(lineRecovered, cost);
          }
          // A cancellation declared unperformed also reverses its direct service cost.
          if (cancel && line.isService) {
            final record = (await txn.query(
              'sale_lines',
              where: 'id = ?',
              whereArgs: [line.id],
            )).single;
            lineRecovered = _sumMicros(
              lineRecovered,
              _proportion(
                record['direct_cost_micros'] as int,
                item.quantity,
                line.quantity,
              ),
            );
          }
        }
        recovered = _sumMicros(recovered, lineRecovered);
        await txn.update(
          'sale_lines',
          {
            'returned_quantity': line.returnedQuantity + item.quantity,
            'recovered_cost_micros': line.recoveredCostMicros + lineRecovered,
          },
          where: 'id = ?',
          whereArgs: [line.id],
        );
        details.add({
          'id': _uuid.v4(),
          'return_id': returnId,
          'sale_line_id': line.id,
          'quantity': item.quantity,
          'amount': amount,
          'restock': item.restock ? 1 : 0,
          'cost_reversed_micros': lineRecovered,
          'business_id': businessId,
        });
      }
      final netAfter = sale.netTotal - credit;
      final refund = max(0, sale.paid - netAfter);
      await txn.insert('sale_returns', {
        'id': returnId,
        'sale_id': id,
        'number': number,
        'created_at': now,
        'amount': credit,
        'refund': refund,
        'method': paymentMethod,
        'actor_id': _actor.id,
        'actor_name': _actor.name,
        'reason': explanation,
        'cost_reversed_micros': recovered,
        'cancelled': cancel ? 1 : 0,
        'business_id': businessId,
        'device_id': deviceId,
      });
      for (final detail in details) {
        await txn.insert('sale_return_lines', detail);
      }
      if (refund > 0) {
        await _recordCash(
          txn,
          -refund,
          paymentMethod,
          'sale.refund',
          returnId,
          now,
          reason: 'Reintegro $number de ${sale.number}',
        );
        await txn.insert('payments', {
          'id': _uuid.v4(),
          'sale_id': id,
          'amount': -refund,
          'created_at': now,
          'method': paymentMethod,
          'received': 0,
          'change_amount': 0,
          'actor_id': _actor.id,
          'actor_name': _actor.name,
          'kind': 'Reintegro',
          'business_id': businessId,
          'device_id': deviceId,
        });
      }
      await txn.update(
        'sales',
        {
          'returned_total': sale.returnedTotal + credit,
          'paid': sale.paid - refund,
          'refunded': sale.refunded + refund,
          'cancelled': cancel ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await _recordOperation(txn, opId, kind, request, returnId, now);
      await _audit(txn, kind, id, {
        'returnId': returnId,
        'amount': credit,
        'refund': refund,
        'costReversedMicros': recovered,
        'reason': explanation,
      }, now);
      await _enqueue(
        txn,
        kind,
        {
          'saleId': id,
          'returnId': returnId,
          'amount': credit,
          'refund': refund,
          'costReversedMicros': recovered,
          'lines': details,
          'return': (await txn.query(
            'sale_returns',
            where: 'id = ?',
            whereArgs: [returnId],
          )).single,
          'stockMovements': await txn.query(
            'stock_movements',
            where: 'reference_id = ?',
            whereArgs: [returnId],
          ),
          'refundPayments': await txn.query(
            'payments',
            where: "sale_id = ? AND created_at = ? AND kind = 'Reintegro'",
            whereArgs: [id, now],
          ),
          'cashMovements': await txn.query(
            'cash_movements',
            where: 'reference_id = ? AND created_at = ?',
            whereArgs: [returnId, now],
          ),
        },
        now,
        operationId: opId,
      );
      return _getSale(txn, id);
    });
  });

  Future<List<SaleReturnRecord>> listSaleReturns({String? saleId}) =>
      _run(() async {
        await _require(Permission.read);
        final records = await _db.query(
          'sale_returns',
          where: 'business_id = ?${saleId == null ? '' : ' AND sale_id = ?'}',
          whereArgs: [businessId, if (saleId != null) _id(saleId)],
          orderBy: 'created_at DESC, rowid DESC',
        );
        final result = <SaleReturnRecord>[];
        for (final r in records) {
          final lines = await _db.query(
            'sale_return_lines',
            where: 'return_id = ?',
            whereArgs: [r['id']],
          );
          result.add(
            SaleReturnRecord(
              id: r['id'] as String,
              saleId: r['sale_id'] as String,
              number: r['number'] as String,
              createdAt: DateTime.parse(r['created_at'] as String).toUtc(),
              amount: r['amount'] as int,
              refund: r['refund'] as int,
              method: r['method'] as String,
              actorName: r['actor_name'] as String,
              reason: r['reason'] as String,
              costReversedMicros: r['cost_reversed_micros'] as int,
              cancelled: r['cancelled'] == 1,
              items: [
                for (final line in lines)
                  SaleReturnItem(
                    saleLineId: line['sale_line_id'] as String,
                    quantity: line['quantity'] as int,
                    restock: line['restock'] == 1,
                  ),
              ],
            ),
          );
        }
        return result;
      });
  Future<Map<String, Object?>> _openCashInTxn(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'cash_sessions',
      where: 'business_id = ? AND closed_at IS NULL',
      whereArgs: [businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException(
        'Abre la caja antes de registrar ventas o movimientos de dinero.',
      );
    }
    return rows.single;
  }

  Future<int> _expectedCash(
    DatabaseExecutor txn,
    Map<String, Object?> session,
  ) async {
    final rows = await txn.query(
      'cash_movements',
      columns: ['amount'],
      where: "session_id = ? AND method = 'Efectivo'",
      whereArgs: [session['id']],
    );
    var total = BigInt.from(session['opening_amount'] as int);
    for (final row in rows) {
      total += BigInt.from(row['amount'] as int);
    }
    if (total < BigInt.zero || total > BigInt.from(_maxMoney)) {
      throw const CapcException(
        'El saldo de caja está fuera del rango permitido.',
      );
    }
    return total.toInt();
  }

  Future<CashSession?> currentCashSession() => _run(() async {
    await _require(Permission.manageCash);
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'cash_sessions',
        where: 'business_id = ? AND closed_at IS NULL',
        whereArgs: [businessId],
      );
      return rows.isEmpty ? null : _cashSession(txn, rows.single);
    });
  });

  Future<CashSession> openCash(int openingAmount, {String? operationId}) =>
      _run(() async {
        _money(openingAmount, 'El efectivo inicial');
        final opId = operationId == null ? _uuid.v4() : _id(operationId);
        final request = jsonEncode({'openingAmount': openingAmount});
        return _db.transaction((txn) async {
          final actor = await _require(Permission.manageCash, txn);
          final previous = await _operation(txn, opId, 'cash.open', request);
          if (previous != null) {
            return _cashSession(
              txn,
              (await txn.query(
                'cash_sessions',
                where: 'id = ?',
                whereArgs: [previous],
              )).single,
            );
          }
          if ((await txn.query(
            'cash_sessions',
            columns: ['id'],
            where: 'business_id = ? AND closed_at IS NULL',
            whereArgs: [businessId],
          )).isNotEmpty) {
            throw const CapcException('Ya existe una caja abierta.');
          }
          final id = _uuid.v4(), now = _now();
          await txn.insert('cash_sessions', {
            'id': id,
            'opened_at': now,
            'opening_amount': openingAmount,
            'opened_by': actor.id,
            'opened_name': actor.name,
            'business_id': businessId,
            'device_id': deviceId,
          });
          await _recordOperation(txn, opId, 'cash.open', request, id, now);
          await _audit(txn, 'cash.opened', id, {
            'openingAmount': openingAmount,
          }, now);
          await _enqueue(
            txn,
            'cash.opened',
            {
              'id': id,
              'openingAmount': openingAmount,
              'session': (await txn.query(
                'cash_sessions',
                where: 'id = ?',
                whereArgs: [id],
              )).single,
            },
            now,
            operationId: opId,
          );
          return _cashSession(
            txn,
            (await txn.query(
              'cash_sessions',
              where: 'id = ?',
              whereArgs: [id],
            )).single,
          );
        });
      });

  Future<CashSession> closeCash(
    int countedAmount, {
    String note = '',
    String? operationId,
  }) => _run(() async {
    _money(countedAmount, 'El efectivo contado');
    final explanation = _optionalText(note, 'La observación', 500);
    final opId = operationId == null ? _uuid.v4() : _id(operationId);
    final request = jsonEncode({
      'countedAmount': countedAmount,
      'note': explanation,
    });
    return _db.transaction((txn) async {
      final actor = await _require(Permission.manageCash, txn);
      final previous = await _operation(txn, opId, 'cash.close', request);
      if (previous != null) {
        return _cashSession(
          txn,
          (await txn.query(
            'cash_sessions',
            where: 'id = ?',
            whereArgs: [previous],
          )).single,
        );
      }
      final row = await _openCashInTxn(txn);
      if (actor.role == UserRole.cashier && row['opened_by'] != actor.id) {
        throw const CapcException(
          'Solo quien abrió la caja o un administrador puede cerrarla.',
        );
      }
      final expected = await _expectedCash(txn, row);
      final now = _now();
      await txn.update(
        'cash_sessions',
        {
          'closed_at': now,
          'expected_amount': expected,
          'counted_amount': countedAmount,
          'difference': countedAmount - expected,
          'closed_by': actor.id,
          'closed_name': actor.name,
          'note': explanation,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      await _recordOperation(
        txn,
        opId,
        'cash.close',
        request,
        row['id'] as String,
        now,
      );
      await _audit(txn, 'cash.closed', row['id'] as String, {
        'expected': expected,
        'counted': countedAmount,
        'difference': countedAmount - expected,
        'note': explanation,
      }, now);
      await _enqueue(
        txn,
        'cash.closed',
        {
          'id': row['id'],
          'expected': expected,
          'counted': countedAmount,
          'session': (await txn.query(
            'cash_sessions',
            where: 'id = ?',
            whereArgs: [row['id']],
          )).single,
        },
        now,
        operationId: opId,
      );
      return _cashSession(
        txn,
        (await txn.query(
          'cash_sessions',
          where: 'id = ?',
          whereArgs: [row['id']],
        )).single,
      );
    });
  });

  Future<void> _recordCash(
    DatabaseExecutor txn,
    int amount,
    String method,
    String kind,
    String referenceId,
    String now, {
    required String reason,
  }) async {
    _money(amount.abs(), 'El movimiento', positive: true);
    final paymentMethod = _method(method);
    final session = await _openCashInTxn(txn);
    if (paymentMethod == 'Efectivo') {
      final after = (await _expectedCash(txn, session)) + amount;
      if (after < 0) {
        throw const CapcException(
          'No hay efectivo suficiente en caja para esta salida.',
        );
      }
      _money(after, 'El saldo de caja');
    }
    await txn.insert('cash_movements', {
      'id': _uuid.v4(),
      'session_id': session['id'],
      'amount': amount,
      'method': paymentMethod,
      'kind': kind,
      'reference_id': referenceId,
      'reason': reason,
      'created_at': now,
      'actor_id': _actor.id,
      'actor_name': _actor.name,
      'business_id': businessId,
      'device_id': deviceId,
    });
  }

  Future<void> addExpense(
    int amount,
    String reason, {
    String method = 'Efectivo',
    String? operationId,
  }) => _cashAdjustment(
    -amount,
    reason,
    method: method,
    operationId: operationId,
    expense: true,
  );

  Future<void> addCashAdjustment(
    int amount,
    String reason, {
    String method = 'Efectivo',
    String? operationId,
  }) => _cashAdjustment(
    amount,
    reason,
    method: method,
    operationId: operationId,
    expense: false,
  );

  Future<void> _cashAdjustment(
    int amount,
    String reason, {
    required String method,
    String? operationId,
    required bool expense,
  }) => _run(() async {
    _money(
      amount.abs(),
      expense ? 'El gasto' : 'El movimiento',
      positive: true,
    );
    if (expense && amount >= 0) {
      throw const CapcException('El gasto debe ser mayor que cero.');
    }
    final explanation = _text(reason, 'El motivo', 500),
        paymentMethod = _method(method);
    final opId = operationId == null ? _uuid.v4() : _id(operationId);
    final kind = expense ? 'expense' : 'cash.adjustment';
    final request = jsonEncode({
      'amount': amount,
      'method': paymentMethod,
      'reason': explanation,
    });
    await _db.transaction((txn) async {
      await _require(Permission.expense, txn);
      if (await _operation(txn, opId, kind, request) != null) return;
      final id = _uuid.v4(), now = _now();
      await _recordCash(
        txn,
        amount,
        paymentMethod,
        kind,
        id,
        now,
        reason: explanation,
      );
      if (expense) {
        await txn.insert('expenses', {
          'id': id,
          'amount': -amount,
          'method': paymentMethod,
          'reason': explanation,
          'created_at': now,
          'actor_id': _actor.id,
          'actor_name': _actor.name,
          'business_id': businessId,
          'device_id': deviceId,
        });
      }
      await _recordOperation(txn, opId, kind, request, id, now);
      await _audit(txn, kind, id, {
        'amount': amount,
        'method': paymentMethod,
        'reason': explanation,
      }, now);
      await _enqueue(
        txn,
        kind,
        {
          'id': id,
          'amount': amount,
          'method': paymentMethod,
          'reason': explanation,
          'cashMovement': (await txn.query(
            'cash_movements',
            where: 'reference_id = ? AND created_at = ?',
            whereArgs: [id, now],
          )).single,
          if (expense)
            'expense': (await txn.query(
              'expenses',
              where: 'id = ?',
              whereArgs: [id],
            )).single,
        },
        now,
        operationId: opId,
      );
    });
  });

  Future<List<CashSession>> listCashSessions() => _run(() async {
    final actor = await _require(Permission.manageCash);
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'cash_sessions',
        where:
            'business_id = ?${actor.role == UserRole.cashier ? ' AND opened_by = ?' : ''}',
        whereArgs: [businessId, if (actor.role == UserRole.cashier) actor.id],
        orderBy: 'opened_at DESC',
      );
      return [for (final row in rows) await _cashSession(txn, row)];
    });
  });

  Future<CashSession> _cashSession(
    DatabaseExecutor txn,
    Map<String, Object?> row,
  ) async => CashSession(
    id: row['id'] as String,
    openedAt: DateTime.parse(row['opened_at'] as String).toUtc(),
    closedAt: row['closed_at'] == null
        ? null
        : DateTime.parse(row['closed_at'] as String).toUtc(),
    openingAmount: row['opening_amount'] as int,
    expectedAmount: row['closed_at'] == null
        ? await _expectedCash(txn, row)
        : row['expected_amount'] as int,
    countedAmount: row['counted_amount'] as int?,
    difference: row['difference'] as int?,
    openedBy: row['opened_name'] as String,
    closedBy: row['closed_name'] as String?,
    note: row['note'] as String,
  );

  Future<List<CashMovement>> listCashMovements({
    String? sessionId,
  }) => _run(() async {
    final actor = await _require(Permission.manageCash);
    final rows = await _db.query(
      'cash_movements',
      where:
          'business_id = ?${sessionId == null ? '' : ' AND session_id = ?'}${actor.role == UserRole.cashier ? ' AND actor_id = ?' : ''}',
      whereArgs: [
        businessId,
        if (sessionId != null) _id(sessionId),
        if (actor.role == UserRole.cashier) actor.id,
      ],
      orderBy: 'created_at DESC, rowid DESC',
    );
    return rows
        .map(
          (r) => CashMovement(
            id: r['id'] as String,
            sessionId: r['session_id'] as String,
            amount: r['amount'] as int,
            method: r['method'] as String,
            kind: r['kind'] as String,
            reason: r['reason'] as String,
            createdAt: DateTime.parse(r['created_at'] as String).toUtc(),
            actorName: r['actor_name'] as String,
            referenceId: r['reference_id'] as String?,
          ),
        )
        .toList();
  });

  Future<List<AuditEntry>> listAudit() => _run(() async {
    await _require(Permission.viewAudit);
    return (await _db.query(
          'audit',
          where: 'business_id = ?',
          whereArgs: [businessId],
          orderBy: 'created_at DESC, rowid DESC',
        ))
        .map(
          (r) => AuditEntry(
            id: r['id'] as String,
            action: r['action'] as String,
            entityId: r['entity_id'] as String,
            actorName: r['actor_name'] as String,
            createdAt: DateTime.parse(r['created_at'] as String).toUtc(),
            details: r['details'] as String,
          ),
        )
        .toList();
  });
  Future<void> backupTo(String destination) => _run(() async {
    await _require(Permission.backup);
    final target = p.normalize(
      p.absolute(_text(destination, 'La ubicación', 4096)),
    );
    if (_samePath(target, databasePath)) {
      throw const CapcException(
        'El respaldo no puede reemplazar la base de datos actual.',
      );
    }
    await _snapshotTo(target);
    await _db.transaction((txn) async {
      await _require(Permission.backup, txn);
      await _audit(txn, 'backup.created', businessId, {
        'destination': target,
      }, _now());
    });
  });

  Future<void> _snapshotTo(String target) async {
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CapcException(
        'Ya existe un archivo en ese destino. Elige un nombre nuevo.',
      );
    }
    if (!await Directory(p.dirname(target)).exists()) {
      throw const CapcException('La carpeta de destino no existe.');
    }
    try {
      await File(target).create(exclusive: true);
    } on FileSystemException {
      throw const CapcException(
        'No se puede crear el respaldo en esa ubicación.',
      );
    }
    try {
      await _db.execute('VACUUM INTO ?', [target]);
      await validateBackup(target);
    } catch (_) {
      // Only this call's newly reserved output is removed; existing destinations are never touched.
      if (await File(target).exists()) await File(target).delete();
      rethrow;
    }
  }

  /// Read-only validation, usable from the startup recovery screen.
  static Future<void> validateBackup(String path) async {
    if (!await File(path).exists() || await File(path).length() < 100) {
      throw const CapcException(
        'El archivo no contiene un respaldo SQLite completo.',
      );
    }
    native.Database? db;
    try {
      db = native.sqlite3.open(path, mode: native.OpenMode.readOnly);
      final version =
          db.select('PRAGMA user_version').single.values.single as int;
      final app =
          db.select('PRAGMA application_id').single.values.single as int;
      if (version < 1 ||
          version > _schemaVersion ||
          (app != _applicationId && !(version == 1 && app == 0))) {
        throw const CapcException(
          'El archivo no es un respaldo compatible de CAPC.',
        );
      }
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toSet();
      final required = {
        'products',
        'customers',
        'sales',
        'sale_lines',
        'payments',
        'stock_movements',
        'operations',
        'outbox',
        'counters',
        if (version >= 2) ...{
          'settings',
          'users',
          'service_materials',
          'sale_consumptions',
          'sale_returns',
          'sale_return_lines',
          'cash_sessions',
          'cash_movements',
          'expenses',
          'audit',
          'suppliers',
          'purchases',
          'purchase_lines',
          'supplier_payments',
          'quotes',
          'quote_lines',
          'work_orders',
          'work_advances',
        },
        if (version >= 3) ...{'inbox', 'sync_state', 'sync_conflicts'},
      };
      if (!tables.containsAll(required)) {
        throw const CapcException('Al respaldo le faltan tablas necesarias.');
      }
      final integrity = db.select('PRAGMA integrity_check');
      if (integrity.length != 1 ||
          integrity.single.values.single != 'ok' ||
          db.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const CapcException(
          'El respaldo está dañado o tiene referencias inválidas.',
        );
      }
      // Application writes use no SQL triggers. Reject executable additions in imported files.
      if (db
          .select(
            "SELECT name FROM sqlite_master WHERE type IN ('trigger','view')",
          )
          .isNotEmpty) {
        throw const CapcException(
          'El archivo contiene cambios de esquema no reconocidos.',
        );
      }
      final incoherent = db.select('''SELECT s.id FROM sales s WHERE s.paid !=
        COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.sale_id=s.id),0)
        ${version >= 2 ? '+ s.prepaid' : ''} LIMIT 1''');
      if (incoherent.isNotEmpty) {
        throw const CapcException(
          'Los saldos del respaldo no coinciden con su historial de pagos.',
        );
      }
      if (version == 2) {
        for (final query in [
          '''SELECT p.id FROM purchases p WHERE p.paid !=
            COALESCE((SELECT SUM(amount) FROM supplier_payments s WHERE s.purchase_id=p.id),0)
            OR p.total != COALESCE((SELECT SUM(total_cost) FROM purchase_lines l WHERE l.purchase_id=p.id),0) LIMIT 1''',
          '''SELECT q.id FROM quotes q WHERE q.total !=
            COALESCE((SELECT SUM(quantity*unit_price) FROM quote_lines l WHERE l.quote_id=q.id),0) LIMIT 1''',
          '''SELECT s.id FROM sales s WHERE s.prepaid !=
            COALESCE((SELECT SUM(amount) FROM work_advances a WHERE a.sale_id=s.id),0) LIMIT 1''',
        ]) {
          if (db.select(query).isNotEmpty) {
            throw const CapcException(
              'Los documentos del respaldo no coinciden con sus líneas, pagos o anticipos.',
            );
          }
        }
        final settings = db.select(
          "SELECT key,value FROM settings WHERE key IN ('business_id','device_id')",
        );
        if (settings.length != 2 ||
            settings.any((r) => (r['value'] as String).isEmpty)) {
          throw const CapcException(
            'El respaldo no identifica el negocio y el equipo.',
          );
        }
      }
    } on CapcException {
      rethrow;
    } catch (_) {
      throw const CapcException(
        'No se pudo validar el respaldo. Conserva tus datos actuales y selecciona otro archivo.',
      );
    } finally {
      db?.close();
    }
  }

  /// Restores a validated snapshot after saving a consistent copy of current data.
  /// Progress callbacks also make interruption/rollback testable without weakening authentication.
  Future<String> restoreFrom(
    String source, {
    Future<void> Function(String stage)? onProgress,
  }) async {
    final actor = await _run(() => _require(Permission.restore));
    final target = p.normalize(p.absolute(source));
    if (_samePath(target, databasePath) ||
        databasePath == inMemoryDatabasePath) {
      throw const CapcException(
        'Selecciona un respaldo distinto de la base de datos activa.',
      );
    }
    await validateBackup(target);
    if (_maintenance || _closed) {
      throw const CapcException(
        'Los datos están ocupados. Vuelve a intentarlo.',
      );
    }
    _maintenance = true;
    await _waitForOperations();
    final stamp =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-${_uuid.v4()}';
    final previous = '$databasePath.antes-restaurar-$stamp.sqlite';
    final staged = '$databasePath.restaurando-$stamp.sqlite';
    final displaced = '$databasePath.reemplazado-$stamp';
    final oldDevice = deviceId;
    var originalMoved = false,
        replacementMoved = false,
        connectionClosed = false;
    RandomAccessFile? restoreLock;
    final journal = <String, Object?>{
      'version': 1,
      'database': databasePath,
      'original': displaced,
      'previous': previous,
      'staged': staged,
      'kind': 'restore',
      'originalPresent': true,
      'phase': 'prepared',
    };
    try {
      restoreLock = await _acquireRestoreLock(databasePath);
      await _require(Permission.restore);
      // VACUUM INTO reads a coherent source even if a chosen database has WAL data.
      await _copySnapshot(target, staged);
      await validateBackup(staged);
      await _snapshotTo(previous);
      if (onProgress != null) await onProgress('validated');
      await _writeRestoreJournal(databasePath, journal);
      await _db.close();
      connectionClosed = true;
      await File(databasePath).rename(displaced);
      originalMoved = true;
      await _moveSidecars(databasePath, displaced);
      await File(staged).rename(databasePath);
      replacementMoved = true;
      if (onProgress != null) await onProgress('replaced');
      _db = await _openDatabase(databasePath);
      connectionClosed = false;
      final values = await _db.query('settings');
      _businessId =
          values.singleWhere((r) => r['key'] == 'business_id')['value']
              as String;
      _deviceId = oldDevice;
      await _db.transaction((txn) async {
        await txn.update(
          'settings',
          {'value': oldDevice},
          where: 'key = ?',
          whereArgs: ['device_id'],
        );
        await txn.insert('audit', {
          'id': _uuid.v4(),
          'action': 'backup.restored',
          'entity_id': _businessId,
          'actor_id': actor.id,
          'actor_name': actor.name,
          'created_at': _now(),
          'details': jsonEncode({'source': target, 'previous': previous}),
          'business_id': _businessId,
          'device_id': _deviceId,
        });
      });
      if (onProgress != null) await onProgress('reopened');
      await _writeRestoreJournal(databasePath, {
        ...journal,
        'phase': 'complete',
      });
      logout();
      await _deleteDatabaseFiles(displaced);
      await File('$databasePath.restore-journal.json').delete();
      return previous;
    } catch (_) {
      try {
        if (!connectionClosed && originalMoved) {
          await _db.close();
          connectionClosed = true;
        }
        if (replacementMoved) await _deleteDatabaseFiles(databasePath);
        if (originalMoved) {
          await File(displaced).rename(databasePath);
          await _moveSidecars(displaced, databasePath);
        }
        if (connectionClosed) {
          _db = await _openDatabase(databasePath);
          connectionClosed = false;
        }
        final values = await _db.query('settings');
        _businessId =
            values.singleWhere((r) => r['key'] == 'business_id')['value']
                as String;
        _deviceId =
            values.singleWhere((r) => r['key'] == 'device_id')['value']
                as String;
        logout();
        final marker = File('$databasePath.restore-journal.json');
        if (await marker.exists()) await marker.delete();
      } catch (_) {
        _closed = true;
        throw CapcException(
          'No se pudo completar la recuperación. La copia anterior se conserva en $previous y los archivos originales en $displaced.',
        );
      }
      throw CapcException(
        'La restauración no se completó. Se recuperaron los datos anteriores. Copia previa: $previous',
      );
    } finally {
      if (!await File('$databasePath.restore-journal.json').exists() &&
          await File(staged).exists()) {
        await File(staged).delete();
      }
      if (restoreLock != null) {
        await restoreLock.unlock();
        await restoreLock.close();
      }
      _maintenance = false;
    }
  }

  /// Startup recovery authenticates an owner from the valid backup, preserving
  /// the unreadable original and any WAL/SHM files before the replacement.
  static Future<String> recoverDatabase({
    required String databasePath,
    required String backupPath,
    required String username,
    required String password,
  }) async {
    final destination = p.normalize(p.absolute(databasePath));
    final source = p.normalize(p.absolute(backupPath));
    if (_samePath(destination, source)) {
      throw const CapcException(
        'Selecciona un respaldo distinto de los datos dañados.',
      );
    }
    await validateBackup(source);
    final reader = native.sqlite3.open(source, mode: native.OpenMode.readOnly);
    LocalUser owner;
    try {
      if ((reader.select('PRAGMA user_version').single.values.single as int) <
          2) {
        throw const CapcException(
          'Este respaldo antiguo no contiene cuentas. Restaúralo desde una sesión propietaria de CAPC.',
        );
      }
      final rows = reader.select(
        "SELECT * FROM users WHERE username = ? COLLATE NOCASE AND active=1 AND role='owner'",
        [username.trim()],
      );
      if (rows.length != 1 || !await _verifyPassword(password, rows.single)) {
        throw const CapcException(
          'Introduce una cuenta propietaria y su contraseña válidas en este respaldo.',
        );
      }
      owner = _user(rows.single);
    } finally {
      reader.close();
    }
    await Directory(p.dirname(destination)).create(recursive: true);
    final stamp = _uuid.v4();
    final staged = '$destination.recuperando-$stamp.sqlite';
    final folder = '$destination.antes-recuperar-$stamp';
    await _copySnapshot(source, staged);
    await validateBackup(staged);
    final moved = <String>[];
    var replacementMoved = false;
    Database? restored;
    RandomAccessFile? restoreLock;
    final journal = <String, Object?>{
      'version': 1,
      'database': destination,
      'original': p.join(folder, p.basename(destination)),
      'previous': folder,
      'staged': staged,
      'kind': 'startup',
      'originalPresent': await File(destination).exists(),
      'phase': 'prepared',
    };
    try {
      restoreLock = await _acquireRestoreLock(destination);
      await Directory(folder).create();
      await _writeRestoreJournal(destination, journal);
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$destination$suffix');
        if (await file.exists()) {
          await file.rename(
            p.join(folder, '${p.basename(destination)}$suffix'),
          );
          moved.add(suffix);
        }
      }
      await File(staged).rename(destination);
      replacementMoved = true;
      restored = await _openDatabase(destination);
      final business =
          (await restored.query(
                'settings',
                where: 'key = ?',
                whereArgs: ['business_id'],
              )).single['value']
              as String;
      final device = _uuid.v4();
      await restored.update(
        'settings',
        {'value': device},
        where: 'key = ?',
        whereArgs: ['device_id'],
      );
      await restored.insert('audit', {
        'id': _uuid.v4(),
        'action': 'backup.startup_recovered',
        'entity_id': business,
        'actor_id': owner.id,
        'actor_name': owner.name,
        'created_at': _now(),
        'details': jsonEncode({'source': source, 'previous': folder}),
        'business_id': business,
        'device_id': device,
      });
      await restored.close();
      restored = null;
      await _writeRestoreJournal(destination, {
        ...journal,
        'phase': 'complete',
      });
      await File('$destination.restore-journal.json').delete();
      return folder;
    } catch (_) {
      if (restored != null) await restored.close();
      if (replacementMoved) await _deleteDatabaseFiles(destination);
      for (final suffix in moved.reversed) {
        await File(
          p.join(folder, '${p.basename(destination)}$suffix'),
        ).rename('$destination$suffix');
      }
      final marker = File('$destination.restore-journal.json');
      if (await marker.exists()) await marker.delete();
      throw CapcException(
        'La recuperación falló y se conservaron los archivos originales. Copia: $folder',
      );
    } finally {
      if (!await File('$destination.restore-journal.json').exists() &&
          await File(staged).exists()) {
        await File(staged).delete();
      }
      if (restoreLock != null) {
        await restoreLock.unlock();
        await restoreLock.close();
      }
    }
  }

  static Future<RandomAccessFile> _acquireRestoreLock(String path) async {
    final handle = await File('$path.restore-lock').open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return handle;
    } catch (_) {
      await handle.close();
      throw const CapcException(
        'Otro proceso está restaurando los datos. Espera a que termine.',
      );
    }
  }

  static Future<void> _writeRestoreJournal(
    String path,
    Map<String, Object?> journal,
  ) async {
    final temporary = File('$path.restore-journal.next');
    await temporary.writeAsString(jsonEncode(journal), flush: true);
    await temporary.rename('$path.restore-journal.json');
  }

  static Future<Map<String, Object?>?> _recoverInterruptedRestore(
    String path,
  ) async {
    final marker = File('$path.restore-journal.json');
    if (!await marker.exists()) return null;
    final lock = await _acquireRestoreLock(path);
    try {
      if (!await marker.exists()) return null;
      final journal = Map<String, Object?>.from(
        jsonDecode(await marker.readAsString()) as Map,
      );
      if (journal['version'] != 1 ||
          journal['database'] is! String ||
          !_samePath(journal['database'] as String, path)) {
        throw const CapcException(
          'El registro de restauración no corresponde a estos datos. No se ha creado una base vacía.',
        );
      }
      final kind = journal['kind'];
      String checkedPath(String field, String prefix, {bool nested = false}) {
        final value = journal[field];
        if (value is! String) {
          throw const CapcException(
            'El registro de restauración está incompleto.',
          );
        }
        final resolved = p.normalize(p.absolute(value));
        final parent = p.dirname(path);
        final starts = appPlatform.caseInsensitivePaths
            ? resolved.toLowerCase().startsWith(prefix.toLowerCase())
            : resolved.startsWith(prefix);
        if (!starts ||
            !p.isWithin(parent, resolved) ||
            (!nested && !_samePath(p.dirname(resolved), parent))) {
          throw const CapcException(
            'El registro de restauración contiene una ubicación no permitida.',
          );
        }
        return resolved;
      }

      final original = checkedPath(
        'original',
        kind == 'startup' ? '$path.antes-recuperar-' : '$path.reemplazado-',
        nested: kind == 'startup',
      );
      final previous = checkedPath(
        'previous',
        kind == 'startup' ? '$path.antes-recuperar-' : '$path.antes-restaurar-',
      );
      final staged = checkedPath(
        'staged',
        kind == 'startup' ? '$path.recuperando-' : '$path.restaurando-',
      );
      if (kind != 'restore' && kind != 'startup') {
        throw const CapcException('El tipo de recuperación no es válido.');
      }
      if (kind == 'startup' &&
          !_samePath(original, p.join(previous, p.basename(path)))) {
        throw const CapcException(
          'La ubicación original de recuperación no es válida.',
        );
      }
      for (final candidate in [original, previous, staged]) {
        if (await FileSystemEntity.type(candidate, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const CapcException(
            'No se pueden recuperar datos mediante enlaces de archivos.',
          );
        }
      }
      if (journal['phase'] == 'complete' && await File(path).exists()) {
        await validateBackup(path);
        await marker.delete();
        return null;
      }
      String? preservedReplacement;
      if (await File(original).exists()) {
        if (await File(path).exists()) {
          preservedReplacement =
              '$path.restauracion-interrumpida-${_uuid.v4()}.sqlite';
          await File(path).rename(preservedReplacement);
          await _moveSidecars(path, preservedReplacement);
        }
        await File(original).rename(path);
        await _moveSidecars(original, path);
      } else if (!await File(path).exists()) {
        if (kind == 'restore' && await File(previous).exists()) {
          await validateBackup(previous);
          await _copySnapshot(previous, path);
        } else if (journal['originalPresent'] == false &&
            await File(staged).exists()) {
          await validateBackup(staged);
          await File(staged).rename(path);
        } else {
          throw const CapcException(
            'La restauración quedó interrumpida y falta el archivo anterior. No se ha creado una base vacía.',
          );
        }
      }
      // The prior file can itself be corrupt during startup recovery; preserve
      // it and let the normal startup recovery screen report that condition.
      if (kind == 'restore') await validateBackup(path);
      await marker.delete();
      return {
        'previous': previous,
        'interruptedReplacement': preservedReplacement,
        'kind': kind,
      };
    } on CapcException {
      rethrow;
    } catch (_) {
      throw const CapcException(
        'No se pudo recuperar una restauración interrumpida. Se conservaron los archivos; no se ha creado una base vacía.',
      );
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  static bool _samePath(String a, String b) {
    final first = p.normalize(p.absolute(a)),
        second = p.normalize(p.absolute(b));
    return appPlatform.caseInsensitivePaths
        ? first.toLowerCase() == second.toLowerCase()
        : first == second;
  }

  static Future<void> _copySnapshot(String source, String destination) async {
    final db = native.sqlite3.open(source, mode: native.OpenMode.readOnly);
    try {
      db.execute('VACUUM INTO ?', [destination]);
    } finally {
      db.close();
    }
  }

  static Future<void> _moveSidecars(String source, String destination) async {
    for (final suffix in ['-wal', '-shm']) {
      final file = File('$source$suffix');
      if (await file.exists()) await file.rename('$destination$suffix');
    }
  }

  static Future<void> _deleteDatabaseFiles(String path) async {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();
  static String _text(String value, String label, int maxLength) {
    final cleaned = value.trim();
    if (cleaned.isEmpty ||
        cleaned.length > maxLength ||
        cleaned.contains('\u0000')) {
      throw CapcException(
        '$label es obligatorio y admite hasta $maxLength caracteres.',
      );
    }
    return cleaned;
  }

  static String _optionalText(String value, String label, int maxLength) {
    final cleaned = value.trim();
    if (cleaned.length > maxLength || cleaned.contains('\u0000')) {
      throw CapcException('$label admite hasta $maxLength caracteres.');
    }
    return cleaned;
  }

  static String _id(String value) => _text(value, 'El identificador', 128);
  static void _money(int value, String label, {bool positive = false}) {
    if (value < (positive ? 1 : 0) || value > _maxMoney) {
      throw CapcException(
        '$label debe ser un entero ${positive ? 'mayor que cero' : 'no negativo'} en pesos colombianos y menor a un billón.',
      );
    }
  }

  static void _stock(int value) {
    if (value < 0 || value > _maxQuantity) {
      throw const CapcException(
        'Las existencias deben estar entre 0 y 1000000000.',
      );
    }
  }

  static void _quantity(int value) {
    if (value <= 0 || value > _maxQuantity) {
      throw const CapcException(
        'Las cantidades deben ser enteros mayores que cero y no superar 1000000000.',
      );
    }
  }

  static void _micros(int value) {
    if (value < 0 || value > _maxMicros) {
      throw const CapcException(
        'El valor del inventario supera el límite permitido.',
      );
    }
  }

  static int _multiply(int a, int b, {int scale = 1, int limit = _maxMicros}) {
    final result = BigInt.from(a) * BigInt.from(b) * BigInt.from(scale);
    if (result < BigInt.zero || result > BigInt.from(limit)) {
      throw const CapcException(
        'La cantidad o el costo supera el límite permitido.',
      );
    }
    return result.toInt();
  }

  static int _proportion(int value, int part, int whole) {
    if (whole <= 0 || part < 0 || part > whole || value < 0) {
      throw const CapcException(
        'No se puede calcular la valoración del movimiento.',
      );
    }
    return (BigInt.from(value) * BigInt.from(part) ~/ BigInt.from(whole))
        .toInt();
  }

  static int _sumMoney(int a, int b) {
    final result = a + b;
    _money(result, 'El total');
    return result;
  }

  static int _sumMicros(int a, int b) {
    final result = BigInt.from(a) + BigInt.from(b);
    if (result < BigInt.zero || result > BigInt.from(_maxMicros)) {
      throw const CapcException('El costo total supera el límite permitido.');
    }
    return result.toInt();
  }

  static String _method(String value, {bool allowCredit = false}) {
    final method = value.trim();
    if (!{
      'Efectivo',
      'Transferencia',
      'Tarjeta',
      if (allowCredit) 'Crédito',
    }.contains(method)) {
      throw const CapcException(
        'Selecciona efectivo, transferencia o tarjeta.',
      );
    }
    return method;
  }

  static int _received(int applied, int? received, String method) {
    final amount = received ?? applied;
    _money(amount, 'El dinero recibido');
    if (amount < applied ||
        (method != 'Efectivo' && amount != applied) ||
        (applied == 0 && amount != 0)) {
      throw const CapcException(
        'El recibido debe cubrir el importe aplicado. Solo el efectivo puede generar cambio.',
      );
    }
    return amount;
  }

  static String _search(String value) =>
      '%${value.trim().replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%';

  static Product _product(Map<String, Object?> row) => Product(
    id: row['id'] as String,
    code: row['code'] as String,
    name: row['name'] as String,
    unit: row['unit'] as String,
    isService: row['is_service'] == 1,
    purchasePrice: row['purchase_price'] as int,
    salePrice: row['sale_price'] as int,
    stock: row['stock'] as int,
    minimumStock: row['minimum_stock'] as int,
    category: row['category'] as String,
    inventoryValueMicros: row['inventory_value_micros'] as int,
    costKnown: row['cost_known'] == 1,
    costBasis: row['cost_basis'] as String,
  );

  Future<Product> _getProduct(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'products',
      where: 'id = ? AND business_id = ?',
      whereArgs: [id, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('Uno de los productos ya no existe.');
    }
    return _product(rows.single);
  }

  static Map<String, Object?> _lineRecord(SaleLine line) => {
    'product_id': line.productId,
    'code': line.code,
    'name': line.name,
    'unit': line.unit,
    'is_service': line.isService ? 1 : 0,
    'quantity': line.quantity,
    'unit_price': line.unitPrice,
    'unit_cost': line.unitCost,
    'cost_total_micros': line.costTotalMicros,
    'cost_known': line.costKnown,
    'cost_basis': line.costBasis,
  };

  Future<Sale> _getSale(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'sales',
      where: 'id = ? AND business_id = ?',
      whereArgs: [id, businessId],
    );
    if (rows.isEmpty) {
      throw const CapcException('La venta seleccionada no existe.');
    }
    return _saleFromRow(db, rows.single);
  }

  Future<Sale> _saleFromRow(
    DatabaseExecutor db,
    Map<String, Object?> row,
  ) async {
    final lines = await db.query(
      'sale_lines',
      where: 'sale_id = ?',
      whereArgs: [row['id']],
      orderBy: 'position',
    );
    return Sale(
      id: row['id'] as String,
      number: row['number'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      lines: [
        for (final line in lines)
          SaleLine(
            id: line['id'] as String,
            productId: line['product_id'] as String? ?? '',
            code: line['code'] as String,
            name: line['name'] as String,
            unit: line['unit'] as String,
            isService: line['is_service'] == 1,
            quantity: line['quantity'] as int,
            unitPrice: line['unit_price'] as int,
            unitCost: line['unit_cost'] as int,
            costTotalMicros: line['cost_total_micros'] as int,
            costKnown: line['cost_known'] == 1,
            costBasis: line['cost_basis'] as String,
            returnedQuantity: line['returned_quantity'] as int,
            recoveredCostMicros: line['recovered_cost_micros'] as int,
          ),
      ],
      customerId: row['customer_id'] as String?,
      customerName: row['customer_name'] as String,
      operatorName: row['operator_name'] as String,
      total: row['total'] as int,
      paid: row['paid'] as int,
      paymentMethod: row['payment_method'] as String,
      received: row['received'] as int,
      change: row['change_amount'] as int,
      dueAt: row['due_at'] == null
          ? null
          : DateTime.parse(row['due_at'] as String).toUtc(),
      returnedTotal: row['returned_total'] as int,
      refunded: row['refunded'] as int,
      cancelled: row['cancelled'] == 1,
      prepaid: row['prepaid'] as int,
      sourceQuoteId: row['source_quote_id'] as String?,
    );
  }

  Future<String?> _operation(
    DatabaseExecutor db,
    String id,
    String kind,
    String request,
  ) async {
    final rows = await db.query(
      'operations',
      where: 'id = ? AND business_id = ?',
      whereArgs: [id, businessId],
    );
    if (rows.isEmpty) return null;
    if (rows.single['kind'] != kind || rows.single['request'] != request) {
      throw const CapcException(
        'Ese identificador ya se utilizó para una operación diferente.',
      );
    }
    return rows.single['entity_id'] as String;
  }

  Future<void> _recordOperation(
    DatabaseExecutor db,
    String id,
    String kind,
    String request,
    String entityId,
    String now,
  ) async {
    await db.insert('operations', {
      'id': id,
      'kind': kind,
      'request': request,
      'entity_id': entityId,
      'created_at': now,
      'actor_id': _actor.id,
      'business_id': businessId,
      'device_id': deviceId,
    });
  }

  Future<RemoteLinkState> remoteLinkState() => _run(() async {
    const movementTables = [
      'sales',
      'payments',
      'stock_movements',
      'sale_returns',
      'cash_sessions',
      'cash_movements',
      'expenses',
      'purchases',
      'supplier_payments',
      'quotes',
      'work_orders',
      'work_advances',
    ];
    for (final table in movementTables) {
      final rows = await _db.rawQuery(
        'SELECT 1 FROM $table WHERE business_id=? LIMIT 1',
        [businessId],
      );
      if (rows.isNotEmpty) return RemoteLinkState.hasBusinessMovements;
    }
    for (final table in ['products', 'customers', 'suppliers']) {
      final rows = await _db.rawQuery(
        'SELECT 1 FROM $table WHERE business_id=? LIMIT 1',
        [businessId],
      );
      if (rows.isNotEmpty) return RemoteLinkState.noMovements;
    }
    return RemoteLinkState.newInstallation;
  });

  Future<void> adoptRemoteBusinessId(String remoteBusinessId) => _run(() async {
    final remote = _id(remoteBusinessId);
    if (remote == businessId) return;
    if (await remoteLinkState() == RemoteLinkState.hasBusinessMovements) {
      throw const CapcException(
        'La base local contiene movimientos. Haz un respaldo y usa una migración explícita; no se mezclarán negocios.',
      );
    }
    final previous = businessId;
    await _db.transaction((txn) async {
      final tables = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );
      for (final tableRow in tables) {
        final table = tableRow['name'] as String;
        final columns = await txn.rawQuery('PRAGMA table_info("$table")');
        if (columns.any((column) => column['name'] == 'business_id')) {
          await txn.rawUpdate(
            'UPDATE "$table" SET business_id=? WHERE business_id=?',
            [remote, previous],
          );
        }
      }
      for (final target in [
        ('outbox', 'payload'),
        ('inbox', 'payload'),
        ('operations', 'request'),
      ]) {
        final columns = await txn.rawQuery('PRAGMA table_info("${target.$1}")');
        if (columns.any((column) => column['name'] == target.$2)) {
          await txn.rawUpdate(
            'UPDATE "${target.$1}" SET "${target.$2}"=replace("${target.$2}",?,?)',
            [previous, remote],
          );
        }
      }
      await txn.update(
        'settings',
        {'value': remote},
        where: 'key = ?',
        whereArgs: ['business_id'],
      );
      await txn.insert('audit', {
        'id': _uuid.v4(),
        'action': 'remote.business_adopted',
        'entity_id': remote,
        'actor_id': _actor.id,
        'actor_name': _actor.name,
        'created_at': _now(),
        'details': jsonEncode({'previousBusinessId': previous}),
        'business_id': remote,
        'device_id': deviceId,
      });
    });
    _businessId = remote;
  });

  Future<void> _enqueue(
    DatabaseExecutor db,
    String kind,
    Map<String, Object?> payload,
    String now, {
    String? operationId,
  }) async {
    await db.insert('outbox', {
      'id': _uuid.v4(),
      'operation_id': operationId ?? _uuid.v4(),
      'kind': kind,
      'schema_version': 1,
      'payload': jsonEncode(payload),
      'created_at': now,
      'state': 'pending',
      'business_id': businessId,
      'device_id': deviceId,
    });
  }

  Future<void> _audit(
    DatabaseExecutor txn,
    String action,
    String entityId,
    Map<String, Object?> payload,
    String now,
  ) async {
    final actor = _actor;
    await txn.insert('audit', {
      'id': _uuid.v4(),
      'action': action,
      'entity_id': entityId,
      'actor_id': actor.id,
      'actor_name': actor.name,
      'created_at': now,
      'details': jsonEncode(payload),
      'business_id': businessId,
      'device_id': deviceId,
    });
  }

  static Future<void> _createSchema(
    DatabaseExecutor db, {
    String? business,
    String? device,
  }) async {
    final businessValue = business ?? _uuid.v4();
    final deviceValue = device ?? _uuid.v4();
    for (final statement in _schema) {
      await db.execute(statement);
    }
    await db.insert('settings', {
      'key': 'business_id',
      'value': businessValue,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('settings', {
      'key': 'device_id',
      'value': deviceValue,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('sync_state', {
      'business_id': businessValue,
      'cursor': 0,
      'status': 'local_only',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    for (final name in ['sale', 'return']) {
      await db.insert('counters', {
        'name': name,
        'value': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await createOperationsSchema(db);
    await db.execute('PRAGMA application_id = $_applicationId');
  }

  static Future<void> _migrateV1(DatabaseExecutor db) async {
    const tables = [
      'products',
      'customers',
      'sales',
      'sale_lines',
      'payments',
      'stock_movements',
      'operations',
      'outbox',
      'counters',
    ];
    for (final table in tables) {
      await db.execute('ALTER TABLE $table RENAME TO legacy_$table');
    }
    final business = _uuid.v4(), device = _uuid.v4(), now = _now();
    await _createSchema(db, business: business, device: device);
    const productColumns =
        'id,code,name,unit,is_service,purchase_price,sale_price,stock,minimum_stock,updated_at';
    await db.rawInsert(
      'INSERT INTO products ($productColumns,business_id,device_id,cost_basis) SELECT $productColumns,?,?,? FROM legacy_products',
      [business, device, 'legacy'],
    );
    for (final row in await db.query('products')) {
      final value =
          BigInt.from(row['stock'] as int) *
          BigInt.from(row['purchase_price'] as int) *
          BigInt.from(1000000);
      final valid = value <= BigInt.from(_maxMicros);
      await db.update(
        'products',
        {
          'inventory_value_micros': valid ? value.toInt() : 0,
          'cost_known': valid ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      await db.insert('audit', {
        'id': _uuid.v4(),
        'action': 'migration.opening_valuation',
        'entity_id': row['id'],
        'actor_id': 'migration-v1',
        'actor_name': 'Migración de datos v1',
        'created_at': now,
        'details': jsonEncode({
          'stock': row['stock'],
          'declaredUnitCost': row['purchase_price'],
          'valueMicros': valid ? value.toInt() : null,
          'basis': 'legacy',
        }),
        'business_id': business,
        'device_id': device,
      });
    }
    await db.rawInsert(
      'INSERT INTO customers (id,name,phone,updated_at,business_id,device_id) SELECT id,name,phone,updated_at,?,? FROM legacy_customers',
      [business, device],
    );
    const saleColumns =
        'id,number,sequence,created_at,customer_id,customer_name,operator_name,total,paid,payment_method';
    await db.rawInsert(
      'INSERT INTO sales ($saleColumns,business_id,device_id,received) SELECT $saleColumns,?,?,COALESCE((SELECT SUM(amount) FROM legacy_payments p WHERE p.sale_id=legacy_sales.id AND p.created_at=legacy_sales.created_at),0) FROM legacy_sales',
      [business, device],
    );
    const lineColumns =
        'id,sale_id,position,product_id,code,name,unit,is_service,quantity,unit_price,unit_cost';
    await db.rawInsert(
      'INSERT INTO sale_lines ($lineColumns,business_id,cost_basis) SELECT $lineColumns,?,? FROM legacy_sale_lines',
      [business, 'legacy'],
    );
    for (final row in await db.query('sale_lines')) {
      final value =
          BigInt.from(row['quantity'] as int) *
          BigInt.from(row['unit_cost'] as int) *
          BigInt.from(1000000);
      final valid = value <= BigInt.from(_maxMicros),
          cost = value <= BigInt.from(_maxMicros) ? value.toInt() : 0;
      await db.update(
        'sale_lines',
        {
          'cost_total_micros': cost,
          'cost_known': valid ? 1 : 0,
          'direct_cost_micros': row['is_service'] == 1 ? cost : 0,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      if (row['is_service'] == 0) {
        await db.insert('sale_consumptions', {
          'id': _uuid.v4(),
          'sale_line_id': row['id'],
          'product_id': row['product_id'],
          'quantity': row['quantity'],
          'cost_micros': cost,
          'cost_known': valid ? 1 : 0,
          'business_id': business,
        });
      }
    }
    await db.rawInsert(
      'INSERT INTO payments (id,sale_id,amount,created_at,method,received,actor_name,business_id,device_id) SELECT id,sale_id,amount,created_at,method,amount,?,?,? FROM legacy_payments',
      ['Responsable no registrado (v1)', business, device],
    );
    await db.rawInsert(
      'INSERT INTO stock_movements (id,product_id,delta,reason,created_at,reference_id,product_name,kind,actor_name,business_id,device_id) SELECT id,product_id,delta,reason,created_at,sale_id,(SELECT name FROM products WHERE products.id=product_id),?,?,?,? FROM legacy_stock_movements',
      ['Histórico v1', 'Responsable no registrado (v1)', business, device],
    );
    for (final row in await db.query('legacy_operations')) {
      var request = row['request'] as String;
      final old = jsonDecode(request) as Map<String, dynamic>;
      if (row['kind'] == 'sale.create') {
        final items = (old['items'] as List).cast<Map<String, dynamic>>();
        final canonical = [
          for (final item in items)
            {
              'key': jsonEncode([item['productId'], null, null, null, null]),
              'quantity': item['quantity'],
            },
        ]..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
        request = jsonEncode({
          'items': canonical,
          'custom': <Object>[],
          'customerId': old['customerId'],
          'paid': old['paid'],
          'received': old['paid'],
          'method': old['paymentMethod'],
          'dueAt': null,
          'prepaid': 0,
          'quote': null,
        });
      } else if (row['kind'] == 'payment.add') {
        request = jsonEncode({
          'saleId': old['saleId'],
          'amount': old['amount'],
          'method': old['method'],
          'received': old['amount'],
        });
      }
      await db.insert('operations', {
        ...row,
        'request': request,
        'business_id': business,
        'device_id': device,
      });
    }
    await db.rawInsert(
      'INSERT INTO outbox (id,operation_id,kind,schema_version,payload,created_at,state,business_id,device_id) SELECT id,operation_id,kind,schema_version,payload,created_at,state,?,? FROM legacy_outbox',
      [business, device],
    );
    await db.rawInsert(
      'INSERT OR REPLACE INTO counters (name,value) SELECT name,value FROM legacy_counters',
    );
    for (final table in tables.reversed) {
      await db.execute('DROP TABLE legacy_$table');
    }
    // Renamed legacy indexes kept their names until the old tables were dropped.
    for (final statement in _schema.where(
      (s) =>
          s.startsWith('CREATE INDEX') || s.startsWith('CREATE UNIQUE INDEX'),
    )) {
      await db.execute(statement);
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw const CapcException(
        'La migración no pudo validar las referencias. Se conservan los datos anteriores.',
      );
    }
  }

  static Future<void> _migrateV2ToV3(DatabaseExecutor db) async {
    final productColumns = await db.rawQuery('PRAGMA table_info(products)');
    if (!productColumns.any((row) => row['name'] == 'revision')) {
      await db.execute(
        'ALTER TABLE products ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0)',
      );
    }
    final customerColumns = await db.rawQuery('PRAGMA table_info(customers)');
    if (!customerColumns.any((row) => row['name'] == 'revision')) {
      await db.execute(
        'ALTER TABLE customers ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0)',
      );
    }
    final quoteColumns = await db.rawQuery('PRAGMA table_info(quotes)');
    if (!quoteColumns.any((row) => row['name'] == 'revision')) {
      await db.execute(
        'ALTER TABLE quotes ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0)',
      );
    }
    final outboxColumns = await db.rawQuery('PRAGMA table_info(outbox)');
    if (!outboxColumns.any((row) => row['name'] == 'retry_count')) {
      await db.execute('ALTER TABLE outbox RENAME TO outbox_v2');
      await db.execute(_outboxSchema);
      await db.execute('''INSERT INTO outbox
        (id,business_id,device_id,operation_id,kind,schema_version,payload,created_at,state)
        SELECT id,business_id,device_id,operation_id,kind,schema_version,payload,created_at,'pending'
        FROM outbox_v2''');
      await db.execute('DROP TABLE outbox_v2');
    }
    for (final statement in _syncSchema) {
      await db.execute(statement);
    }
    final settings = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['business_id'],
    );
    if (settings.isNotEmpty) {
      final count = await db.rawQuery(
        "SELECT COUNT(*) AS amount FROM outbox WHERE state != 'acknowledged'",
      );
      final pending = count.single['amount'] as int;
      await db.insert('sync_state', {
        'business_id': settings.single['value'],
        'cursor': 0,
        'status': pending == 0 ? 'local_only' : 'pending',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> _migrateV3ToV4(DatabaseExecutor db) async {
    final supplierColumns = await db.rawQuery('PRAGMA table_info(suppliers)');
    if (!supplierColumns.any((column) => column['name'] == 'revision')) {
      await db.execute(
        'ALTER TABLE suppliers ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0)',
      );
    }
    final workColumns = await db.rawQuery('PRAGMA table_info(work_orders)');
    if (!workColumns.any((column) => column['name'] == 'revision')) {
      await db.execute(
        'ALTER TABLE work_orders ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0)',
      );
    }
  }

  static const _outboxSchema = '''CREATE TABLE IF NOT EXISTS outbox (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      operation_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, schema_version INTEGER NOT NULL,
      payload TEXT NOT NULL, created_at TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sending','acknowledged','error')),
      retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count>=0), last_attempt_at TEXT,
      acknowledged_at TEXT, server_cursor INTEGER, last_error TEXT)''';

  static const _syncSchema = <String>[
    '''CREATE TABLE IF NOT EXISTS inbox (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      operation_id TEXT NOT NULL, server_cursor INTEGER NOT NULL, kind TEXT NOT NULL,
      schema_version INTEGER NOT NULL, payload TEXT NOT NULL, occurred_at TEXT NOT NULL,
      received_at TEXT NOT NULL, applied_at TEXT, state TEXT NOT NULL DEFAULT 'received'
      CHECK(state IN ('received','applied','conflict','error')), last_error TEXT,
      UNIQUE(business_id,operation_id), UNIQUE(business_id,server_cursor))''',
    '''CREATE TABLE IF NOT EXISTS sync_state (
      business_id TEXT PRIMARY KEY NOT NULL, cursor INTEGER NOT NULL DEFAULT 0 CHECK(cursor>=0),
      status TEXT NOT NULL DEFAULT 'local_only'
      CHECK(status IN ('local_only','pending','syncing','synced','error')),
      last_attempt_at TEXT, last_success_at TEXT, last_error TEXT)''',
    '''CREATE TABLE IF NOT EXISTS sync_conflicts (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, operation_id TEXT NOT NULL,
      kind TEXT NOT NULL, entity_id TEXT NOT NULL, details TEXT NOT NULL,
      created_at TEXT NOT NULL, resolved_at TEXT,
      UNIQUE(business_id,operation_id,kind,entity_id))''',
    'CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(business_id,state,created_at)',
    'CREATE INDEX IF NOT EXISTS inbox_pending ON inbox(business_id,state,server_cursor)',
    'CREATE INDEX IF NOT EXISTS sync_conflicts_open ON sync_conflicts(business_id,resolved_at,created_at)',
  ];

  static const _schema = <String>[
    'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
    '''CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      name TEXT NOT NULL, username TEXT NOT NULL COLLATE NOCASE, role TEXT NOT NULL CHECK(role IN ('owner','admin','cashier')),
      active INTEGER NOT NULL CHECK(active IN (0,1)), password_hash TEXT NOT NULL, password_salt TEXT NOT NULL,
      password_algorithm TEXT NOT NULL DEFAULT 'argon2id:m19456:t2:p1:v19',
      session_version INTEGER NOT NULL DEFAULT 0, failed_login INTEGER NOT NULL DEFAULT 0, locked_until TEXT,
      created_at TEXT NOT NULL, UNIQUE(business_id,username))''',
    '''CREATE TABLE IF NOT EXISTS products (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      code TEXT NOT NULL COLLATE NOCASE, name TEXT NOT NULL, unit TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT '', is_service INTEGER NOT NULL CHECK(is_service IN (0,1)),
      purchase_price INTEGER NOT NULL CHECK(purchase_price>=0), sale_price INTEGER NOT NULL CHECK(sale_price>=0),
      stock INTEGER NOT NULL CHECK(stock>=0), minimum_stock INTEGER NOT NULL CHECK(minimum_stock>=0),
      inventory_value_micros INTEGER NOT NULL DEFAULT 0 CHECK(inventory_value_micros>=0),
      cost_known INTEGER NOT NULL DEFAULT 1 CHECK(cost_known IN (0,1)), cost_basis TEXT NOT NULL DEFAULT 'weighted',
      updated_at TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),
      UNIQUE(business_id,code), CHECK(is_service=0 OR (stock=0 AND minimum_stock=0)))''',
    '''CREATE TABLE IF NOT EXISTS service_materials (
      service_id TEXT NOT NULL REFERENCES products(id), product_id TEXT NOT NULL REFERENCES products(id),
      quantity INTEGER NOT NULL CHECK(quantity>0), business_id TEXT NOT NULL, PRIMARY KEY(service_id,product_id))''',
    '''CREATE TABLE IF NOT EXISTS customers (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL,
      revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0))''',
    '''CREATE TABLE IF NOT EXISTS sales (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      number TEXT NOT NULL, sequence INTEGER NOT NULL, created_at TEXT NOT NULL,
      customer_id TEXT REFERENCES customers(id), customer_name TEXT NOT NULL,
      actor_id TEXT, operator_name TEXT NOT NULL, total INTEGER NOT NULL CHECK(total>=0),
      paid INTEGER NOT NULL CHECK(paid>=0), payment_method TEXT NOT NULL,
      received INTEGER NOT NULL DEFAULT 0 CHECK(received>=0), change_amount INTEGER NOT NULL DEFAULT 0 CHECK(change_amount>=0),
      due_at TEXT, returned_total INTEGER NOT NULL DEFAULT 0 CHECK(returned_total>=0 AND returned_total<=total),
      refunded INTEGER NOT NULL DEFAULT 0 CHECK(refunded>=0), cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN (0,1)),
      prepaid INTEGER NOT NULL DEFAULT 0 CHECK(prepaid>=0), source_quote_id TEXT UNIQUE,
      CHECK(paid<=total-returned_total), CHECK(paid=total-returned_total OR customer_id IS NOT NULL),
      UNIQUE(business_id,number), UNIQUE(business_id,sequence))''',
    '''CREATE TABLE IF NOT EXISTS sale_lines (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, sale_id TEXT NOT NULL REFERENCES sales(id), position INTEGER NOT NULL,
      product_id TEXT REFERENCES products(id), code TEXT NOT NULL, name TEXT NOT NULL, unit TEXT NOT NULL,
      is_service INTEGER NOT NULL CHECK(is_service IN (0,1)), quantity INTEGER NOT NULL CHECK(quantity>0),
      unit_price INTEGER NOT NULL CHECK(unit_price>=0), unit_cost INTEGER NOT NULL CHECK(unit_cost>=0),
      cost_total_micros INTEGER NOT NULL DEFAULT 0 CHECK(cost_total_micros>=0),
      direct_cost_micros INTEGER NOT NULL DEFAULT 0 CHECK(direct_cost_micros>=0),
      cost_known INTEGER NOT NULL DEFAULT 1 CHECK(cost_known IN (0,1)), cost_basis TEXT NOT NULL DEFAULT 'weighted',
      returned_quantity INTEGER NOT NULL DEFAULT 0 CHECK(returned_quantity>=0 AND returned_quantity<=quantity),
      recovered_cost_micros INTEGER NOT NULL DEFAULT 0 CHECK(recovered_cost_micros>=0 AND recovered_cost_micros<=cost_total_micros),
      UNIQUE(sale_id,position))''',
    '''CREATE TABLE IF NOT EXISTS sale_consumptions (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, sale_line_id TEXT NOT NULL REFERENCES sale_lines(id),
      product_id TEXT NOT NULL REFERENCES products(id), quantity INTEGER NOT NULL CHECK(quantity>0),
      cost_micros INTEGER NOT NULL CHECK(cost_micros>=0), cost_known INTEGER NOT NULL CHECK(cost_known IN (0,1)),
      restored_quantity INTEGER NOT NULL DEFAULT 0 CHECK(restored_quantity>=0 AND restored_quantity<=quantity),
      restored_cost_micros INTEGER NOT NULL DEFAULT 0 CHECK(restored_cost_micros>=0 AND restored_cost_micros<=cost_micros))''',
    '''CREATE TABLE IF NOT EXISTS payments (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL, sale_id TEXT NOT NULL REFERENCES sales(id),
      amount INTEGER NOT NULL CHECK(amount<>0), created_at TEXT NOT NULL, method TEXT NOT NULL,
      received INTEGER NOT NULL DEFAULT 0 CHECK(received>=0), change_amount INTEGER NOT NULL DEFAULT 0 CHECK(change_amount>=0),
      actor_id TEXT, actor_name TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'Cobro')''',
    '''CREATE TABLE IF NOT EXISTS stock_movements (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      product_id TEXT NOT NULL REFERENCES products(id), product_name TEXT NOT NULL,
      delta INTEGER NOT NULL CHECK(delta<>0), cost_micros INTEGER NOT NULL DEFAULT 0 CHECK(cost_micros>=0),
      reason TEXT NOT NULL, kind TEXT NOT NULL, created_at TEXT NOT NULL, reference_id TEXT,
      actor_id TEXT, actor_name TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS sale_returns (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      sale_id TEXT NOT NULL REFERENCES sales(id), number TEXT NOT NULL, created_at TEXT NOT NULL,
      amount INTEGER NOT NULL CHECK(amount>=0), refund INTEGER NOT NULL CHECK(refund>=0), method TEXT NOT NULL,
      actor_id TEXT NOT NULL, actor_name TEXT NOT NULL, reason TEXT NOT NULL,
      cost_reversed_micros INTEGER NOT NULL CHECK(cost_reversed_micros>=0), cancelled INTEGER NOT NULL CHECK(cancelled IN (0,1)),
      UNIQUE(business_id,number))''',
    '''CREATE TABLE IF NOT EXISTS sale_return_lines (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, return_id TEXT NOT NULL REFERENCES sale_returns(id),
      sale_line_id TEXT NOT NULL REFERENCES sale_lines(id), quantity INTEGER NOT NULL CHECK(quantity>0),
      amount INTEGER NOT NULL CHECK(amount>=0), restock INTEGER NOT NULL CHECK(restock IN (0,1)),
      cost_reversed_micros INTEGER NOT NULL CHECK(cost_reversed_micros>=0))''',
    '''CREATE TABLE IF NOT EXISTS cash_sessions (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL, opened_at TEXT NOT NULL,
      closed_at TEXT, opening_amount INTEGER NOT NULL CHECK(opening_amount>=0), expected_amount INTEGER,
      counted_amount INTEGER, difference INTEGER, opened_by TEXT NOT NULL, opened_name TEXT NOT NULL,
      closed_by TEXT, closed_name TEXT, note TEXT NOT NULL DEFAULT '')''',
    '''CREATE TABLE IF NOT EXISTS cash_movements (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      session_id TEXT NOT NULL REFERENCES cash_sessions(id), amount INTEGER NOT NULL CHECK(amount<>0),
      method TEXT NOT NULL, kind TEXT NOT NULL, reference_id TEXT, reason TEXT NOT NULL,
      created_at TEXT NOT NULL, actor_id TEXT NOT NULL, actor_name TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS expenses (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      amount INTEGER NOT NULL CHECK(amount>0), method TEXT NOT NULL, reason TEXT NOT NULL,
      created_at TEXT NOT NULL, actor_id TEXT NOT NULL, actor_name TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS operations (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      kind TEXT NOT NULL, request TEXT NOT NULL, entity_id TEXT NOT NULL, created_at TEXT NOT NULL, actor_id TEXT)''',
    _outboxSchema,
    '''CREATE TABLE IF NOT EXISTS audit (
      id TEXT PRIMARY KEY NOT NULL, business_id TEXT NOT NULL, device_id TEXT NOT NULL,
      action TEXT NOT NULL, entity_id TEXT NOT NULL, actor_id TEXT NOT NULL, actor_name TEXT NOT NULL,
      created_at TEXT NOT NULL, details TEXT NOT NULL)''',
    'CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS sales_created_at ON sales(business_id,created_at)',
    'CREATE INDEX IF NOT EXISTS sales_customer ON sales(business_id,customer_id)',
    'CREATE INDEX IF NOT EXISTS sale_lines_sale ON sale_lines(sale_id)',
    'CREATE INDEX IF NOT EXISTS payments_sale ON payments(sale_id)',
    'CREATE INDEX IF NOT EXISTS payments_created_at ON payments(business_id,created_at)',
    'CREATE INDEX IF NOT EXISTS stock_movements_product ON stock_movements(product_id,created_at)',
    'CREATE INDEX IF NOT EXISTS returns_created ON sale_returns(business_id,created_at)',
    'CREATE INDEX IF NOT EXISTS cash_movements_session ON cash_movements(session_id,method)',
    'CREATE UNIQUE INDEX IF NOT EXISTS cash_one_open ON cash_sessions(business_id) WHERE closed_at IS NULL',
    ..._syncSchema,
  ];
}
