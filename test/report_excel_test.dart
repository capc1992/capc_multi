import 'package:capc_multiservicio/ui/spreadsheet_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Reportes Excel conservan identificadores y tipan fechas e importes',
    () {
      final rows = reportExcelRows('Ventas y utilidad', [
        [
          '000012',
          '25/09/2026 14:05',
          'Venta',
          r'$ 1.234.000',
          'Costo declarado / incompleto',
        ],
        ['DEV-1', '26/09/2026 09:00', 'Devolución', r'-$ 2.000', r'-$ 1.000'],
      ]);
      expect(rows.first, [
        '000012',
        DateTime(2026, 9, 25, 14, 5),
        'Venta',
        1234000,
        'Costo declarado / incompleto',
      ]);
      expect(rows.last.sublist(3), [-2000, -1000]);
    },
  );

  test(
    'Cantidades negativas, saldos pendientes y totales grandes se conservan',
    () {
      expect(
        reportExcelRows('Productos más vendidos', [
          ['001 Producto', '-2', r'-$ 10.000'],
        ]).single,
        ['001 Producto', -2, -10000],
      );
      expect(
        reportExcelRows('Caja', [
          ['25/09/2026 08:00', 'Abierta', r'$ 1.000', 'Pendiente', 'Pendiente'],
        ]).single,
        [DateTime(2026, 9, 25, 8), 'Abierta', 1000, 'Pendiente', 'Pendiente'],
      );
      expect(
        reportExcelRows('Cartera', [
          [r'$ 10.000', '000012', 'Sin fecha', r'$ 1.000.000.000.000.001'],
        ]).single,
        [r'$ 10.000', '000012', 'Sin fecha', r'$ 1.000.000.000.000.001'],
      );
    },
  );
}
