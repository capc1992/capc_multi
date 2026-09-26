import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../data/repository.dart';
import '../services/documents.dart';
import '../services/document_preview.dart';
import '../services/reporting.dart';
import 'line_editor.dart';
import 'spreadsheet_actions.dart';
import 'ui_shared.dart';

class ManagementPage extends StatefulWidget {
  const ManagementPage({
    super.key,
    required this.repository,
    required this.page,
    required this.onChanged,
    this.refreshRevision = 0,
  });
  final CapcRepository repository;
  final int page;
  final int refreshRevision;
  final Future<void> Function() onChanged;
  @override
  State<ManagementPage> createState() => _ManagementState();
}

class _ManagementState extends State<ManagementPage> {
  CapcRepository get repo => widget.repository;
  bool get manager => repo.currentUser?.role != UserRole.cashier;
  bool get owner => repo.currentUser?.role == UserRole.owner;
  bool loading = true, busy = false;
  String? error;
  String query = '';
  List<Product> products = [];
  List<Customer> customers = [];
  List<Supplier> suppliers = [];
  List<Purchase> purchases = [];
  List<Quote> quotes = [];
  List<WorkOrder> works = [];
  List<LocalUser> users = [];
  List<AuditEntry> audits = [];
  List<CashSession> sessions = [];
  List<CashMovement> movements = [];
  CashSession? current;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant ManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshRevision != widget.refreshRevision) refresh();
  }

  Future<void> refresh() async {
    try {
      if (widget.page == 7) {
        current = await repo.currentCashSession();
        sessions = await repo.listCashSessions();
        movements = await repo.listCashMovements();
      }
      if (widget.page == 8) {
        suppliers = await repo.listSuppliers();
        purchases = await repo.listPurchases();
        products = await repo.listProducts();
      }
      if (widget.page == 9) {
        quotes = await repo.listQuotes();
        works = await repo.listWorkOrders();
        products = await repo.listProducts();
        customers = await repo.listCustomers();
      }
      if (widget.page == 10) {
        if (owner) users = await repo.listUsers();
        audits = await repo.listAudit();
      }
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString();
        });
      }
    }
  }

  Future<void> action(Future<void> Function() fn) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await fn();
      await refresh();
      await widget.onChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            duration: const Duration(seconds: 7),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget button(
    String text,
    IconData icon,
    Future<void> Function() fn, {
    bool primary = false,
  }) => primary
      ? FilledButton.icon(
          onPressed: busy ? null : () => action(fn),
          icon: Icon(icon),
          label: Text(text),
        )
      : OutlinedButton.icon(
          onPressed: busy ? null : () => action(fn),
          icon: Icon(icon),
          label: Text(text),
        );
  bool matches(String value) =>
      value.toLowerCase().contains(query.toLowerCase());
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null) {
      return DataCard(
        title: 'No se pudieron cargar los datos',
        subtitle: error,
        actions: [button('Volver a intentar', Icons.refresh, refresh)],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) const LinearProgressIndicator(),
        if (widget.page != 7)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Buscar',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
        ...switch (widget.page) {
          7 => cash(),
          8 => purchasePage(),
          9 => quotePage(),
          _ => userPage(),
        },
      ],
    );
  }

  List<Widget> cash() => [
    DataCard(
      title: current == null ? 'Caja cerrada' : 'Caja abierta',
      subtitle: current == null
          ? 'Abre una caja antes de registrar ventas, abonos, gastos o pagos.'
          : 'Apertura: ${localDate(current!.openedAt)} · ${current!.openedBy}',
      actions: [
        if (current == null)
          button(
            'Abrir caja',
            Icons.lock_open,
            () => cashOpen(),
            primary: true,
          ),
        if (current != null)
          button(
            'Cerrar caja',
            Icons.lock_outline,
            () => cashClose(),
            primary: true,
          ),
        if (current != null && manager)
          button('Registrar gasto', Icons.money_off, () => expense()),
        if (current != null && manager)
          button(
            'Entrada / retiro de caja',
            Icons.swap_vert,
            () => cashAdjustment(),
          ),
        button(
          'Reporte de caja / PDF',
          Icons.description_outlined,
          () => showCapcDocument(
            context,
            title: 'Caja y movimientos',
            build: () => CapcDocuments.buildTableDocument(
              title: 'Movimientos de caja',
              headers: [
                'Fecha Bogotá',
                'Concepto',
                'Método',
                'Importe',
                'Responsable',
              ],
              rows: movements
                  .map(
                    (m) => [
                      localDate(m.createdAt),
                      m.reason,
                      m.method,
                      cop(m.amount),
                      m.actorName,
                    ],
                  )
                  .toList(),
              notes: [
                'El efectivo esperado incluye la base y los movimientos en efectivo. Transferencias y tarjeta se muestran por separado.',
              ],
            ),
          ),
        ),
      ],
      children: [
        if (current != null) ...[
          Text('Base inicial: ${cop(current!.openingAmount)}'),
          Text('Efectivo esperado: ${cop(current!.expectedAmount)}'),
        ],
      ],
    ),
    for (final session in sessions)
      DataCard(
        title: session.closedAt == null
            ? 'Sesión abierta'
            : 'Cierre ${localDate(session.closedAt)}',
        subtitle:
            'Apertura ${localDate(session.openedAt)} · ${session.openedBy}',
        children: [
          Text('Esperado: ${cop(session.expectedAmount)}'),
          if (session.countedAmount != null)
            Text(
              'Contado: ${cop(session.countedAmount!)} · Diferencia: ${cop(session.difference ?? 0)}',
            ),
          if (session.note.isNotEmpty) Text(session.note),
        ],
      ),
    if (movements.isEmpty) const DataCard(title: 'Sin movimientos de caja'),
    if (movements.length > 200)
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text(
          'Se muestran los 200 movimientos más recientes. El reporte PDF incluye todo el historial.',
        ),
      ),
    for (final m in movements.take(200))
      DataCard(
        title: m.reason,
        subtitle:
            '${localDate(m.createdAt)} · ${m.method} · ${cop(m.amount)} · ${m.actorName}',
      ),
  ];
  Future<void> cashOpen() async {
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Abrir caja',
      fields: [
        const EntryField(
          'amount',
          'Efectivo inicial (COP)',
          value: '0',
          number: true,
        ),
      ],
      onSave: (v) async {
        await repo.openCash(int.parse(v['amount']!), operationId: id);
      },
    );
  }

  Future<void> cashClose() async {
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Cerrar caja',
      notice:
          'Cuenta el efectivo físico. Esperado: ${cop(current!.expectedAmount)}. La diferencia quedará registrada.',
      fields: [
        const EntryField('amount', 'Efectivo contado (COP)', number: true),
        const EntryField('note', 'Observaciones', required: false, lines: 3),
      ],
      onSave: (v) async {
        await repo.closeCash(
          int.parse(v['amount']!),
          note: v['note']!,
          operationId: id,
        );
      },
      saveLabel: 'Registrar cierre',
    );
  }

  Future<void> expense() async {
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Registrar gasto',
      fields: [
        const EntryField('amount', 'Importe (COP)', number: true),
        const EntryField('reason', 'Concepto / motivo'),
        const EntryField(
          'method',
          'Medio de pago',
          value: 'Efectivo',
          options: paymentOptions,
        ),
      ],
      onSave: (v) => repo.addExpense(
        int.parse(v['amount']!),
        v['reason']!,
        method: v['method']!,
        operationId: id,
      ),
    );
  }

  Future<void> cashAdjustment() async {
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Movimiento manual de caja',
      notice:
          'Usa este movimiento para aportes o retiros. Los gastos, ventas y pagos tienen sus propias opciones.',
      fields: [
        const EntryField(
          'direction',
          'Tipo',
          value: 'in',
          options: {'in': 'Entrada / aporte', 'out': 'Retiro / salida'},
        ),
        const EntryField('amount', 'Importe (COP)', number: true),
        const EntryField('reason', 'Motivo'),
        const EntryField(
          'method',
          'Medio',
          value: 'Efectivo',
          options: paymentOptions,
        ),
      ],
      onSave: (v) => repo.addCashAdjustment(
        int.parse(v['amount']!) * (v['direction'] == 'in' ? 1 : -1),
        v['reason']!,
        method: v['method']!,
        operationId: id,
      ),
    );
  }

  List<Widget> purchasePage() => [
    DataCard(
      title: 'Compras y cuentas por pagar',
      subtitle:
          'Registra la compra y confirma su recepción cuando los materiales estén disponibles.',
      actions: [
        button(
          'Nueva compra',
          Icons.add_shopping_cart,
          () => createPurchase(),
          primary: true,
        ),
        button('Nuevo proveedor', Icons.person_add_alt, () => supplierForm()),
      ],
    ),
    for (final supplier in suppliers.where(
      (s) => matches('${s.name} ${s.phone} ${s.document}'),
    ))
      DataCard(
        title: supplier.name,
        subtitle: '${supplier.phone} · ${supplier.document}',
        actions: [
          button(
            'Editar proveedor',
            Icons.edit_outlined,
            () => supplierForm(supplier),
          ),
        ],
        children: [
          Text(
            'Saldo por pagar: ${cop(purchases.where((p) => p.supplierId == supplier.id).fold(0, (sum, p) => sum + p.balance))}',
          ),
        ],
      ),
    if (purchases.isEmpty) const DataCard(title: 'Todavía no hay compras'),
    for (final p in purchases.where(
      (p) => matches('${p.number} ${p.supplierName} ${p.reference}'),
    ))
      DataCard(
        title: '${p.number} · ${p.supplierName}',
        subtitle:
            '${p.status} · ${p.received ? 'Material recibido' : 'Pendiente de recepción'} · ${localDate(p.createdAt)}',
        actions: [
          if (!p.received)
            button('Recibir materiales', Icons.inventory_2_outlined, () async {
              if (await confirmAction(
                context,
                'Recibir ${p.number}',
                'Se registrará la entrada de todos los materiales. Esta recepción solo se permite una vez.',
              )) {
                await repo.receivePurchase(
                  p.id,
                  operationId: 'receive-${p.id}',
                );
              }
            }),
          if (p.balance > 0)
            button(
              'Pagar / abonar',
              Icons.payments_outlined,
              () => supplierPayment(p),
            ),
          button(
            'Ver compra / PDF',
            Icons.description_outlined,
            () => purchaseDocument(p),
          ),
        ],
        children: [
          Text('Referencia: ${p.reference}'),
          Text(
            'Total ${cop(p.total)} · Pagado ${cop(p.paid)} · Saldo ${cop(p.balance)}',
          ),
          if (p.dueAt != null) Text('Vence: ${localDate(p.dueAt)}'),
        ],
      ),
  ];
  Future<void> supplierForm([Supplier? s]) async {
    await entryDialog(
      context,
      title: s == null ? 'Nuevo proveedor' : 'Editar proveedor',
      fields: [
        EntryField('name', 'Nombre', value: s?.name ?? ''),
        EntryField('phone', 'Teléfono', value: s?.phone ?? '', required: false),
        EntryField(
          'document',
          'Documento / identificación (opcional)',
          value: s?.document ?? '',
          required: false,
        ),
        EntryField(
          'address',
          'Dirección',
          value: s?.address ?? '',
          required: false,
        ),
      ],
      onSave: (v) => repo.saveSupplier(
        Supplier(
          id: s?.id ?? '',
          name: v['name']!,
          phone: v['phone']!,
          document: v['document']!,
          address: v['address']!,
        ),
      ),
    );
  }

  Future<void> createPurchase() async {
    if (suppliers.isEmpty) {
      throw const CapcException(
        'Registra un proveedor antes de crear la compra.',
      );
    }
    final lines = await editDocumentLines(context, products, purchase: true);
    if (lines == null || !mounted) return;
    final total = lines.fold(0, (sum, l) => sum + l.price);
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Registrar compra · ${cop(total)}',
      notice:
          'La compra se guarda pendiente de recepción. Confirma la llegada para actualizar existencias.',
      fields: [
        EntryField(
          'supplier',
          'Proveedor',
          options: {for (final s in suppliers) s.id: s.name},
        ),
        const EntryField('reference', 'Referencia del documento'),
        const EntryField(
          'paid',
          'Pago inicial (COP)',
          value: '0',
          number: true,
        ),
        const EntryField(
          'method',
          'Medio de pago',
          value: 'Efectivo',
          options: paymentOptions,
        ),
        EntryField(
          'due',
          'Vencimiento de la deuda (dd/mm/aaaa)',
          value: dateText(DateTime.now().toUtc().add(const Duration(days: 30))),
        ),
      ],
      onSave: (v) async {
        await repo.createPurchase(
          supplierId: v['supplier']!,
          reference: v['reference']!,
          items: [
            for (final l in lines)
              PurchaseItemInput(
                productId: l.productId!,
                quantity: l.quantity,
                totalCost: l.price,
              ),
          ],
          paid: int.parse(v['paid']!),
          paymentMethod: v['method']!,
          dueAt: int.parse(v['paid']!) < total ? dateInput(v['due']!) : null,
          operationId: id,
        );
      },
    );
  }

  Future<void> supplierPayment(Purchase p) async {
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Pago a ${p.supplierName}',
      notice: 'Saldo pendiente: ${cop(p.balance)}',
      fields: [
        EntryField(
          'amount',
          'Importe aplicado (COP)',
          value: '${p.balance}',
          number: true,
        ),
        const EntryField(
          'method',
          'Medio de pago',
          value: 'Efectivo',
          options: paymentOptions,
        ),
      ],
      onSave: (v) => repo.addSupplierPayment(
        p.id,
        int.parse(v['amount']!),
        v['method']!,
        operationId: id,
      ),
    );
  }

  Future<void> purchaseDocument(Purchase p) async {
    final payments = await repo.listSupplierPayments(purchaseId: p.id);
    if (!mounted) return;
    await showCapcDocument(
      context,
      title: 'Compra ${p.number}',
      build: () => CapcDocuments.buildTableDocument(
        title: 'Compra ${p.number} · ${p.supplierName}',
        headers: ['Concepto', 'Cantidad', 'Costo total'],
        rows: [
          for (final l in p.lines) [l.name, '${l.quantity}', cop(l.totalCost)],
        ],
        notes: [
          'Referencia: ${p.reference}',
          'Fecha: ${localDate(p.createdAt)}',
          'Estado: ${p.status} · ${p.received ? 'Recibida' : 'Pendiente de recepción'}',
          'Total: ${cop(p.total)} · Pagado: ${cop(p.paid)} · Saldo: ${cop(p.balance)}',
          for (final payment in payments)
            'Pago ${localDate(payment.createdAt)} · ${payment.method} · ${cop(payment.amount)}',
        ],
      ),
    );
  }

  List<QuoteStatus> quoteTransitions(Quote quote) {
    if (quote.status == QuoteStatus.rejected ||
        quote.status == QuoteStatus.expired ||
        quote.status == QuoteStatus.converted) {
      return const [];
    }
    final linked = works.where((w) => w.quoteId == quote.id);
    final hasAdvances = linked.any((w) => w.unappliedAdvances > 0);
    final pendingWork = linked.any((w) => w.status != WorkStatus.delivered);
    return [
      if (quote.status == QuoteStatus.draft && !quote.isExpired)
        QuoteStatus.sent,
      if ((quote.status == QuoteStatus.draft ||
              quote.status == QuoteStatus.sent) &&
          !quote.isExpired)
        QuoteStatus.accepted,
      if (!hasAdvances) QuoteStatus.rejected,
      if (!hasAdvances &&
          quote.isExpired &&
          (quote.status != QuoteStatus.accepted || !pendingWork))
        QuoteStatus.expired,
    ];
  }

  bool canEditQuote(Quote quote) =>
      quote.status == QuoteStatus.draft &&
      (manager ||
          quote.lines.every(
            (line) => products.any(
              (p) => p.id == line.productId && p.salePrice == line.unitPrice,
            ),
          ));

  Quote? workQuote(WorkOrder work) {
    for (final quote in quotes) {
      if (quote.id == work.quoteId) return quote;
    }
    return null;
  }

  bool canReceiveAdvance(WorkOrder work) {
    if (work.saleId != null || work.status == WorkStatus.delivered) {
      return false;
    }
    if (work.quoteId == null) return true;
    final quote = workQuote(work);
    return quote != null &&
        quote.status == QuoteStatus.accepted &&
        work.advancesTotal < quote.total;
  }

  List<Widget> quotePage() => [
    DataCard(
      title: 'Cotizaciones y trabajos',
      subtitle:
          'Las cotizaciones no afectan inventario ni caja. Una cotización aceptada puede convertirse en venta una sola vez.',
      actions: [
        button(
          'Nueva cotización',
          Icons.request_quote_outlined,
          () => createQuote(),
          primary: true,
        ),
        button('Recibir trabajo', Icons.assignment_add, () => createWork()),
      ],
    ),
    if (quotes.isEmpty && works.isEmpty)
      const DataCard(title: 'Todavía no hay cotizaciones ni trabajos'),
    for (final q in quotes.where(
      (q) => matches('${q.number} ${q.customerName} ${q.description}'),
    ))
      DataCard(
        title: '${q.number} · ${q.customerName}',
        subtitle:
            '${q.status.label} · ${cop(q.total)} · Válida hasta ${localDate(q.validUntil)}',
        actions: [
          button(
            'Vista previa / PDF',
            Icons.description_outlined,
            () => quoteDocument(q),
          ),
          if (canEditQuote(q))
            button(
              'Editar borrador',
              Icons.edit_outlined,
              () => createQuote(q),
            ),
          if (quoteTransitions(q).isNotEmpty)
            button('Cambiar estado', Icons.edit_note, () => quoteStatus(q)),
          if (q.status == QuoteStatus.accepted)
            button(
              'Convertir en venta',
              Icons.point_of_sale,
              () => convertQuote(q),
            ),
        ],
        children: [
          Text(q.description),
          if (q.conditions.isNotEmpty) Text(q.conditions),
        ],
      ),
    for (final w in works.where(
      (w) => matches('${w.number} ${w.customerName} ${w.description}'),
    ))
      DataCard(
        title: '${w.number} · ${w.customerName}',
        subtitle: '${w.status.label} · Entrega ${localDate(w.deliveryAt)}',
        actions: [
          button(
            'Actualizar trabajo',
            Icons.edit_outlined,
            () => workStatus(w),
          ),
          if (canReceiveAdvance(w))
            button(
              'Registrar anticipo',
              Icons.payments_outlined,
              () => advance(w),
            ),
          button(
            'Historial de anticipos',
            Icons.history,
            () => advanceHistory(w),
          ),
          if (w.unappliedAdvances > 0 &&
              (w.quoteId == null || workQuote(w)?.saleId != null))
            button('Aplicar a una venta', Icons.link, () => applyAdvance(w)),
        ],
        children: [
          Text(w.description),
          Text('Responsable: ${w.responsible}'),
          Text(
            'Anticipos: ${cop(w.advancesTotal)} · Por aplicar: ${cop(w.unappliedAdvances)}',
          ),
          if (w.unappliedAdvances > 0 &&
              w.quoteId != null &&
              workQuote(w)?.saleId == null)
            Text(
              'Los anticipos se aplicarán al convertir ${workQuote(w)?.number ?? 'la cotización vinculada'} en venta.',
            ),
        ],
      ),
  ];
  Future<void> createQuote([Quote? quote]) async {
    if (customers.isEmpty) {
      throw const CapcException('Registra un cliente antes de cotizar.');
    }
    final lines = await editDocumentLines(
      context,
      products,
      purchase: false,
      allowPriceChanges: manager,
      initialLines: [
        for (final line in quote?.lines ?? <QuoteLine>[])
          DraftLine(
            productId: line.productId,
            description: line.description,
            quantity: line.quantity,
            price: line.unitPrice,
            cost: line.directCost,
            unit: line.unit,
          ),
      ],
    );
    if (lines == null || !mounted) return;
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: quote == null ? 'Crear cotización' : 'Editar ${quote.number}',
      notice: quote == null
          ? null
          : 'Cliente: ${quote.customerName}. Los cambios se guardarán en el mismo borrador.',
      fields: [
        if (quote == null)
          EntryField(
            'customer',
            'Cliente',
            options: {for (final c in customers) c.id: c.name},
          ),
        EntryField(
          'description',
          'Descripción del trabajo',
          value: quote?.description ?? '',
          lines: 2,
        ),
        EntryField(
          'valid',
          'Vigente hasta (dd/mm/aaaa)',
          value: dateText(
            quote?.validUntil ??
                DateTime.now().toUtc().add(const Duration(days: 15)),
          ),
        ),
        EntryField(
          'conditions',
          'Condiciones',
          value: quote?.conditions ?? '',
          lines: 3,
          required: false,
        ),
      ],
      onSave: (v) async {
        final items = [
          for (final l in lines)
            QuoteLineInput(
              productId: l.productId,
              description: l.description,
              unit: l.unit,
              quantity: l.quantity,
              unitPrice: l.price,
              directCost: l.cost,
            ),
        ];
        if (quote == null) {
          await repo.createQuote(
            customerId: v['customer']!,
            description: v['description']!,
            items: items,
            validUntil: dateInput(v['valid']!),
            conditions: v['conditions']!,
            operationId: id,
          );
        } else {
          await repo.updateQuote(
            quote.id,
            description: v['description']!,
            items: items,
            validUntil: dateInput(v['valid']!),
            conditions: v['conditions']!,
          );
        }
      },
    );
  }

  Future<void> quoteStatus(Quote q) async {
    final transitions = quoteTransitions(q);
    if (transitions.isEmpty) return;
    await entryDialog(
      context,
      title: 'Estado de ${q.number}',
      fields: [
        EntryField(
          'status',
          'Estado',
          value: transitions.first.name,
          options: {for (final s in transitions) s.name: s.label},
        ),
      ],
      onSave: (v) =>
          repo.updateQuoteStatus(q.id, QuoteStatus.values.byName(v['status']!)),
    );
  }

  Future<void> convertQuote(Quote q) async {
    final id = 'convert-${q.id}';
    Sale? saved;
    await entryDialog(
      context,
      title: 'Convertir ${q.number} en venta',
      notice:
          'Se descontará inventario y se aplicarán los anticipos del trabajo vinculado. Total: ${cop(q.total)}.',
      fields: [
        const EntryField(
          'paid',
          'Cobro adicional ahora (COP)',
          value: '0',
          number: true,
        ),
        const EntryField(
          'received',
          'Dinero recibido (COP, opcional)',
          required: false,
          number: true,
        ),
        const EntryField(
          'method',
          'Medio de pago',
          value: 'Efectivo',
          options: paymentOptions,
        ),
        EntryField(
          'due',
          'Vencimiento si queda deuda (dd/mm/aaaa)',
          value: dateText(DateTime.now().toUtc().add(const Duration(days: 30))),
        ),
      ],
      onSave: (v) async {
        saved = await repo.convertQuote(
          q.id,
          paid: int.parse(v['paid']!),
          paymentMethod: v['method']!,
          received: int.tryParse(v['received']!),
          dueAt: dateInput(v['due']!),
          operationId: id,
        );
      },
      saveLabel: 'Confirmar venta',
    );
    if (saved != null && mounted) {
      await showCapcDocument(
        context,
        title: 'Comprobante ${saved!.number}',
        build: () => CapcDocuments.buildSale(saved!),
      );
    }
  }

  Future<void> quoteDocument(Quote q) => showCapcDocument(
    context,
    title: 'Cotización ${q.number}',
    build: () => CapcDocuments.buildTableDocument(
      title: 'Cotización ${q.number}',
      headers: ['Descripción', 'Cantidad', 'Precio unitario', 'Total'],
      rows: [
        for (final l in q.lines)
          [
            l.description,
            '${l.quantity} ${l.unit}',
            cop(l.unitPrice),
            cop(l.unitPrice * l.quantity),
          ],
      ],
      notes: [
        'Cliente: ${q.customerName}',
        'Descripción: ${q.description}',
        'Vigencia: ${localDate(q.validUntil)}',
        'Estado: ${q.status.label}',
        'Total: ${cop(q.total)}',
        'Condiciones: ${q.conditions}',
        'Una cotización no es un cobro ni una salida de inventario.',
      ],
    ),
  );
  Future<void> createWork() async {
    if (customers.isEmpty) {
      throw const CapcException(
        'Registra un cliente antes de recibir un trabajo.',
      );
    }
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Recibir trabajo',
      fields: [
        EntryField(
          'customer',
          'Cliente',
          options: {for (final c in customers) c.id: c.name},
        ),
        const EntryField('description', 'Descripción', lines: 3),
        EntryField('responsible', 'Responsable', value: repo.currentUser!.name),
        EntryField(
          'delivery',
          'Fecha de entrega (dd/mm/aaaa)',
          value: dateText(DateTime.now().toUtc().add(const Duration(days: 1))),
        ),
        EntryField(
          'quote',
          'Cotización vinculada',
          value: '',
          required: false,
          options: {
            '': 'Sin cotización',
            for (final q in quotes.where(
              (q) =>
                  q.status != QuoteStatus.converted &&
                  q.status != QuoteStatus.rejected &&
                  q.status != QuoteStatus.expired &&
                  !works.any((w) => w.quoteId == q.id),
            ))
              q.id: '${q.number} · ${q.customerName}',
          },
        ),
      ],
      onSave: (v) async {
        await repo.createWorkOrder(
          customerId: v['customer']!,
          description: v['description']!,
          responsible: v['responsible']!,
          deliveryAt: dateInput(v['delivery']!),
          quoteId: v['quote']!.isEmpty ? null : v['quote'],
          operationId: id,
        );
      },
    );
  }

  Future<void> workStatus(WorkOrder w) async {
    await entryDialog(
      context,
      title: 'Actualizar ${w.number}',
      fields: [
        EntryField(
          'status',
          'Estado',
          value: w.status.name,
          options: {
            for (final s in WorkStatus.values.where(
              (s) =>
                  (s == w.status || s.index == w.status.index + 1) &&
                  (s != WorkStatus.delivered || w.unappliedAdvances == 0),
            ))
              s.name: s.label,
          },
        ),
        EntryField('responsible', 'Responsable', value: w.responsible),
        EntryField(
          'delivery',
          'Entrega (dd/mm/aaaa)',
          value: dateText(w.deliveryAt),
        ),
      ],
      onSave: (v) => repo.updateWorkOrder(
        w.id,
        status: WorkStatus.values.byName(v['status']!),
        responsible: v['responsible']!,
        deliveryAt: dateInput(v['delivery']!),
      ),
    );
  }

  Future<void> advance(WorkOrder w) async {
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Anticipo a ${w.number}',
      notice:
          'El anticipo se registrará como cobro y se aplicará una sola vez a la venta correspondiente. Si el trabajo tiene cotización, acéptala antes de recibir el anticipo.',
      fields: [
        const EntryField('amount', 'Importe del anticipo (COP)', number: true),
        const EntryField(
          'received',
          'Dinero recibido (COP, opcional)',
          number: true,
          required: false,
        ),
        const EntryField(
          'method',
          'Medio de pago',
          value: 'Efectivo',
          options: paymentOptions,
        ),
      ],
      onSave: (v) async {
        await repo.addWorkAdvance(
          w.id,
          int.parse(v['amount']!),
          v['method']!,
          received: int.tryParse(v['received']!),
          operationId: id,
        );
      },
    );
  }

  Future<void> advanceHistory(WorkOrder w) async {
    final payments = await repo.listWorkAdvances(workId: w.id);
    if (!mounted) return;
    await showCapcDocument(
      context,
      title: 'Anticipos ${w.number}',
      build: () => CapcDocuments.buildTableDocument(
        title: 'Anticipos ${w.number} · ${w.customerName}',
        headers: ['Fecha Bogotá', 'Método', 'Importe'],
        rows: [
          for (final p in payments)
            [localDate(p.createdAt), p.method, cop(p.amount)],
        ],
        notes: [
          'Total anticipado: ${cop(w.advancesTotal)}',
          'Pendiente de aplicar: ${cop(w.unappliedAdvances)}',
        ],
      ),
    );
  }

  Future<void> applyAdvance(WorkOrder w) async {
    final requiredSale = w.saleId ?? workQuote(w)?.saleId;
    final sales = (await repo.listSales())
        .where(
          (s) =>
              s.customerId == w.customerId &&
              !s.cancelled &&
              s.balance >= w.unappliedAdvances &&
              (requiredSale == null || s.id == requiredSale),
        )
        .toList();
    if (!mounted) return;
    if (sales.isEmpty) {
      throw const CapcException(
        'No hay una venta pendiente compatible con este trabajo. Registra la venta con saldo suficiente para aplicar todos los anticipos.',
      );
    }
    final id = const Uuid().v4();
    await entryDialog(
      context,
      title: 'Aplicar anticipos de ${w.number}',
      notice:
          'Se aplicará el saldo disponible a la venta seleccionada sin registrar un cobro adicional.',
      fields: [
        EntryField(
          'sale',
          'Venta del cliente',
          options: {
            for (final s in sales)
              s.id: '${s.number} · saldo ${cop(s.balance)}',
          },
        ),
      ],
      onSave: (v) => repo.applyWorkAdvances(w.id, v['sale']!, operationId: id),
    );
  }

  List<Widget> userPage() => [
    if (owner)
      DataCard(
        title: 'Usuarios locales',
        subtitle:
            'Propietario: controla usuarios y restauración. Administrador: gestiona inventario y operaciones. Cajero: atiende ventas y caja.',
        actions: [
          button(
            'Crear usuario',
            Icons.person_add_alt,
            () => userForm(),
            primary: true,
          ),
        ],
      ),
    for (final u in users.where((u) => matches('${u.name} ${u.username}')))
      DataCard(
        title: u.name,
        subtitle:
            '${u.username} · ${roleText(u.role)} · ${u.active ? 'Activo' : 'Inactivo'}',
        actions: [
          button('Editar usuario', Icons.edit_outlined, () => userForm(u)),
        ],
      ),
    DataCard(
      title: 'Auditoría',
      subtitle:
          'Operaciones registradas automáticamente con usuario y fecha. Se muestran las primeras 200 coincidencias; el PDF incluye todo el historial.',
      actions: [
        button(
          'Guardar / imprimir auditoría',
          Icons.description_outlined,
          () => showCapcDocument(
            context,
            title: 'Auditoría',
            build: () => CapcDocuments.buildTableDocument(
              title: 'Auditoría local',
              headers: ['Fecha Bogotá', 'Acción', 'Responsable', 'Detalle'],
              rows: [
                for (final a in audits)
                  [
                    localDate(a.createdAt),
                    operationLabel(a.action),
                    a.actorName,
                    auditDescription(a.details),
                  ],
              ],
            ),
          ),
        ),
      ],
    ),
    for (final a
        in audits
            .where((a) => matches('${a.action} ${a.actorName} ${a.details}'))
            .take(200))
      DataCard(
        title: operationLabel(a.action),
        subtitle: '${localDate(a.createdAt)} · ${a.actorName}',
        children: [SelectableText(auditDescription(a.details))],
      ),
  ];
  String roleText(UserRole r) => switch (r) {
    UserRole.owner => 'Propietario',
    UserRole.admin => 'Administrador',
    UserRole.cashier => 'Cajero',
  };
  Future<void> userForm([LocalUser? u]) async {
    await entryDialog(
      context,
      title: u == null ? 'Crear usuario' : 'Editar usuario',
      fields: [
        EntryField('name', 'Nombre', value: u?.name ?? ''),
        EntryField('username', 'Usuario', value: u?.username ?? ''),
        EntryField(
          'role',
          'Rol',
          value: u?.role.name ?? 'cashier',
          options: {for (final r in UserRole.values) r.name: roleText(r)},
        ),
        EntryField(
          'password',
          u == null
              ? 'Contraseña (mínimo 10 caracteres)'
              : 'Nueva contraseña (vacío para conservar)',
          required: u == null,
          secret: true,
        ),
        EntryField(
          'active',
          'Estado',
          value: u?.active == false ? 'no' : 'yes',
          options: const {'yes': 'Activo', 'no': 'Inactivo'},
        ),
      ],
      onSave: (v) async {
        await repo.saveUser(
          id: u?.id,
          name: v['name']!,
          username: v['username']!,
          role: UserRole.values.byName(v['role']!),
          password: v['password']!.isEmpty ? null : v['password'],
          active: v['active'] == 'yes',
        );
      },
    );
  }
}

class ManagementReports extends StatefulWidget {
  const ManagementReports({
    super.key,
    required this.repository,
    required this.from,
    required this.to,
  });
  final CapcRepository repository;
  final DateTime from, to;

  @override
  State<ManagementReports> createState() => _ManagementReportsState();
}

class _ManagementReportsState extends State<ManagementReports> {
  CapcRepository get repository => widget.repository;
  DateTime get from => widget.from;
  DateTime get to => widget.to;
  bool _busy = false;
  static const _reports = [
    'Ventas y utilidad',
    'Productos más vendidos',
    'Cobros',
    'Compras y proveedores',
    'Cuentas por pagar',
    'Gastos',
    'Gastos y flujo de caja',
    'Caja',
    'Inventario',
    'Cartera',
  ];
  bool within(DateTime value) {
    final d = value.toUtc().subtract(const Duration(hours: 5));
    final day = DateTime(d.year, d.month, d.day);
    return !day.isBefore(DateTime(from.year, from.month, from.day)) &&
        !day.isAfter(DateTime(to.year, to.month, to.day));
  }

  @override
  Widget build(BuildContext context) => DataCard(
    title: 'Reportes completos',
    subtitle:
        'Período seleccionado en Bogotá. Los saldos de cartera e inventario corresponden al estado actual.',
    actions: [
      for (final name in _reports)
        OutlinedButton.icon(
          onPressed: _busy ? null : () => report(context, name),
          icon: const Icon(Icons.description_outlined),
          label: Text(name),
        ),
      PopupMenuButton<String>(
        enabled: !_busy,
        tooltip: 'Exportar reporte a Excel',
        onSelected: (name) => report(context, name, excel: true),
        itemBuilder: (_) => [
          for (final name in _reports)
            PopupMenuItem(value: name, child: Text(name)),
        ],
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.table_view_outlined),
              SizedBox(width: 8),
              Text('Exportar Excel'),
              Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    ],
    children: [if (_busy) const LinearProgressIndicator()],
  );
  Future<void> report(
    BuildContext context,
    String name, {
    bool excel = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final sales = await repository.listSales();
      final payments = await repository.listPayments();
      List<String> headers = [];
      List<List<String>> rows = [];
      List<List<Object?>>? excelRows;
      final notes = <String>[
        'Período: ${dateText(DateTime.utc(from.year, from.month, from.day, 12))} al ${dateText(DateTime.utc(to.year, to.month, to.day, 12))}. Hora de Bogotá.',
      ];
      if (name == 'Ventas y utilidad' || name == 'Productos más vendidos') {
        final report = SalesPeriodReport(
          sales: sales,
          payments: payments,
          returns: await repository.listSaleReturns(),
          from: from,
          to: to,
        );
        headers = name == 'Ventas y utilidad'
            ? ['Documento', 'Fecha Bogotá', 'Operación', 'Importe', 'Costo']
            : ['Producto / servicio', 'Unidades netas', 'Venta neta'];
        rows = name == 'Ventas y utilidad'
            ? report.salesRows
            : report.bestSellerRows;
        notes.addAll(report.notes);
        if (name == 'Productos más vendidos') {
          notes.add(
            'Las unidades netas pueden ser negativas si se devuelven ventas de un período anterior.',
          );
        }
      } else if (name == 'Cobros') {
        final numbers = {for (final sale in sales) sale.id: sale.number};
        headers = ['Fecha', 'Venta / movimiento', 'Medio', 'Importe aplicado'];
        rows = [
          for (final p in payments.where((p) => within(p.createdAt)))
            [
              localDate(p.createdAt),
              '${numbers[p.saleId] ?? p.saleId} · ${p.kind}',
              p.method,
              cop(p.amount),
            ],
        ];
        notes.add(
          'Cobros de ventas y abonos por su fecha. Los anticipos y reintegros se consultan en flujo de caja.',
        );
      } else if (name == 'Compras y proveedores' ||
          name == 'Cuentas por pagar') {
        final purchases = await repository.listPurchases();
        headers = ['Compra / proveedor', 'Fecha', 'Total', 'Pagado', 'Saldo'];
        rows = [
          for (final p in purchases.where(
            (p) => name == 'Cuentas por pagar'
                ? p.balance > 0
                : within(p.createdAt),
          ))
            [
              '${p.number} · ${p.supplierName}',
              localDate(p.createdAt),
              cop(p.total),
              cop(p.paid),
              cop(p.balance),
            ],
        ];
        if (name == 'Cuentas por pagar') {
          notes.add(
            'Cuentas por pagar actuales de todas las fechas; los pagos posteriores modifican este saldo.',
          );
        }
      } else if (name == 'Gastos y flujo de caja' || name == 'Gastos') {
        final movements = (await repository.listCashMovements())
            .where(
              (m) =>
                  within(m.createdAt) &&
                  (name != 'Gastos' || m.kind == 'expense'),
            )
            .toList();
        headers = ['Fecha', 'Concepto', 'Medio', 'Flujo neto', 'Responsable'];
        rows = [
          for (final m in movements)
            [
              localDate(m.createdAt),
              '${operationLabel(m.kind)} · ${m.reason}',
              m.method,
              cop(m.amount),
              m.actorName,
            ],
        ];
        notes.add(
          'Movimiento neto del período: ${cop(movements.fold(0, (sum, m) => sum + m.amount))}. Incluye cobros, anticipos, reintegros, gastos y pagos a proveedores. Las ventas a crédito no son entrada de dinero.',
        );
      } else if (name == 'Caja') {
        final sessions = await repository.listCashSessions();
        headers = [
          'Apertura Bogotá',
          'Cierre Bogotá',
          'Esperado',
          'Contado',
          'Diferencia',
        ];
        rows = [
          for (final s in sessions.where(
            (s) => within(s.closedAt ?? s.openedAt),
          ))
            [
              localDate(s.openedAt),
              s.closedAt == null ? 'Abierta' : localDate(s.closedAt),
              cop(s.expectedAmount),
              s.countedAmount == null ? 'Pendiente' : cop(s.countedAmount!),
              s.difference == null ? 'Pendiente' : cop(s.difference!),
            ],
        ];
        notes.add(
          'Sesiones incluidas por fecha de cierre; las abiertas se incluyen por fecha de apertura.',
        );
      } else if (name == 'Inventario') {
        final products = await repository.listProducts();
        headers = [
          'Código / producto',
          'Categoría',
          'Existencia',
          'Mínimo',
          'Valor inventario',
        ];
        rows = [
          for (final p in products.where((p) => !p.isService))
            [
              '${p.code} · ${p.name}',
              p.category,
              '${p.stock} ${p.unit}',
              '${p.minimumStock}',
              p.costKnown
                  ? SalesPeriodReport.moneyMicros(p.inventoryValueMicros)
                  : 'Costo desconocido',
            ],
        ];
        notes.add(
          'Estado actual del inventario; no reconstruye existencias históricas.',
        );
        if (excel) {
          headers = [
            'Código',
            'Producto',
            'Categoría',
            'Unidad',
            'Existencia',
            'Mínimo',
            'Valor inventario COP',
          ];
          excelRows = [
            for (final p in products.where((p) => !p.isService))
              [
                p.code,
                p.name,
                p.category,
                p.unit,
                p.stock,
                p.minimumStock,
                p.costKnown
                    ? p.inventoryValueMicros / 1000000
                    : 'Costo desconocido',
              ],
          ];
        }
      } else {
        headers = ['Cliente', 'Venta', 'Vence', 'Saldo actual'];
        rows = [
          for (final s in sales.where((s) => s.balance > 0))
            [s.customerName, s.number, localDate(s.dueAt), cop(s.balance)],
        ];
        notes.add(
          'Cartera actual de todas las fechas; los abonos posteriores modifican este saldo.',
        );
      }
      if (!context.mounted) return;
      if (excel) {
        await saveTableExcel(
          context,
          title: name,
          headers: headers,
          rows: excelRows ?? reportExcelRows(name, rows),
          notes: notes,
        );
        return;
      }
      await showCapcDocument(
        context,
        title: name,
        build: () => CapcDocuments.buildTableDocument(
          title: name,
          headers: headers,
          rows: rows,
          notes: notes,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
