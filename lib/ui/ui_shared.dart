import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

String cop(int value) =>
    '\$ ${NumberFormat.decimalPattern('es_CO').format(value)}';
DateTime bogotaNow() =>
    DateTime.now().toUtc().subtract(const Duration(hours: 5));
String localDate(DateTime? value) => value == null
    ? 'Sin fecha'
    : DateFormat(
        'dd/MM/yyyy HH:mm',
      ).format(value.toUtc().subtract(const Duration(hours: 5)));
DateTime dateInput(String text) {
  try {
    final date = DateFormat('dd/MM/yyyy').parseStrict(text.trim());
    return DateTime.utc(
      date.year,
      date.month,
      date.day,
      23,
      59,
      59,
    ).add(const Duration(hours: 5));
  } catch (_) {
    throw const FormatException('Escribe una fecha válida: dd/mm/aaaa.');
  }
}

String dateText(DateTime? value) => DateFormat(
  'dd/MM/yyyy',
).format(value?.toUtc().subtract(const Duration(hours: 5)) ?? bogotaNow());

class EntryField {
  const EntryField(
    this.key,
    this.label, {
    this.value = '',
    this.required = true,
    this.number = false,
    this.secret = false,
    this.options,
    this.lines = 1,
    this.hint,
    this.editable = true,
  });
  final String key, label, value;
  final bool required, number, secret;
  final Map<String, String>? options;
  final int lines;
  final String? hint;
  final bool editable;
}

Future<bool> entryDialog(
  BuildContext context, {
  required String title,
  required List<EntryField> fields,
  required Future<void> Function(Map<String, String>) onSave,
  String saveLabel = 'Guardar',
  String? notice,
}) async {
  final controllers = {
    for (final f in fields) f.key: TextEditingController(text: f.value),
  };
  final form = GlobalKey<FormState>();
  var busy = false;
  String? error;
  final route = DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (notice != null) ...[
                      Text(notice),
                      const SizedBox(height: 18),
                    ],
                    for (final f in fields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: f.options != null
                            ? DropdownButtonFormField<String>(
                                itemHeight: null,
                                initialValue: f.options!.containsKey(f.value)
                                    ? f.value
                                    : null,
                                isExpanded: true,
                                decoration: InputDecoration(labelText: f.label),
                                items: f.options!.entries
                                    .map(
                                      (e) => DropdownMenuItem(
                                        value: e.key,
                                        child: Text(
                                          e.value,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: busy
                                    ? null
                                    : (v) => controllers[f.key]!.text = v ?? '',
                                validator: (v) =>
                                    f.required && (v == null || v.isEmpty)
                                    ? 'Selecciona una opción.'
                                    : null,
                              )
                            : TextFormField(
                                readOnly: !f.editable,
                                controller: controllers[f.key],
                                enabled: !busy,
                                decoration: InputDecoration(
                                  labelText: f.label,
                                  helperText: f.hint,
                                ),
                                obscureText: f.secret,
                                maxLines: f.lines,
                                keyboardType: f.number
                                    ? TextInputType.number
                                    : TextInputType.text,
                                inputFormatters: f.number
                                    ? [FilteringTextInputFormatter.digitsOnly]
                                    : null,
                                validator: (v) =>
                                    f.required &&
                                        (v == null || v.trim().isEmpty)
                                    ? 'Completa este campo.'
                                    : f.number &&
                                          v != null &&
                                          v.isNotEmpty &&
                                          int.tryParse(v) == null
                                    ? 'Escribe un entero válido.'
                                    : null,
                              ),
                      ),
                    if (error != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                      ),
                    if (busy) const LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (busy) return;
                      if (!form.currentState!.validate()) return;
                      update(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await onSave({
                          for (final e in controllers.entries)
                            e.key: e.value.text.trim(),
                        });
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        if (ctx.mounted) {
                          update(() {
                            busy = false;
                            error = e.toString();
                          });
                        }
                      }
                    },
              child: Text(busy ? 'Guardando…' : saveLabel),
            ),
          ],
        ),
      ),
    ),
  );
  final result = await Navigator.of(context).push(route);
  await route.completed;
  for (final controller in controllers.values) {
    controller.dispose();
  }
  return result == true;
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String detail, {
  String action = 'Confirmar',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(detail)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

class DataCard extends StatelessWidget {
  const DataCard({
    super.key,
    required this.title,
    this.subtitle,
    this.children = const [],
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final List<Widget> children, actions;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFDCE3E8)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!)],
        if (children.isNotEmpty) ...[const SizedBox(height: 14), ...children],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: actions),
        ],
      ],
    ),
  );
}

const paymentOptions = {
  'Efectivo': 'Efectivo',
  'Transferencia': 'Transferencia',
  'Tarjeta': 'Tarjeta',
};

String operationLabel(String value) =>
    const {
      'user.saved': 'Usuario actualizado',
      'product.saved': 'Producto actualizado',
      'catalog.imported': 'Catálogo importado desde Excel',
      'service.recipe_saved': 'Materiales del servicio actualizados',
      'stock.moved': 'Movimiento de inventario',
      'customer.saved': 'Cliente actualizado',
      'catalog.example_loaded': 'Catálogo de ejemplo cargado',
      'sale.created': 'Venta registrada',
      'payment.added': 'Abono registrado',
      'advance.applied': 'Anticipo aplicado',
      'sale.cancelled': 'Venta anulada',
      'sale.returned': 'Devolución registrada',
      'cash.opened': 'Apertura de caja',
      'cash.closed': 'Cierre de caja',
      'supplier.saved': 'Proveedor actualizado',
      'purchase.created': 'Compra registrada',
      'purchase.received': 'Compra recibida',
      'supplier.payment': 'Pago a proveedor',
      'quote.created': 'Cotización creada',
      'quote.updated': 'Cotización actualizada',
      'quote.status': 'Estado de cotización actualizado',
      'quote.converted': 'Cotización convertida en venta',
      'work.created': 'Trabajo recibido',
      'work.updated': 'Trabajo actualizado',
      'work.advance': 'Anticipo de trabajo',
      'work.advanceApplied': 'Anticipo aplicado',
      'purchase': 'Recepción de compra',
      'expense': 'Gasto',
      'login': 'Inicio de sesión',
      'owner.created': 'Propietario creado',
      'user.owner_created': 'Primer propietario creado',
      'user.recovery_code_generated': 'Código de recuperación renovado',
      'user.password_recovered': 'Contraseña restablecida con código',
      'user.owner_reconfiguration_prepared':
          'Cambio de acceso propietario preparado',
      'user.owner_reconfigured': 'Nuevo acceso propietario configurado',
      'backup.restored': 'Respaldo restaurado',
      'backup.startup_recovered': 'Datos recuperados al iniciar',
      'backup.interruption_recovered': 'Restauración interrumpida recuperada',
      'migration.opening_valuation': 'Valoración inicial de datos anteriores',
      'cash.adjustment': 'Entrada / retiro de caja',
    }[value] ??
    value;

String auditDescription(String value) {
  try {
    final parsed = jsonDecode(value);
    if (parsed is! Map) return value;
    const labels = {
      'name': 'Nombre',
      'number': 'Documento',
      'total': 'Total',
      'paid': 'Aplicado',
      'amount': 'Importe',
      'received': 'Recibido',
      'reason': 'Motivo',
      'role': 'Rol',
      'active': 'Activo',
      'delta': 'Cantidad',
      'method': 'Medio de pago',
      'openingAmount': 'Base inicial',
      'expectedAmount': 'Esperado',
      'countedAmount': 'Contado',
      'difference': 'Diferencia',
      'description': 'Descripción',
      'status': 'Estado',
      'reference': 'Referencia',
      'code': 'Código',
      'unit': 'Unidad',
      'category': 'Categoría',
      'phone': 'Teléfono',
      'document': 'Documento',
      'address': 'Dirección',
      'note': 'Observación',
      'previousUsername': 'Usuario anterior',
      'backup': 'Respaldo previo',
    };
    final parts = <String>[];
    for (final e in parsed.entries) {
      if (!labels.containsKey(e.key)) continue;
      var text = '${e.value}';
      text =
          const {
            'owner': 'Propietario',
            'admin': 'Administrador',
            'cashier': 'Cajero',
            'true': 'Sí',
            'false': 'No',
            'draft': 'Borrador',
            'accepted': 'Aceptada',
            'received': 'Recibido',
            'ready': 'Listo',
            'delivered': 'Entregado',
          }[text] ??
          text;
      parts.add('${labels[e.key]}: $text');
    }
    return parts.isEmpty ? 'Cambio registrado.' : parts.join(' · ');
  } catch (_) {
    return value;
  }
}
