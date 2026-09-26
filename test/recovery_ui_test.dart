import 'dart:io';
import 'dart:ui' as ui;

import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/ui/capc_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const password = 'MiClaveLocal2026!';
const replacement = 'MiClaveNueva2026!';

Future<void> databaseUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
    if (ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('La operación no terminó dentro del tiempo esperado.');
}

Future<void> click(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> fill(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, value);
}

Future<void> mountGate(
  WidgetTester tester,
  CapcRepository repository, {
  Size size = const Size(1000, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('recovery-qa-root'),
      child: CapcApp(repository: repository),
    ),
  );
  await databaseUntil(tester, () {
    final buttons = tester.widgetList<FilledButton>(find.byType(FilledButton));
    return buttons.any((button) => button.onPressed != null);
  });
}

Future<void> captureRecovery(WidgetTester tester, String name) async {
  final output = Platform.environment['CAPC_UI_QA_DIR'];
  if (output == null) return;
  await tester.runAsync(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('recovery-qa-root')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File(
      p.join(output, '$name.png'),
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory directory;
  late CapcRepository repository;
  late String databasePath;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capc_recovery_ui_');
    databasePath = p.join(directory.path, 'test.sqlite');
    repository = await CapcRepository.open(databasePath);
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<LocalUser> owner() => repository.setupOwner(
    name: 'Propietaria de prueba',
    username: 'propietaria',
    password: password,
  );

  testWidgets(
    'Recuperación rechaza códigos incorrectos y usados y vuelve al ingreso',
    (tester) async {
      late String code;
      await tester.runAsync(() async {
        await owner();
        code = await repository.generateRecoveryCode(currentPassword: password);
        repository.logout();
      });
      await mountGate(tester, repository);
      await click(tester, find.text('Olvidé mi contraseña'));
      await tester.pumpAndSettle();
      await captureRecovery(tester, 'recuperacion-ingreso');
      await fill(tester, 'Usuario', 'propietaria');
      await fill(tester, 'Código de recuperación', 'incorrecto');
      await fill(tester, 'Nueva contraseña', replacement);
      await fill(tester, 'Repetir contraseña', replacement);
      await click(tester, find.text('Guardar nueva contraseña'));
      await databaseUntil(
        tester,
        () =>
            find.textContaining('No se pudo restablecer').evaluate().isNotEmpty,
      );
      expect(repository.isAuthenticated, isFalse);
      await fill(tester, 'Código de recuperación', code);
      await click(tester, find.text('Guardar nueva contraseña'));
      await databaseUntil(
        tester,
        () => find
            .textContaining('Contraseña restablecida.')
            .evaluate()
            .isNotEmpty,
      );
      expect(repository.isAuthenticated, isFalse);
      expect(find.text('Ingresar a tu negocio'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('access-password')))
            .controller!
            .text,
        isEmpty,
      );

      await click(tester, find.text('Olvidé mi contraseña'));
      await tester.pumpAndSettle();
      await fill(tester, 'Usuario', 'propietaria');
      await fill(tester, 'Código de recuperación', code);
      await fill(tester, 'Nueva contraseña', password);
      await fill(tester, 'Repetir contraseña', password);
      await click(tester, find.text('Guardar nueva contraseña'));
      await databaseUntil(
        tester,
        () =>
            find.textContaining('No se pudo restablecer').evaluate().isNotEmpty,
      );
      expect(repository.isAuthenticated, isFalse);
      await click(tester, find.text('Volver al ingreso'));
      await tester.pumpAndSettle();
      await fill(tester, 'Usuario', 'propietaria');
      await fill(tester, 'Contraseña', replacement);
      await click(tester, find.text('Ingresar'));
      await databaseUntil(
        tester,
        () => find.text('Tu negocio, al día').evaluate().isNotEmpty,
      );
      expect(repository.currentUser!.username, 'propietaria');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Alta muestra código una vez y permite copiarlo antes de continuar',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mountGate(tester, repository);
      await captureRecovery(tester, 'recuperacion-primer-propietario');
      await fill(tester, 'Nombre del propietario', 'Nueva propietaria');
      await fill(tester, 'Usuario', 'nueva');
      await fill(tester, 'Contraseña', password);
      await fill(tester, 'Repetir contraseña', password);
      await click(tester, find.text('Crear propietario'));
      await databaseUntil(
        tester,
        () => find.byKey(const Key('recovery-code')).evaluate().isNotEmpty,
      );
      expect(find.text('Tu negocio, al día'), findsNothing);
      await captureRecovery(tester, 'recuperacion-codigo-de-prueba');
      final code = tester
          .widget<SelectableText>(find.byKey(const Key('recovery-code')))
          .data!;
      expect(code.replaceAll(' ', ''), matches(RegExp(r'^[A-F0-9]{64}$')));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Continuar'),
            )
            .onPressed,
        isNull,
      );
      await click(tester, find.text('Copiar código'));
      await tester.pumpAndSettle();
      expect(copied!.replaceAll('-', ' '), code);
      await click(tester, find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await click(tester, find.widgetWithText(FilledButton, 'Continuar'));
      await databaseUntil(
        tester,
        () => find.text('Tu negocio, al día').evaluate().isNotEmpty,
      );
      expect(find.text('Tu negocio, al día'), findsOneWidget);
      expect(find.byKey(const Key('recovery-code')), findsNothing);
      await tester.runAsync(
        () async => expect(await repository.recoveryCodeConfigured(), isTrue),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Reconfiguración crea el nuevo acceso y conserva clientes', (
    tester,
  ) async {
    late String ownerId;
    await tester.runAsync(() async {
      ownerId = (await owner()).id;
      await repository.saveCustomer(
        const Customer(id: 'cliente', name: 'Cliente conservado'),
      );
      repository.logout();
      final db = sqlite3.open(databasePath);
      try {
        db.execute('INSERT INTO settings(key,value) VALUES(?,?)', [
          'owner_reconfiguration_user_id',
          ownerId,
        ]);
      } finally {
        db.close();
      }
    });
    await mountGate(tester, repository);
    expect(find.text('Configura tu nuevo propietario'), findsOneWidget);
    await captureRecovery(tester, 'recuperacion-nuevo-propietario');
    expect(find.textContaining('Se conservarán tus ventas'), findsOneWidget);
    expect(find.text('Olvidé mi contraseña'), findsNothing);
    await fill(tester, 'Nombre del propietario', 'Nuevo propietario');
    await fill(tester, 'Usuario', 'nuevoacceso');
    await fill(tester, 'Contraseña', replacement);
    await fill(tester, 'Repetir contraseña', replacement);
    await click(tester, find.text('Crear propietario'));
    await databaseUntil(
      tester,
      () => find.byKey(const Key('recovery-code')).evaluate().isNotEmpty,
    );
    expect(repository.currentUser!.id, ownerId);
    expect(repository.currentUser!.username, 'nuevoacceso');
    await tester.runAsync(() async {
      expect(await repository.pendingOwnerReconfiguration(), isFalse);
      expect(
        (await repository.listCustomers()).single.name,
        'Cliente conservado',
      );
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Cajero genera recuperación solo con contraseña actual', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await owner();
      await repository.saveUser(
        name: 'Caja de prueba',
        username: 'caja',
        role: UserRole.cashier,
        password: password,
      );
      repository.logout();
      await repository.login('caja', password);
    });
    await tester.pumpWidget(CapcApp(repository: repository));
    await databaseUntil(
      tester,
      () =>
          find.byTooltip('Seguridad de mi cuenta').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await click(tester, find.byTooltip('Seguridad de mi cuenta'));
    await databaseUntil(
      tester,
      () => find.text('Generar código de recuperación').evaluate().isNotEmpty,
    );
    await fill(tester, 'Contraseña actual', 'incorrecta');
    await click(tester, find.text('Generar código de recuperación'));
    await databaseUntil(
      tester,
      () => find
          .text('La contraseña actual no es correcta.')
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('recovery-code')), findsNothing);
    await fill(tester, 'Contraseña actual', password);
    await click(tester, find.text('Generar código de recuperación'));
    await databaseUntil(
      tester,
      () => find.byKey(const Key('recovery-code')).evaluate().isNotEmpty,
    );
    expect(find.text('Usuario: caja'), findsOneWidget);
    await click(tester, find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await click(tester, find.widgetWithText(FilledButton, 'Continuar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code')), findsNothing);
    expect(find.byKey(const Key('page-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Seguridad vuelve al ingreso cuando termina la sesión', (
    tester,
  ) async {
    await tester.runAsync(owner);
    await tester.pumpWidget(CapcApp(repository: repository));
    await databaseUntil(
      tester,
      () =>
          find.byTooltip('Seguridad de mi cuenta').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await click(tester, find.byTooltip('Seguridad de mi cuenta'));
    await databaseUntil(
      tester,
      () => find.text('Generar código de recuperación').evaluate().isNotEmpty,
    );
    repository.logout();
    await fill(tester, 'Contraseña actual', password);
    await click(tester, find.text('Generar código de recuperación'));
    await databaseUntil(
      tester,
      () => find.textContaining('La sesión terminó.').evaluate().isNotEmpty,
    );
    await click(tester, find.text('Volver al ingreso'));
    await databaseUntil(
      tester,
      () => find.text('Ingresar a tu negocio').evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('page-title')), findsNothing);
    expect(repository.isAuthenticated, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Acceso y código caben a 375 px con texto al 200%', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mountGate(tester, repository, size: const Size(375, 812));
    await fill(tester, 'Nombre del propietario', 'Propietaria');
    await fill(tester, 'Usuario', 'propietaria');
    await fill(tester, 'Contraseña', password);
    await fill(tester, 'Repetir contraseña', password);
    await click(tester, find.text('Crear propietario'));
    await databaseUntil(
      tester,
      () => find.byKey(const Key('recovery-code')).evaluate().isNotEmpty,
    );
    await click(tester, find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    final next = find.widgetWithText(FilledButton, 'Continuar');
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    expect(next.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await captureRecovery(tester, 'recuperacion-codigo-375-texto200');
    await tester.pumpWidget(const SizedBox.shrink());
    repository.logout();
    await mountGate(tester, repository, size: const Size(375, 812));
    await click(tester, find.text('Olvidé mi contraseña'));
    await tester.pumpAndSettle();
    await fill(tester, 'Usuario', 'propietaria');
    await fill(tester, 'Código de recuperación', 'invalido');
    await fill(tester, 'Nueva contraseña', replacement);
    await fill(tester, 'Repetir contraseña', replacement);
    await click(tester, find.text('Guardar nueva contraseña'));
    await databaseUntil(
      tester,
      () => find.textContaining('No se pudo restablecer').evaluate().isNotEmpty,
    );
    await click(tester, find.text('Volver al ingreso'));
    await tester.pumpAndSettle();
    expect(find.text('Ingresar a tu negocio'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
