import 'package:capc_multiservicio/data/repository.dart';
import 'package:capc_multiservicio/ui/capc_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _databaseFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'una base vacía reemplaza el acceso anterior y permite crear propietario',
    (tester) async {
      late CapcRepository previousRepository;
      late CapcRepository emptyRepository;
      await tester.runAsync(() async {
        previousRepository = await CapcRepository.open(':memory:');
        await previousRepository.setupOwner(
          name: 'Propietaria anterior',
          username: 'anterior',
          password: 'ClaveAnterior2026!',
        );
        emptyRepository = await CapcRepository.open(':memory:');
      });
      addTearDown(previousRepository.close);
      addTearDown(emptyRepository.close);

      await tester.pumpWidget(CapcApp(repository: previousRepository));
      await _databaseFrames(tester);
      expect(find.text('Tu negocio, al día'), findsOneWidget);

      // El reinicio local y el borrado total reemplazan el repositorio sin
      // terminar el proceso de Windows. El acceso debe olvidar la base vieja.
      await tester.pumpWidget(CapcApp(repository: emptyRepository));
      await _databaseFrames(tester);

      expect(find.text('Crea el primer propietario'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Crear propietario'),
        findsOneWidget,
      );
      expect(find.text('Ingresar a tu negocio'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
