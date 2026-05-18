import 'cart_line.dart';
import 'print_job.dart';
import 'printer_config.dart';

class SaleCheckoutDraft {
  const SaleCheckoutDraft({
    required this.lines,
    required this.amountReceived,
    this.paymentMethod = 'cash',
    this.invoicePrinterConfig,
  });

  final List<SaleCheckoutLineDraft> lines;
  final double amountReceived;
  final String paymentMethod;
  final PrinterConfig? invoicePrinterConfig;

  factory SaleCheckoutDraft.fromCart({
    required List<CartLine> cart,
    required double amountReceived,
    PrinterConfig? invoicePrinterConfig,
  }) {
    return SaleCheckoutDraft(
      lines: cart
          .map(
            (line) => SaleCheckoutLineDraft(
              productId: line.product.id,
              quantity: line.quantity,
            ),
          )
          .toList(growable: false),
      amountReceived: amountReceived,
      invoicePrinterConfig: invoicePrinterConfig,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
      'payment_method': paymentMethod,
      'amount_received': amountReceived.toStringAsFixed(2),
      if (invoicePrinterConfig != null)
        'print_invoice': {
          'agent_id': invoicePrinterConfig!.agentId,
          'printer_endpoint': invoicePrinterConfig!.endpoint.toJson(),
        },
    };
  }
}

class SaleCheckoutLineDraft {
  const SaleCheckoutLineDraft({
    required this.productId,
    required this.quantity,
  });

  final int productId;
  final int quantity;

  Map<String, Object?> toJson() {
    return {'product': productId, 'quantity': quantity};
  }
}

class SaleOrder {
  const SaleOrder({
    required this.id,
    required this.status,
    required this.lines,
    required this.subtotal,
    required this.total,
    this.receiptNumber,
    this.registerSession,
    this.registerSessionNumber,
    this.invoicePrintJob,
    this.canVoid = false,
    this.canReturn = false,
    this.requiresManagerAdjustment = false,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String? receiptNumber;
  final String status;
  final int? registerSession;
  final String? registerSessionNumber;
  final PrintJob? invoicePrintJob;
  final bool canVoid;
  final bool canReturn;
  final bool requiresManagerAdjustment;
  final List<SaleOrderLine> lines;
  final double subtotal;
  final double total;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory SaleOrder.fromJson(Map<String, Object?> json) {
    final linesJson = (json['lines'] as List<Object?>?) ?? const [];

    return SaleOrder(
      id: _intFromJson(json['id']),
      receiptNumber: json['receipt_number']?.toString(),
      status: json['status']?.toString() ?? '',
      registerSession: _nullableIntFromJson(json['register_session']),
      registerSessionNumber: json['register_session_number']?.toString(),
      invoicePrintJob: json['print_job'] is Map<String, Object?>
          ? PrintJob.fromJson(json['print_job'] as Map<String, Object?>)
          : null,
      canVoid: _boolFromJson(json['can_void']),
      canReturn: _boolFromJson(json['can_return']),
      requiresManagerAdjustment: _boolFromJson(
        json['requires_manager_adjustment'],
      ),
      lines: linesJson
          .whereType<Map<String, Object?>>()
          .map(SaleOrderLine.fromJson)
          .toList(growable: false),
      subtotal: _moneyFromJson(json['subtotal']),
      total: _moneyFromJson(json['total']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class SaleOrderLine {
  const SaleOrderLine({
    required this.id,
    required this.productId,
    required this.quantity,
    required this.returnedQuantity,
    required this.returnableQuantity,
    required this.unitPrice,
    required this.total,
    this.productName,
  });

  final int id;
  final int productId;
  final String? productName;
  final int quantity;
  final int returnedQuantity;
  final int returnableQuantity;
  final double unitPrice;
  final double total;

  factory SaleOrderLine.fromJson(Map<String, Object?> json) {
    return SaleOrderLine(
      id: _intFromJson(json['id']),
      productId: _productIdFromJson(json['product']),
      productName: json['product_name']?.toString(),
      quantity: _intFromJson(json['quantity']),
      returnedQuantity: _intFromJson(json['returned_quantity']),
      returnableQuantity: _intFromJson(json['returnable_quantity']),
      unitPrice: _moneyFromJson(json['unit_price']),
      total: _moneyFromJson(json['line_total'] ?? json['total']),
    );
  }
}

class SaleVoidDraft {
  const SaleVoidDraft({this.reason = ''});

  final String reason;

  Map<String, Object?> toJson() {
    return {'reason': reason};
  }
}

class SaleReturnDraft {
  const SaleReturnDraft({required this.lines, this.reason = ''});

  final List<SaleReturnLineDraft> lines;
  final String reason;

  Map<String, Object?> toJson() {
    return {
      'reason': reason,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
    };
  }
}

class SaleReturnLineDraft {
  const SaleReturnLineDraft({required this.lineId, required this.quantity});

  final int lineId;
  final int quantity;

  Map<String, Object?> toJson() {
    return {'line': lineId, 'quantity': quantity};
  }
}

int _productIdFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return _intFromJson(value['id']);
  }
  return _intFromJson(value);
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.parse((value ?? 0).toString());
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

double _moneyFromJson(Object? value) {
  return double.parse((value ?? 0).toString());
}

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
