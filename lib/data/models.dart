export 'operations_models.dart';

/// A recoverable rule violation, suitable for display in Spanish.
class CapcException implements Exception {
  const CapcException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum UserRole { owner, admin, cashier }

enum Permission {
  read,
  manageCatalog,
  adjustStock,
  sell,
  setPrices,
  collect,
  manageCustomers,
  returns,
  managePurchases,
  manageQuotes,
  manageJobs,
  manageUsers,
  manageSettings,
  backup,
  restore,
  viewReports,
  manageCash,
  expense,
  viewAudit,
}

class LocalUser {
  const LocalUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    this.active = true,
  });
  final String id, name, username;
  final UserRole role;
  final bool active;
  String get roleLabel => switch (role) {
    UserRole.owner => 'Propietario',
    UserRole.admin => 'Administrador',
    UserRole.cashier => 'Cajero',
  };
  bool can(Permission permission) {
    if (!active) return false;
    if (role == UserRole.owner) return true;
    if (role == UserRole.admin) {
      return !{
        Permission.manageUsers,
        Permission.restore,
        Permission.manageSettings,
      }.contains(permission);
    }
    return {
      Permission.read,
      Permission.sell,
      Permission.collect,
      Permission.manageCustomers,
      Permission.manageCash,
      Permission.manageQuotes,
      Permission.manageJobs,
    }.contains(permission);
  }
}

class Product {
  const Product({
    required this.id,
    required this.code,
    required this.name,
    required this.unit,
    required this.isService,
    required this.purchasePrice,
    required this.salePrice,
    required this.stock,
    required this.minimumStock,
    this.category = '',
    this.inventoryValueMicros = 0,
    this.costKnown = true,
    this.costBasis = 'weighted',
  });
  final String id, code, name, unit, category, costBasis;
  final bool isService, costKnown;
  final int purchasePrice, salePrice, stock, minimumStock, inventoryValueMicros;
  int get averageCostMicros => !isService && stock > 0
      ? inventoryValueMicros ~/ stock
      : purchasePrice * 1000000;
  String get stockStatus => isService || stock > minimumStock
      ? 'Disponible'
      : stock == 0
      ? 'Agotado'
      : 'Solicitar material';

  /// Markup basis points: 2500 means a user-selected 25% over cost.
  int suggestedPrice(int markupBasisPoints) {
    if (markupBasisPoints < 0 || markupBasisPoints > 10000000) {
      throw const CapcException('El porcentaje sobre costo no es válido.');
    }
    if (!costKnown) throw const CapcException('Falta verificar el costo.');
    final denominator =
        BigInt.from((!isService && stock > 0 ? stock : 1)) *
        BigInt.from(10000000000);
    final numerator =
        BigInt.from(
          !isService && stock > 0
              ? inventoryValueMicros
              : purchasePrice * 1000000,
        ) *
        BigInt.from(10000 + markupBasisPoints);
    return ((numerator + denominator ~/ BigInt.two) ~/ denominator).toInt();
  }
}

class ServiceMaterial {
  const ServiceMaterial({required this.productId, required this.quantity});
  final String productId;
  final int quantity;
}

class Customer {
  const Customer({required this.id, required this.name, this.phone = ''});
  final String id, name, phone;
}

class CartLine {
  const CartLine({
    required this.productId,
    required this.quantity,
    this.unitPrice,
    this.name,
    this.code,
    this.unit,
  });
  final String productId;
  final int quantity;
  final int? unitPrice;
  final String? name, code, unit;
}

class CustomSaleItem {
  const CustomSaleItem({
    required this.description,
    required this.quantity,
    required this.unitPrice,
    this.unitCost,
    this.unit = 'Servicio',
  });
  final String description, unit;
  final int quantity, unitPrice;
  final int? unitCost;
}

class SaleLine {
  const SaleLine({
    required this.productId,
    required this.code,
    required this.name,
    required this.unit,
    required this.isService,
    required this.quantity,
    required this.unitPrice,
    required this.unitCost,
    this.id = '',
    int? costTotalMicros,
    this.costKnown = true,
    this.costBasis = 'declared',
    this.returnedQuantity = 0,
    this.recoveredCostMicros = 0,
  }) : _costTotalMicros = costTotalMicros;
  final String id, productId, code, name, unit, costBasis;
  final bool isService, costKnown;
  final int quantity,
      unitPrice,
      unitCost,
      returnedQuantity,
      recoveredCostMicros;
  final int? _costTotalMicros;
  int get costTotalMicros => _costTotalMicros ?? quantity * unitCost * 1000000;
  int get total => quantity * unitPrice;
  int get remainingQuantity => quantity - returnedQuantity;
}

class Sale {
  Sale({
    required this.id,
    required this.number,
    required this.createdAt,
    required List<SaleLine> lines,
    this.customerId,
    required this.customerName,
    required this.operatorName,
    required this.total,
    required this.paid,
    required this.paymentMethod,
    this.received = 0,
    this.change = 0,
    this.dueAt,
    this.returnedTotal = 0,
    this.refunded = 0,
    this.cancelled = false,
    this.prepaid = 0,
    this.sourceQuoteId,
  }) : lines = List.unmodifiable(lines);
  final String id, number, customerName, operatorName, paymentMethod;
  final String? customerId, sourceQuoteId;
  final DateTime createdAt;
  final DateTime? dueAt;
  final List<SaleLine> lines;
  final int total, paid, received, change, returnedTotal, refunded, prepaid;
  final bool cancelled;
  int get netTotal => total - returnedTotal;
  int get balance => netTotal - paid;
  bool get costKnown => lines.every((line) => line.costKnown);
  int get netCostMicros => lines.fold(
    0,
    (value, line) => value + line.costTotalMicros - line.recoveredCostMicros,
  );
  String get status => cancelled
      ? 'Anulada'
      : balance == 0
      ? 'Pagada'
      : paid == 0
      ? 'Debe'
      : 'Abono parcial';
}

class Payment {
  const Payment({
    required this.id,
    required this.saleId,
    required this.amount,
    required this.createdAt,
    required this.method,
    this.received = 0,
    this.change = 0,
    this.actorName = '',
    this.kind = 'Cobro',
  });
  final String id, saleId, method, actorName, kind;
  final int amount, received, change;
  final DateTime createdAt;
}

class SaleReturnItem {
  const SaleReturnItem({
    required this.saleLineId,
    required this.quantity,
    this.restock = true,
  });
  final String saleLineId;
  final int quantity;
  final bool restock;
}

class SaleReturnRecord {
  const SaleReturnRecord({
    required this.id,
    required this.saleId,
    required this.number,
    required this.createdAt,
    required this.amount,
    required this.refund,
    required this.method,
    required this.actorName,
    required this.reason,
    required this.costReversedMicros,
    this.cancelled = false,
    this.items = const [],
  });
  final String id, saleId, number, method, actorName, reason;
  final DateTime createdAt;
  final int amount, refund, costReversedMicros;
  final bool cancelled;
  final List<SaleReturnItem> items;
}

class StockMovement {
  const StockMovement({
    required this.id,
    required this.productId,
    required this.productName,
    required this.delta,
    required this.costMicros,
    required this.reason,
    required this.kind,
    required this.createdAt,
    required this.actorName,
    this.referenceId,
  });
  final String id, productId, productName, reason, kind, actorName;
  final String? referenceId;
  final int delta, costMicros;
  final DateTime createdAt;
}

class CashSession {
  const CashSession({
    required this.id,
    required this.openedAt,
    this.closedAt,
    required this.openingAmount,
    required this.expectedAmount,
    this.countedAmount,
    this.difference,
    required this.openedBy,
    this.closedBy,
    this.note = '',
  });
  final String id, openedBy, note;
  final String? closedBy;
  final DateTime openedAt;
  final DateTime? closedAt;
  final int openingAmount, expectedAmount;
  final int? countedAmount, difference;
  bool get isOpen => closedAt == null;
}

class CashMovement {
  const CashMovement({
    required this.id,
    required this.sessionId,
    required this.amount,
    required this.method,
    required this.kind,
    required this.reason,
    required this.createdAt,
    required this.actorName,
    this.referenceId,
  });
  final String id, sessionId, method, kind, reason, actorName;
  final String? referenceId;
  final int amount;
  final DateTime createdAt;
}

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.entityId,
    required this.actorName,
    required this.createdAt,
    required this.details,
  });
  final String id, action, entityId, actorName, details;
  final DateTime createdAt;
}
