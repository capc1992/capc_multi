import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/models.dart';

/// A period is a pair of inclusive civil dates in Bogotá, independent of the
/// Windows time zone. Balances are current balances, not historical balances.
class CapcReportData {
  CapcReportData._(this.from, this.to, this.sales, this.payments);

  factory CapcReportData.forPeriod(
    List<Sale> sales,
    List<Payment> payments,
    DateTime from,
    DateTime to,
  ) {
    final first = DateTime.utc(from.year, from.month, from.day);
    final last = DateTime.utc(to.year, to.month, to.day);
    if (first.isAfter(last)) {
      throw ArgumentError(
        'La fecha inicial debe ser anterior a la fecha final.',
      );
    }
    bool inPeriod(DateTime instant) {
      final bogota = instant.toUtc().subtract(const Duration(hours: 5));
      final day = DateTime.utc(bogota.year, bogota.month, bogota.day);
      return !day.isBefore(first) && !day.isAfter(last);
    }

    final selectedSales = sales.where((s) => inPeriod(s.createdAt)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final selectedPayments =
        payments.where((p) => inPeriod(p.createdAt)).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return CapcReportData._(
      first,
      last,
      List.unmodifiable(selectedSales),
      List.unmodifiable(selectedPayments),
    );
  }

  final DateTime from;
  final DateTime to;
  final List<Sale> sales;
  final List<Payment> payments;

  int get totalSales => sales.fold(0, (sum, sale) => sum + sale.total);
  int get totalCollected =>
      payments.fold(0, (sum, payment) => sum + payment.amount);
  int get outstandingBalance =>
      sales.fold(0, (sum, sale) => sum + sale.balance);
}

/// Local PDF generation: bundled fonts, no network requests or printer access
/// in the build methods. Printing always uses the platform's explicit dialog.
class CapcDocuments {
  static const _business = 'CAPC MULTISERVICIO';
  static const _notice = 'Comprobante interno · Sin validez fiscal';
  static const _ink = PdfColor.fromInt(0xff173a36);
  static const _muted = PdfColor.fromInt(0xff52665f);
  static const _pale = PdfColor.fromInt(0xffedf4f0);
  static const _rule = PdfColor.fromInt(0xffdbe5df);
  static const _ticketFormat = PdfPageFormat(
    80 * PdfPageFormat.mm,
    250 * PdfPageFormat.mm,
  );

  static Future<void> printSale(Sale sale, {bool ticket = false}) async {
    final bytes = await buildSale(sale, ticket: ticket);
    await Printing.layoutPdf(
      name: 'CAPC ${sale.number}',
      format: ticket ? _ticketFormat : PdfPageFormat.letter,
      dynamicLayout: false,
      windowsModernDialog: true,
      onLayout: (_) async => bytes,
    );
  }

  static Future<bool> saveSale(Sale sale, {bool ticket = false}) async {
    final bytes = await buildSale(sale, ticket: ticket);
    return _save(
      bytes,
      'CAPC-${_filePart(sale.number)}${ticket ? '-tirilla' : ''}.pdf',
    );
  }

  static Future<void> printReport(
    List<Sale> sales,
    List<Payment> payments,
    DateTime from,
    DateTime to,
  ) async {
    final bytes = await buildReport(sales, payments, from, to);
    await Printing.layoutPdf(
      name: 'CAPC Reporte ${_isoDay(from)} a ${_isoDay(to)}',
      format: PdfPageFormat.letter,
      dynamicLayout: false,
      windowsModernDialog: true,
      onLayout: (_) async => bytes,
    );
  }

  static Future<bool> saveReport(
    List<Sale> sales,
    List<Payment> payments,
    DateTime from,
    DateTime to,
  ) async {
    final bytes = await buildReport(sales, payments, from, to);
    return _save(bytes, 'CAPC-reporte-${_isoDay(from)}-${_isoDay(to)}.pdf');
  }

  static Future<bool> _save(Uint8List bytes, String name) async {
    final destination = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Documento PDF', extensions: ['pdf']),
      ],
      suggestedName: name,
      confirmButtonText: 'Guardar PDF',
    );
    if (destination == null) return false;
    final file = XFile.fromData(bytes, name: name, mimeType: 'application/pdf');
    await file.saveTo(destination.path);
    return true;
  }

  static Future<pw.ThemeData> _theme() async {
    // Asset bundles in widget tests can complete synchronously. Loading each
    // font explicitly also gives the failing asset a useful stack trace.
    final regular = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
    return pw.ThemeData.withFont(
      base: pw.Font.ttf(regular),
      bold: pw.Font.ttf(bold),
    );
  }

  static Future<Uint8List> buildSale(Sale sale, {bool ticket = false}) async {
    final document = pw.Document(
      title: 'Comprobante ${sale.number}',
      author: _business,
    );
    final theme = await _theme();
    final size = ticket ? 8.5 : 10.0;
    document.addPage(
      pw.MultiPage(
        pageFormat: ticket ? _ticketFormat : PdfPageFormat.letter,
        margin: pw.EdgeInsets.all(ticket ? 4 * PdfPageFormat.mm : 36),
        theme: theme,
        // A bounded row always fits; the limit grows with the number of lines.
        maxPages: sale.lines.length + 20,
        header: (_) =>
            _header('Comprobante de venta', sale.number, ticket: ticket),
        footer: (context) => _footer(context, ticket: ticket),
        build: (_) => [
          pw.Text(
            'Fecha y hora: ${_instant(sale.createdAt)}',
            style: pw.TextStyle(fontSize: size),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Cliente: ${sale.customerName}',
            style: pw.TextStyle(fontSize: size),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Vendedor: ${sale.operatorName}',
            style: pw.TextStyle(fontSize: size),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Método inicial: ${sale.paymentMethod}',
            style: pw.TextStyle(fontSize: size),
          ),
          if (sale.dueAt != null) ...[
            pw.SizedBox(height: 4),
            pw.Text(
              'Vencimiento: ${_day(sale.dueAt!.toUtc().subtract(const Duration(hours: 5)))}',
              style: pw.TextStyle(fontSize: size),
            ),
          ],
          pw.SizedBox(height: 12),
          ticket ? _ticketLines(sale.lines) : _saleLines(sale.lines),
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: const pw.BoxDecoration(color: _pale),
            child: pw.Column(
              children: [
                _totalRow(
                  'Total de la venta',
                  sale.total,
                  size: size + 1,
                  bold: true,
                ),
                if (sale.returnedTotal > 0) ...[
                  pw.SizedBox(height: 6),
                  _totalRow(
                    'Devoluciones / anulación',
                    sale.returnedTotal,
                    size: size,
                  ),
                  pw.SizedBox(height: 6),
                  _totalRow(
                    'Total neto',
                    sale.netTotal,
                    size: size,
                    bold: true,
                  ),
                ],
                pw.SizedBox(height: 6),
                _totalRow('Recibido al confirmar', sale.received, size: size),
                pw.SizedBox(height: 6),
                _totalRow('Cambio entregado', sale.change, size: size),
                if (sale.prepaid > 0) ...[
                  pw.SizedBox(height: 6),
                  _totalRow('Anticipos aplicados', sale.prepaid, size: size),
                ],
                if (sale.refunded > 0) ...[
                  pw.SizedBox(height: 6),
                  _totalRow('Dinero reintegrado', sale.refunded, size: size),
                ],
                pw.SizedBox(height: 6),
                _totalRow('Pagado acumulado', sale.paid, size: size),
                pw.SizedBox(height: 6),
                _totalRow(
                  'Saldo pendiente',
                  sale.balance,
                  size: size,
                  bold: true,
                ),
                pw.SizedBox(height: 8),
                pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Text(
                    'Estado: ${sale.status}',
                    style: pw.TextStyle(
                      fontSize: size,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Valores en pesos colombianos (COP).',
            style: pw.TextStyle(fontSize: size - 1, color: _muted),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Pagado y saldo reflejan abonos y compensaciones registrados al generar este documento. Los conceptos originales se conservan.',
            style: pw.TextStyle(fontSize: size - 1, color: _muted),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Generado: ${_instant(DateTime.now())}',
            style: pw.TextStyle(fontSize: size - 1, color: _muted),
          ),
        ],
      ),
    );
    return document.save();
  }

  static Future<Uint8List> buildReport(
    List<Sale> sales,
    List<Payment> payments,
    DateTime from,
    DateTime to,
  ) async {
    final data = CapcReportData.forPeriod(sales, payments, from, to);
    final saleNumbers = {for (final sale in sales) sale.id: sale.number};
    final document = pw.Document(
      title: 'Reporte de ventas y cobros',
      author: _business,
    );
    final theme = await _theme();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(36),
        theme: theme,
        maxPages: data.sales.length + data.payments.length + 20,
        header: (_) => _header(
          'Reporte de ventas y cobros',
          '${_day(data.from)} al ${_day(data.to)}',
        ),
        footer: (context) => _footer(context),
        build: (_) => [
          pw.Text(
            'Días completos en Bogotá (UTC-5) · Valores en COP',
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Generado: ${_instant(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(14),
            decoration: const pw.BoxDecoration(color: _pale),
            child: pw.Column(
              children: [
                _totalRow(
                  'Ventas originales del período (${data.sales.length})',
                  data.totalSales,
                  bold: true,
                ),
                pw.SizedBox(height: 8),
                _totalRow(
                  'Cobros menos reintegros del período',
                  data.totalCollected,
                  bold: true,
                ),
                pw.SizedBox(height: 8),
                _totalRow(
                  'Saldo actual de ventas del período',
                  data.outstandingBalance,
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Text(
            'Se suman los importes aplicados de pagos iniciales y abonos y se restan los reintegros según su fecha de registro, incluso si la venta es de otro período. El efectivo recibido para dar cambio no aumenta el cobro. El saldo es el pendiente actual de las ventas seleccionadas; no reconstruye una cartera histórica.',
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Las ventas originales conservan su importe al confirmar. Consulta Ventas y utilidad para compensaciones por fecha y ventas netas. Este reporte no calcula utilidad ni incluye gastos, compras o impuestos.',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),
          _sectionTitle('Ventas del período'),
          if (data.sales.isEmpty)
            _empty('No hay ventas en este período.')
          else
            _table(
              [
                'Venta / fecha y hora',
                'Cliente',
                'Estado',
                'Neto\nactual',
                'Pagado\nacumulado',
                'Saldo\nactual',
              ],
              [
                for (final sale in data.sales)
                  [
                    '${sale.number}\n${_instant(sale.createdAt)}',
                    sale.customerName,
                    sale.status,
                    _money(sale.netTotal),
                    _money(sale.paid),
                    _money(sale.balance),
                  ],
              ],
              widths: const [2.0, 1.8, 1.2, 1.2, 1.2, 1.2],
              numericColumns: const {3, 4, 5},
              fontSize: 8,
            ),
          pw.SizedBox(height: 16),
          _sectionTitle('Cobros y reintegros del período'),
          if (data.payments.isEmpty)
            _empty('No hay cobros ni reintegros en este período.')
          else
            _table(
              ['Fecha y hora (Bogotá)', 'Venta', 'Método', 'Importe aplicado'],
              [
                for (final payment in data.payments)
                  [
                    _instant(payment.createdAt),
                    saleNumbers[payment.saleId] ?? payment.saleId,
                    payment.method,
                    _money(payment.amount),
                  ],
              ],
              widths: const [2.2, 2, 2, 1.6],
              numericColumns: const {3},
            ),
        ],
      ),
    );
    return document.save();
  }

  static Future<Uint8List> buildTableDocument({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
    List<String> notes = const [],
    bool ticket = false,
  }) async {
    if (headers.isEmpty || rows.any((row) => row.length != headers.length)) {
      throw ArgumentError(
        'Cada fila debe coincidir con las columnas del documento.',
      );
    }
    final document = pw.Document(title: title, author: _business);
    document.addPage(
      pw.MultiPage(
        pageFormat: ticket ? _ticketFormat : PdfPageFormat.letter,
        margin: pw.EdgeInsets.all(ticket ? 4 * PdfPageFormat.mm : 36),
        theme: await _theme(),
        maxPages: rows.length + notes.length + 20,
        header: (_) => _header(
          title,
          'Generado: ${_instant(DateTime.now())}',
          ticket: ticket,
        ),
        footer: (context) => _footer(context, ticket: ticket),
        build: (_) => [
          for (final note in notes) ...[
            pw.Text(note, style: pw.TextStyle(fontSize: ticket ? 8 : 10)),
            pw.SizedBox(height: 6),
          ],
          pw.SizedBox(height: 8),
          if (rows.isEmpty)
            _empty('Sin registros.')
          else
            _table(
              headers,
              rows,
              widths: List.filled(headers.length, 1),
              fontSize: ticket ? 8 : 9,
            ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Valores monetarios en pesos colombianos (COP). Fechas en Bogotá (UTC-5).',
            style: const pw.TextStyle(fontSize: 8, color: _muted),
          ),
        ],
      ),
    );
    return document.save();
  }

  static Future<Uint8List> buildStatement(
    Customer customer,
    List<Sale> sales,
    List<Payment> payments,
  ) async {
    final accountSales =
        sales.where((s) => s.customerId == customer.id).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final byId = {for (final sale in accountSales) sale.id: sale};
    final accountPayments =
        payments.where((p) => byId.containsKey(p.saleId)).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final document = pw.Document(
      title: 'Estado de cuenta - ${customer.name}',
      author: _business,
    );
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(36),
        theme: await _theme(),
        maxPages: accountSales.length + accountPayments.length + 20,
        header: (_) => _header('Estado de cuenta', customer.name),
        footer: (context) => _footer(context),
        build: (_) => [
          pw.Text(
            'Teléfono: ${customer.phone.isEmpty ? "Sin registrar" : customer.phone}',
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Generado: ${_instant(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 12),
          _totalRow(
            'Saldo pendiente actual',
            accountSales.fold(0, (sum, s) => sum + s.balance),
            bold: true,
          ),
          pw.SizedBox(height: 16),
          _sectionTitle('Documentos'),
          if (accountSales.isEmpty)
            _empty('Sin ventas registradas.')
          else
            _table(
              ['Documento / fecha', 'Estado', 'Total', 'Abonado', 'Saldo'],
              [
                for (final s in accountSales)
                  [
                    '${s.number}\n${_instant(s.createdAt)}${s.dueAt == null ? "" : "\nVence: ${_day(s.dueAt!.toUtc().subtract(const Duration(hours: 5)))}"}',
                    s.status,
                    _money(s.netTotal),
                    _money(s.paid),
                    _money(s.balance),
                  ],
              ],
              widths: const [2.5, 1.4, 1.4, 1.4, 1.4],
              numericColumns: const {2, 3, 4},
            ),
          pw.SizedBox(height: 16),
          _sectionTitle('Historial de cobros'),
          if (accountPayments.isEmpty)
            _empty('Sin pagos registrados.')
          else
            _table(
              ['Fecha Bogotá', 'Documento', 'Medio', 'Aplicado'],
              [
                for (final p in accountPayments)
                  [
                    _instant(p.createdAt),
                    byId[p.saleId]!.number,
                    p.method,
                    _money(p.amount),
                  ],
              ],
              widths: const [2.5, 1.5, 1.5, 1.5],
              numericColumns: const {3},
            ),
          pw.SizedBox(height: 12),
          pw.Text(
            'Este estado muestra los saldos actuales. Conserva los comprobantes de pago y documentos compensatorios.',
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
        ],
      ),
    );
    return document.save();
  }

  static pw.Widget _saleLines(List<SaleLine> lines) => _table(
    [
      'Código / producto o servicio',
      'Unidad',
      'Cant.',
      'Precio unitario',
      'Total',
    ],
    [
      for (final line in lines)
        [
          '${line.code}\n${line.name}',
          line.unit,
          '${line.quantity}',
          _money(line.unitPrice),
          _money(line.total),
        ],
    ],
    widths: const [3.8, 1, 0.7, 1.7, 1.7],
    numericColumns: const {2, 3, 4},
  );

  static pw.Widget _ticketLines(List<SaleLine> lines) => _table(
    ['Producto / cantidad × precio', 'Total'],
    [
      for (final line in lines)
        [
          '${line.code} · ${line.name}\n${line.quantity} ${line.unit} × ${_money(line.unitPrice)}',
          _money(line.total),
        ],
    ],
    widths: const [3.5, 1.5],
    numericColumns: const {1},
    fontSize: 8.5,
    padding: 4,
  );

  static pw.Table _table(
    List<String> headers,
    List<List<String>> rows, {
    required List<double> widths,
    Set<int> numericColumns = const {},
    double fontSize = 9,
    double padding = 6,
  }) {
    pw.Widget cell(String text, int column, {bool heading = false}) =>
        pw.Padding(
          padding: pw.EdgeInsets.all(padding),
          child: pw.Text(
            text,
            textAlign: numericColumns.contains(column)
                ? pw.TextAlign.right
                : pw.TextAlign.left,
            style: pw.TextStyle(
              fontSize: fontSize,
              color: _ink,
              fontWeight: heading ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        );
    return pw.Table(
      columnWidths: {
        for (var i = 0; i < widths.length; i++)
          i: pw.FlexColumnWidth(widths[i]),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
      ),
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _pale),
          children: [
            for (var i = 0; i < headers.length; i++)
              cell(headers[i], i, heading: true),
          ],
        ),
        for (final row in rows)
          pw.TableRow(
            children: [for (var i = 0; i < row.length; i++) cell(row[i], i)],
          ),
      ],
    );
  }

  static pw.Widget _header(
    String title,
    String subtitle, {
    bool ticket = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 12),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          _business,
          style: pw.TextStyle(
            fontSize: ticket ? 12 : 20,
            color: _ink,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          title,
          style: pw.TextStyle(fontSize: ticket ? 10 : 13, color: _ink),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          subtitle,
          style: pw.TextStyle(fontSize: ticket ? 9 : 10, color: _muted),
        ),
        pw.SizedBox(height: 8),
        pw.Divider(color: _rule, thickness: 0.7, height: 1),
      ],
    ),
  );

  static pw.Widget _footer(pw.Context context, {bool ticket = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 10),
        child: pw.Column(
          children: [
            pw.Divider(color: _rule, thickness: 0.5),
            pw.Text(
              _notice,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: ticket ? 7 : 8, color: _muted),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              'Página ${context.pageNumber} de ${context.pagesCount}',
              style: pw.TextStyle(fontSize: ticket ? 7 : 8, color: _muted),
            ),
          ],
        ),
      );

  static pw.Widget _totalRow(
    String label,
    int amount, {
    double size = 10,
    bool bold = false,
  }) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: size,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      ),
      pw.SizedBox(width: 8),
      pw.Text(
        _money(amount),
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    ],
  );

  static pw.Widget _sectionTitle(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Text(
      text,
      style: pw.TextStyle(
        fontSize: 11,
        fontWeight: pw.FontWeight.bold,
        color: _ink,
      ),
    ),
  );

  static pw.Widget _empty(String text) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 10),
    child: pw.Text(
      text,
      style: const pw.TextStyle(fontSize: 10, color: _muted),
    ),
  );

  static String _money(int value) {
    final digits = value.abs().toString();
    final grouped = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]}.',
    );
    return '${value < 0 ? '-' : ''}\$ $grouped';
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');
  static String _day(DateTime date) =>
      '${_pad(date.day)}/${_pad(date.month)}/${date.year}';
  static String _isoDay(DateTime date) =>
      '${date.year}-${_pad(date.month)}-${_pad(date.day)}';
  static String _instant(DateTime value) {
    final date = value.toUtc().subtract(const Duration(hours: 5));
    return '${_day(date)} ${_pad(date.hour)}:${_pad(date.minute)}:${_pad(date.second)} UTC-5';
  }

  static String _filePart(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-');
}
