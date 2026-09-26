part of 'repository.dart';

const _ownerReconfigurationKey = 'owner_reconfiguration_user_id';
const _recoveryFailure = CapcException(
  'No se pudo restablecer la contraseña. Verifica el usuario y el código. '
  'Si ya lo intentaste varias veces, espera cinco minutos.',
);

String _recoveryHashKey(String userId) => 'password_recovery_hash:$userId';
String _recoveryAttemptsKey(String userId) =>
    'password_recovery_attempts:$userId';

Future<String?> _recoverySetting(DatabaseExecutor db, String key) async {
  final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
  return rows.isEmpty ? null : rows.single['value'] as String;
}

Future<void> _clearRecovery(DatabaseExecutor db, String userId) => db
    .delete(
      'settings',
      where: 'key IN (?, ?)',
      whereArgs: [_recoveryHashKey(userId), _recoveryAttemptsKey(userId)],
    )
    .then((_) {});

Future<void> _requireOwnerConfigurationComplete(DatabaseExecutor db) async {
  if (await _recoverySetting(db, _ownerReconfigurationKey) != null) {
    throw const CapcException(
      'Completa la configuración del nuevo acceso propietario para continuar.',
    );
  }
}

Future<String?> _hashRecoveryCode(String input) async {
  if (input.length > 160) return null;
  final normalized = input.replaceAll(RegExp(r'[-\s]'), '').toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) return null;
  final hash = await Sha256().hash(utf8.encode(normalized));
  return base64Encode(hash.bytes);
}

bool _sameRecoveryHash(String actual, String expected) {
  var difference = actual.length ^ expected.length;
  for (var i = 0; i < actual.length; i++) {
    difference |=
        actual.codeUnitAt(i) ^
        (i < expected.length ? expected.codeUnitAt(i) : 0);
  }
  return difference == 0;
}

/// Local recovery needs a previously saved, single-use secret. Only its hash is
/// persisted; it is never sent to the outbox or included in audit details.
extension CapcRecovery on CapcRepository {
  Future<bool> recoveryCodeConfigured() => _run(() async {
    final actor = await _require(Permission.read);
    return await _recoverySetting(_db, _recoveryHashKey(actor.id)) != null;
  });

  Future<String> generateRecoveryCode({required String currentPassword}) =>
      _run(() async {
        final actor = await _require(Permission.read);
        final row = (await _db.query(
          'users',
          where: 'id = ? AND business_id = ?',
          whereArgs: [actor.id, businessId],
        )).single;
        if (!await CapcRepository._verifyPassword(currentPassword, row)) {
          throw const CapcException('La contraseña actual no es correcta.');
        }
        final random = Random.secure();
        final normalized = List.generate(
          32,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final code = List.generate(
          8,
          (i) => normalized.substring(i * 8, i * 8 + 8),
        ).join('-').toUpperCase();
        final hash = (await _hashRecoveryCode(code))!;
        await _db.transaction((txn) async {
          final freshActor = await _require(Permission.read, txn);
          final fresh = (await txn.query(
            'users',
            where: 'id = ? AND business_id = ?',
            whereArgs: [actor.id, businessId],
          )).single;
          if (freshActor.id != actor.id ||
              fresh['password_hash'] != row['password_hash'] ||
              fresh['password_salt'] != row['password_salt']) {
            throw const CapcException(
              'La sesión cambió. Inicia sesión para generar un código nuevo.',
            );
          }
          await _clearRecovery(txn, actor.id);
          await txn.insert('settings', {
            'key': _recoveryHashKey(actor.id),
            'value': hash,
          });
          await _audit(
            txn,
            'user.recovery_code_generated',
            actor.id,
            {},
            CapcRepository._now(),
          );
        });
        return code;
      });

  Future<void> resetPasswordWithRecoveryCode({
    required String username,
    required String recoveryCode,
    required String newPassword,
  }) => _run(() async {
    CapcRepository._validatePassword(newPassword);
    final loginName = username.trim().toLowerCase();
    final hash = await _hashRecoveryCode(recoveryCode);
    if (loginName.isEmpty || loginName.length > 80 || hash == null) {
      throw _recoveryFailure;
    }
    // Consuming the code and changing the credentials share one transaction.
    // Concurrent requests therefore cannot reuse or race a rotated code.
    final recoveredId = await _db.transaction<String?>((txn) async {
      await _requireOwnerConfigurationComplete(txn);
      final users = await txn.query(
        'users',
        where: 'username = ? COLLATE NOCASE AND business_id = ? AND active = 1',
        whereArgs: [loginName, businessId],
      );
      if (users.isEmpty) return null;
      final user = users.single;
      final userId = user['id'] as String;
      final encodedAttempts = await _recoverySetting(
        txn,
        _recoveryAttemptsKey(userId),
      );
      final attemptsState = encodedAttempts == null
          ? <String, dynamic>{}
          : jsonDecode(encodedAttempts) as Map<String, dynamic>;
      final lockedUntil = DateTime.tryParse(
        attemptsState['lockedUntil'] as String? ?? '',
      );
      final now = DateTime.now().toUtc();
      if (lockedUntil != null && lockedUntil.isAfter(now)) return null;
      final storedHash = await _recoverySetting(txn, _recoveryHashKey(userId));
      if (storedHash == null || !_sameRecoveryHash(hash, storedHash)) {
        final failures = lockedUntil != null
            ? 1
            : (attemptsState['failures'] as int? ?? 0) + 1;
        await txn.insert('settings', {
          'key': _recoveryAttemptsKey(userId),
          'value': jsonEncode({
            'failures': failures,
            if (failures >= 5)
              'lockedUntil': now
                  .add(const Duration(minutes: 5))
                  .toIso8601String(),
          }),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return null;
      }
      final credentials = await CapcRepository._hashPassword(newPassword);
      await txn.update(
        'users',
        {
          ...credentials,
          'session_version': (user['session_version'] as int) + 1,
          'failed_login': 0,
          'locked_until': null,
        },
        where: 'id = ? AND business_id = ?',
        whereArgs: [userId, businessId],
      );
      await _clearRecovery(txn, userId);
      await _recoveryAudit(
        txn,
        'user.password_recovered',
        userId,
        user['name'] as String,
      );
      return userId;
    });
    if (recoveredId == null) throw _recoveryFailure;
    if (_session?.id == recoveredId) logout();
  });

  Future<bool> pendingOwnerReconfiguration() => _run(
    () async => await _recoverySetting(_db, _ownerReconfigurationKey) != null,
  );

  /// This marker is prepared by authorized offline maintenance after a backup.
  /// There is deliberately no app API that can enable owner reconfiguration.
  Future<LocalUser> completeOwnerReconfiguration({
    required String name,
    required String username,
    required String password,
  }) => _run(() async {
    final epoch = _sessionEpoch;
    final displayName = CapcRepository._text(name, 'El nombre', 160);
    final loginName = CapcRepository._text(
      username,
      'El usuario',
      80,
    ).toLowerCase();
    final credentials = await CapcRepository._hashPassword(password);
    final configured = await _db.transaction<Map<String, Object?>>((txn) async {
      if (epoch != _sessionEpoch) {
        throw const CapcException(
          'La sesión cambió. Vuelve a configurar el acceso.',
        );
      }
      final ownerId = await _recoverySetting(txn, _ownerReconfigurationKey);
      final owners = ownerId == null
          ? <Map<String, Object?>>[]
          : await txn.query(
              'users',
              where:
                  "id = ? AND business_id = ? AND role = 'owner' AND active = 1",
              whereArgs: [ownerId, businessId],
            );
      if (owners.isEmpty) {
        throw const CapcException(
          'No hay un cambio de acceso propietario autorizado pendiente.',
        );
      }
      final owner = owners.single;
      final updated = <String, Object?>{
        'name': displayName,
        'username': loginName,
        ...credentials,
        'session_version': (owner['session_version'] as int) + 1,
        'failed_login': 0,
        'locked_until': null,
      };
      await txn.update('users', updated, where: 'id = ?', whereArgs: [ownerId]);
      await _clearRecovery(txn, ownerId!);
      await txn.delete(
        'settings',
        where: 'key = ?',
        whereArgs: [_ownerReconfigurationKey],
      );
      await _recoveryAudit(
        txn,
        'user.owner_reconfigured',
        ownerId,
        displayName,
      );
      if (epoch != _sessionEpoch) {
        throw const CapcException(
          'La sesión cambió. Vuelve a configurar el acceso.',
        );
      }
      return {...owner, ...updated};
    });
    if (epoch != _sessionEpoch) {
      throw const CapcException(
        'El nuevo acceso quedó configurado. Inicia sesión con tu nuevo usuario y contraseña.',
      );
    }
    _session = CapcRepository._user(configured);
    _sessionEpoch++;
    _sessionVersion = configured['session_version'] as int;
    return _session!;
  });

  Future<void> _recoveryAudit(
    DatabaseExecutor txn,
    String action,
    String userId,
    String name,
  ) => txn
      .insert('audit', {
        'id': CapcRepository._uuid.v4(),
        'action': action,
        'entity_id': userId,
        'actor_id': userId,
        'actor_name': name,
        'created_at': CapcRepository._now(),
        'details': '{}',
        'business_id': businessId,
        'device_id': deviceId,
      })
      .then((_) {});
}
