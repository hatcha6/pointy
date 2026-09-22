/// The things a practice shop owns.
///
/// Plain mutable data with no behaviour: every rule that moves them lives in
/// [SandboxShop], so there is exactly one place to look when a lesson's numbers
/// disagree with the screen.
library;

class SandboxVariant {
  SandboxVariant({
    required this.id,
    required this.name,
    required this.sku,
    required this.barcode,
    required this.unitPrice,
    required this.stock,
    this.isDefault = true,
    List<String>? extraBarcodes,
  }) : extraBarcodes = extraBarcodes ?? <String>[];

  final int id;
  String name;
  String sku;
  String barcode;
  double unitPrice;
  bool isDefault;

  /// Packaging barcodes beyond the unit's own — the carton's EAN, the
  /// six-pack's. One product, several codes on several boxes, all scanning to
  /// the same thing.
  final List<String> extraBarcodes;

  /// Mutable: this is the number a lesson is teaching the learner to move.
  double stock;

  /// Every code that resolves to this variant.
  List<String> get allBarcodes => [
    if (barcode.isNotEmpty) barcode,
    ...extraBarcodes,
  ];
}

class SandboxProduct {
  SandboxProduct({
    required this.id,
    required this.name,
    required this.variants,
    this.unit = 'piece',
    this.categoryIds = const [],
    this.isService = false,
    this.isPrepared = false,
  });

  final int id;
  String name;
  String unit;
  List<int> categoryIds;
  bool isService;
  bool isPrepared;
  final List<SandboxVariant> variants;

  SandboxVariant get defaultVariant =>
      variants.firstWhere((v) => v.isDefault, orElse: () => variants.first);

  double get quantityOnHand =>
      variants.fold<double>(0, (sum, variant) => sum + variant.stock);
}

class SandboxCategory {
  const SandboxCategory({required this.id, required this.name});

  final int id;
  final String name;
}

/// A customer or a supplier. One class because the practice shop treats them
/// symmetrically — a balance and a name — and a learner meets them as the same
/// idea seen from two sides.
class SandboxContact {
  SandboxContact({
    required this.id,
    required this.name,
    required this.isSupplier,
    this.phone = '',
    this.balance = 0,
  });

  final int id;
  String name;
  String phone;
  final bool isSupplier;

  /// Customers: what they owe the shop. Suppliers: what the shop owes them.
  double balance;
}

class SandboxPayment {
  const SandboxPayment({required this.method, required this.amount});

  final String method;
  final double amount;
}

class SandboxOrderLine {
  SandboxOrderLine({
    required this.variantId,
    required this.sku,
    required this.productName,
    required this.variantName,
    required this.quantity,
    required this.unitPrice,
  });

  final int variantId;
  final String sku;
  final String productName;
  final String variantName;
  final double quantity;
  final double unitPrice;

  /// How much of this line has come back. Lessons about returns assert on it.
  double returnedQuantity = 0;

  /// This line's share of whatever came off the invoice. The practice shop puts
  /// a discount on the lines for the same reason the real one does: a returned
  /// line is credited what it sold for, and a trainee who refunds a haggled
  /// sale should get back the money the customer actually paid.
  double discountTotal = 0;

  double get subtotal => quantity * unitPrice;

  double get total => subtotal - discountTotal;
}

class SandboxOrder {
  SandboxOrder({
    required this.id,
    required this.receiptNumber,
    required this.lines,
    required this.payments,
    required this.saleType,
    required this.createdAt,
    required this.sessionId,
    required this.sessionNumber,
    required this.cashierId,
    required this.cashierName,
    this.customerId,
    this.customerName = '',
  });

  final int id;
  final String receiptNumber;
  final List<SandboxOrderLine> lines;
  final List<SandboxPayment> payments;
  final String saleType;
  final DateTime createdAt;
  final int? sessionId;
  final String sessionNumber;
  final int cashierId;
  final String cashierName;
  final int? customerId;
  final String customerName;

  /// The discount the cashier typed for this sale. Recorded for the receipt and
  /// the invoice screen; the money itself lives on the lines.
  double extraDiscountAmount = 0;

  /// What the goods are worth before anything comes off.
  double get subtotal =>
      lines.fold<double>(0, (sum, line) => sum + line.subtotal);

  /// Everything that came off, summed from the lines — exactly how the real
  /// ``Order.recalculate`` reaches the same figure.
  double get discountTotal =>
      lines.fold<double>(0, (sum, line) => sum + line.discountTotal);

  double get total => lines.fold<double>(0, (sum, line) => sum + line.total);

  double get paid =>
      payments.fold<double>(0, (sum, payment) => sum + payment.amount);

  double get balanceDue => total - paid;

  double get cashPaid => paidBy('cash');

  double paidBy(String method) => payments
      .where((payment) => payment.method == method)
      .fold<double>(0, (sum, payment) => sum + payment.amount);
}

class SandboxRegisterSession {
  SandboxRegisterSession({
    required this.id,
    required this.sessionNumber,
    required this.openingCash,
    required this.ownerName,
    required this.openedAt,
  });

  final int id;
  final String sessionNumber;
  final double openingCash;
  final String ownerName;
  final DateTime openedAt;

  double cashSalesTotal = 0;
  double payInTotal = 0;
  double payOutTotal = 0;
  double cashRefundTotal = 0;
  String status = 'open';
  double? closingCash;
  DateTime? closedAt;

  double get expectedCash =>
      openingCash + cashSalesTotal + payInTotal - payOutTotal - cashRefundTotal;
}

class SandboxPurchaseOrderLine {
  SandboxPurchaseOrderLine({
    required this.variantId,
    required this.sku,
    required this.productName,
    required this.quantity,
    required this.unitCost,
  });

  final int variantId;
  final String sku;
  final String productName;
  double quantity;
  double unitCost;
  double receivedQuantity = 0;

  double get total => quantity * unitCost;
}

class SandboxPurchaseOrder {
  SandboxPurchaseOrder({
    required this.id,
    required this.reference,
    required this.supplierId,
    required this.supplierName,
    required this.lines,
    required this.createdAt,
    this.status = 'draft',
  });

  final int id;
  final String reference;
  final int supplierId;
  final String supplierName;
  final List<SandboxPurchaseOrderLine> lines;
  final DateTime createdAt;

  /// draft → submitted → partially_received → received. A lesson asserts the
  /// word, because the word is what the learner sees on the badge.
  String status;
  double paidTotal = 0;

  double get total => lines.fold<double>(0, (sum, line) => sum + line.total);

  double get balanceDue => total - paidTotal;

  bool get isFullyReceived =>
      lines.every((line) => line.receivedQuantity >= line.quantity);

  bool get isPartiallyReceived =>
      !isFullyReceived && lines.any((line) => line.receivedQuantity > 0);
}
