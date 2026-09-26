/// Immutable local purchasing, quotation and work-order documents.
class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    this.phone = '',
    this.document = '',
    this.address = '',
  });
  final String id;
  final String name;
  final String phone;
  final String document;
  final String address;
}

class PurchaseItemInput {
  const PurchaseItemInput({
    required this.productId,
    required this.quantity,
    required this.totalCost,
  });
  final String productId;
  final int quantity;

  /// Exact cost of the entire lot, in whole Colombian pesos.
  final int totalCost;
}

class PurchaseLine {
  const PurchaseLine({
    required this.productId,
    required this.code,
    required this.name,
    required this.unit,
    required this.quantity,
    required this.totalCost,
  });
  final String productId;
  final String code;
  final String name;
  final String unit;
  final int quantity;
  final int totalCost;
  int get unitCostMicros => totalCost * 1000000 ~/ quantity;
}

class Purchase {
  Purchase({
    required this.id,
    required this.number,
    required this.supplierId,
    required this.supplierName,
    required this.reference,
    required this.createdAt,
    this.dueAt,
    required List<PurchaseLine> lines,
    required this.total,
    required this.paid,
    this.receivedAt,
    required this.operatorName,
  }) : lines = List.unmodifiable(lines);
  final String id;
  final String number;
  final String supplierId;
  final String supplierName;
  final String reference;
  final DateTime createdAt;
  final DateTime? dueAt;
  final List<PurchaseLine> lines;
  final int total;
  final int paid;
  final DateTime? receivedAt;
  final String operatorName;
  bool get received => receivedAt != null;
  int get balance => total - paid;
  String get status => balance == 0
      ? 'Pagada'
      : paid == 0
      ? 'Debe'
      : 'Abono parcial';
}

class PurchasePayment {
  const PurchasePayment({
    required this.id,
    required this.purchaseId,
    required this.amount,
    required this.method,
    required this.createdAt,
    required this.operatorName,
  });
  final String id;
  final String purchaseId;
  final int amount;
  final String method;
  final DateTime createdAt;
  final String operatorName;
}

enum QuoteStatus {
  draft('Borrador'),
  sent('Enviada'),
  accepted('Aceptada'),
  rejected('Rechazada'),
  expired('Vencida'),
  converted('Convertida');

  const QuoteStatus(this.label);
  final String label;
}

class QuoteLineInput {
  const QuoteLineInput({
    this.productId,
    required this.description,
    this.unit = 'Unidad',
    required this.quantity,
    required this.unitPrice,
    this.directCost,
  });
  final String? productId;
  final String description;
  final String unit;
  final int quantity;
  final int unitPrice;

  /// Unit direct cost for a custom job; null means cost not yet known.
  final int? directCost;
}

class QuoteLine {
  const QuoteLine({
    this.productId,
    required this.code,
    required this.description,
    required this.unit,
    required this.quantity,
    required this.unitPrice,
    this.directCost,
  });
  final String? productId;
  final String code;
  final String description;
  final String unit;
  final int quantity;
  final int unitPrice;
  final int? directCost;
  int get total => quantity * unitPrice;
}

class Quote {
  Quote({
    required this.id,
    required this.number,
    required this.customerId,
    required this.customerName,
    required this.description,
    required this.createdAt,
    required this.validUntil,
    required this.conditions,
    required this.status,
    required List<QuoteLine> lines,
    required this.total,
    this.saleId,
    required this.operatorName,
  }) : lines = List.unmodifiable(lines);
  final String id;
  final String number;
  final String customerId;
  final String customerName;
  final String description;
  final DateTime createdAt;
  final DateTime validUntil;
  final String conditions;
  final QuoteStatus status;
  final List<QuoteLine> lines;
  final int total;
  final String? saleId;
  final String operatorName;
  bool get isExpired => DateTime.now().toUtc().isAfter(validUntil);
}

enum WorkStatus {
  received('Recibido'),
  inProgress('En proceso'),
  ready('Listo'),
  delivered('Entregado');

  const WorkStatus(this.label);
  final String label;
}

class WorkOrder {
  const WorkOrder({
    required this.id,
    required this.number,
    required this.customerId,
    required this.customerName,
    required this.description,
    required this.createdAt,
    required this.status,
    required this.responsible,
    required this.deliveryAt,
    this.quoteId,
    this.saleId,
    required this.advancesTotal,
    required this.unappliedAdvances,
  });
  final String id;
  final String number;
  final String customerId;
  final String customerName;
  final String description;
  final DateTime createdAt;
  final WorkStatus status;
  final String responsible;
  final DateTime deliveryAt;
  final String? quoteId;
  final String? saleId;
  final int advancesTotal;
  final int unappliedAdvances;
}

class WorkAdvance {
  const WorkAdvance({
    required this.id,
    required this.workId,
    required this.amount,
    required this.received,
    required this.method,
    required this.createdAt,
    required this.operatorName,
    this.saleId,
    this.appliedAt,
  });
  final String id;
  final String workId;
  final int amount;
  final int received;
  final String method;
  final DateTime createdAt;
  final String operatorName;
  final String? saleId;
  final DateTime? appliedAt;
  int get change => received - amount;
  bool get applied => appliedAt != null;
}
