import 'package:flutter/material.dart';
import '../data/models.dart';
import 'ui_shared.dart';

class DraftLine {
  const DraftLine({
    this.productId,
    required this.description,
    required this.quantity,
    required this.price,
    this.cost,
    this.unit = 'Unidad',
  });
  final String? productId;
  final String description, unit;
  final int quantity, price;
  final int? cost;
}

Future<List<DraftLine>?> editDocumentLines(
  BuildContext context,
  List<Product> products, {
  required bool purchase,
  bool allowPriceChanges = true,
  List<DraftLine> initialLines = const [],
}) async {
  final lines = List<DraftLine>.of(initialLines);
  Future<void> editLine(
    BuildContext ctx,
    StateSetter update, [
    int? index,
  ]) async {
    final existing = index == null ? null : lines[index];
    var selected = existing?.productId ?? 'custom';
    final eligible = purchase
        ? products.where((p) => !p.isService).toList()
        : products;
    if (existing == null) {
      final first = await entryDialog(
        ctx,
        title: 'Seleccionar concepto',
        fields: [
          EntryField(
            'product',
            'Producto / servicio',
            options: {
              if (!purchase && allowPriceChanges)
                'custom': 'Trabajo personalizado',
              for (final p in eligible) p.id: '${p.code} · ${p.name}',
            },
          ),
        ],
        onSave: (v) async {
          selected = v['product']!;
        },
        saveLabel: 'Continuar',
      );
      if (!first || !ctx.mounted) return;
    }
    final product = selected == 'custom'
        ? null
        : eligible.firstWhere((p) => p.id == selected);
    if (product == null && !allowPriceChanges) return;
    final saved = await entryDialog(
      ctx,
      title: existing == null ? 'Detalle del concepto' : 'Editar concepto',
      fields: [
        EntryField(
          'description',
          'Descripción',
          value: existing?.description ?? product?.name ?? '',
        ),
        EntryField(
          'unit',
          'Unidad',
          value: existing?.unit ?? product?.unit ?? 'Servicio',
        ),
        EntryField(
          'quantity',
          'Cantidad',
          value: '${existing?.quantity ?? 1}',
          number: true,
        ),
        if (purchase)
          EntryField(
            'costMode',
            'Tipo de costo',
            value: existing == null ? 'unit' : 'lot',
            options: const {'unit': 'Costo unitario', 'lot': 'Total del lote'},
          ),
        EntryField(
          'price',
          purchase ? 'Costo de compra (COP)' : 'Precio unitario (COP)',
          value: existing != null
              ? '${existing.price}'
              : purchase
              ? ''
              : '${product?.salePrice ?? 0}',
          hint: purchase
              ? 'Unitario: se multiplica por la cantidad. Total del lote: se conserva el importe exacto.'
              : null,
          number: true,
          editable: purchase || allowPriceChanges,
        ),
        if (product == null)
          EntryField(
            'cost',
            'Costo unitario directo (COP, opcional)',
            value: existing?.cost == null ? '' : '${existing!.cost}',
            number: true,
            required: false,
            hint: 'Vacío indica costo desconocido.',
          ),
      ],
      onSave: (v) async {
        final q = int.parse(v['quantity']!);
        if (q <= 0 || q > 1000000000) {
          throw const CapcException(
            'La cantidad debe ser mayor que cero y no superar 1.000.000.000.',
          );
        }
        var entered = BigInt.from(int.parse(v['price']!));
        if (purchase && v['costMode'] == 'unit') entered *= BigInt.from(q);
        if (entered > BigInt.from(999999999999)) {
          throw const CapcException(
            'El costo total supera el importe máximo permitido.',
          );
        }
        final line = DraftLine(
          productId: product?.id,
          description: v['description']!,
          quantity: q,
          price: entered.toInt(),
          unit: v['unit']!,
          cost: int.tryParse(v['cost'] ?? ''),
        );
        if (index == null) {
          lines.add(line);
        } else {
          lines[index] = line;
        }
      },
      saveLabel: existing == null ? 'Agregar concepto' : 'Guardar concepto',
    );
    if (saved && ctx.mounted) update(() {});
  }

  return showDialog<List<DraftLine>>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text(
          purchase ? 'Materiales de la compra' : 'Conceptos de la cotización',
        ),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Agrega uno o varios conceptos. Podrás revisar el total antes de guardar.',
                ),
                const SizedBox(height: 16),
                for (var index = 0; index < lines.length; index++)
                  DataCard(
                    title: lines[index].description,
                    subtitle:
                        '${lines[index].quantity} ${lines[index].unit} · ${purchase ? 'Costo lote' : 'Precio unitario'} ${cop(lines[index].price)}',
                    actions: [
                      if (allowPriceChanges || lines[index].productId != null)
                        TextButton.icon(
                          onPressed: () => editLine(ctx, update, index),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Editar concepto'),
                        ),
                      TextButton.icon(
                        onPressed: () => update(() => lines.removeAt(index)),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Quitar'),
                      ),
                    ],
                  ),
                OutlinedButton.icon(
                  onPressed: () => editLine(ctx, update),
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar concepto'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Total: ${cop(lines.fold(0, (sum, l) => sum + (purchase ? l.price : l.price * l.quantity)))}',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: lines.isEmpty
                ? null
                : () => Navigator.pop(ctx, List<DraftLine>.of(lines)),
            child: const Text('Continuar'),
          ),
        ],
      ),
    ),
  );
}
