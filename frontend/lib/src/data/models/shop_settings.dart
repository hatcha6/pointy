import 'dart:typed_data';

import 'attachment_summary.dart';

/// How the cost of goods sold is decided when the same product was bought at
/// more than one price.
///
/// Chosen during first-run setup and changeable afterwards only behind an
/// explicit confirmation: the method decides what every past sale's cost *was*,
/// so switching it re-labels history that has already been reported on.
enum InventoryValuationMethod {
  movingAverage('moving_average'),
  fifo('fifo'),
  lifo('lifo');

  const InventoryValuationMethod(this.wireValue);

  final String wireValue;

  static InventoryValuationMethod fromWire(Object? value) {
    final raw = value?.toString();
    for (final method in InventoryValuationMethod.values) {
      if (method.wireValue == raw) {
        return method;
      }
    }
    // An unknown value means a newer backend or a corrupted row; fall back to
    // the default rather than failing to load the settings screen at all.
    return InventoryValuationMethod.movingAverage;
  }
}

class ShopSettings {
  const ShopSettings({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.enableOnlineInvoices,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.allowOverselling,
    required this.preventSellingAtLoss,
    required this.lowStockThreshold,
    required this.cashierReturnWindowHours,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardPaymentReceipt,
    required this.trustedCardTerminalIds,
    required this.cardCommissionPercent,
    required this.transferCommissionPercent,
    this.requireCustomerForCredit = true,
    this.allowCashierCustomerAccess = true,
    this.warnLowStockBeforeSale = true,
    this.autoPrintKitchenTickets = false,
    this.enableRepairOperations = false,
    this.enableProductionOperations = false,
    this.enableKitchenOperations = false,
    this.enableJobTracking = false,
    this.posCashPurchaseLimit,
    this.inventoryValuationMethod = InventoryValuationMethod.movingAverage,
    this.currencyCode = 'LYD',
    this.currencySymbol = 'د.ل',
    this.logoAttachment,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool enableOnlineInvoices;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final bool autoPrintKitchenTickets;
  final bool allowOverselling;
  final bool preventSellingAtLoss;
  final int lowStockThreshold;
  final int cashierReturnWindowHours;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardPaymentReceipt;
  final List<String> trustedCardTerminalIds;
  final double cardCommissionPercent;
  final double transferCommissionPercent;

  /// When true a credit (آجل) or quotation (عرض سعر) sale must name a customer.
  final bool requireCustomerForCredit;
  final bool allowCashierCustomerAccess;

  /// When true the POS asks the cashier to confirm before completing a sale
  /// whose cart quantity exceeds the available stock. Turn it off (with
  /// overselling enabled) to skip that per-sale prompt.
  final bool warnLowStockBeforeSale;
  final bool enableRepairOperations;
  final bool enableProductionOperations;
  final bool enableKitchenOperations;
  final bool enableJobTracking;

  /// Per-purchase ceiling for POS cash purchases (drawer-paid POs from the
  /// sell screen). Null or 0 = no cap.
  final double? posCashPurchaseLimit;

  /// How stock is costed. See [InventoryValuationMethod].
  final InventoryValuationMethod inventoryValuationMethod;
  final String currencyCode;
  final String currencySymbol;
  final AttachmentSummary? logoAttachment;

  bool get hasPosCashPurchaseLimit =>
      posCashPurchaseLimit != null && posCashPurchaseLimit! > 0;

  factory ShopSettings.fromJson(Map<String, Object?> json) {
    final logoJson = json['logo_attachment'];
    return ShopSettings(
      shopName: json['shop_name']?.toString() ?? '',
      receiptHeader: json['receipt_header']?.toString() ?? '',
      receiptFooter: json['receipt_footer']?.toString() ?? '',
      enableOnlineInvoices: _boolFromJson(
        json['enable_online_invoices'],
        false,
      ),
      requireOpeningCash: json['require_opening_cash'] is bool
          ? json['require_opening_cash'] as bool
          : json['require_opening_cash']?.toString() != 'false',
      autoPrintReceipts: json['auto_print_receipts'] is bool
          ? json['auto_print_receipts'] as bool
          : json['auto_print_receipts']?.toString() == 'true',
      autoPrintKitchenTickets: _boolFromJson(
        json['auto_print_kitchen_tickets'],
        false,
      ),
      allowOverselling: json['allow_overselling'] is bool
          ? json['allow_overselling'] as bool
          : json['allow_overselling']?.toString() == 'true',
      preventSellingAtLoss: _boolFromJson(
        json['prevent_selling_at_loss'],
        true,
      ),
      lowStockThreshold: (json['low_stock_threshold'] as num?)?.toInt() ?? 5,
      cashierReturnWindowHours:
          (json['cashier_return_window_hours'] as num?)?.toInt() ?? 42,
      enableCashPayments: _boolFromJson(json['enable_cash_payments'], true),
      enableCardPayments: _boolFromJson(json['enable_card_payments'], true),
      enableTransferPayments: _boolFromJson(
        json['enable_transfer_payments'],
        true,
      ),
      requireCardPaymentReceipt: _boolFromJson(
        json['require_card_payment_receipt'],
        false,
      ),
      trustedCardTerminalIds: _stringListFromJson(
        json['trusted_card_terminal_ids'],
      ),
      cardCommissionPercent: _moneyFromJson(json['card_commission_percent'], 1),
      transferCommissionPercent: _moneyFromJson(
        json['transfer_commission_percent'],
        0,
      ),
      requireCustomerForCredit: _boolFromJson(
        json['require_customer_for_credit'],
        true,
      ),
      allowCashierCustomerAccess: _boolFromJson(
        json['allow_cashier_customer_access'],
        true,
      ),
      warnLowStockBeforeSale: _boolFromJson(
        json['warn_low_stock_before_sale'],
        true,
      ),
      enableRepairOperations: _boolFromJson(
        json['enable_repair_operations'],
        false,
      ),
      enableProductionOperations: _boolFromJson(
        json['enable_production_operations'],
        false,
      ),
      enableKitchenOperations: _boolFromJson(
        json['enable_kitchen_operations'],
        false,
      ),
      enableJobTracking: _boolFromJson(json['enable_job_tracking'], false),
      posCashPurchaseLimit: json['pos_cash_purchase_limit'] == null
          ? null
          : _moneyFromJson(json['pos_cash_purchase_limit'], 0),
      inventoryValuationMethod: InventoryValuationMethod.fromWire(
        json['inventory_valuation_method'],
      ),
      currencyCode: json['currency_code']?.toString() ?? 'LYD',
      currencySymbol: json['currency_symbol']?.toString() ?? 'د.ل',
      logoAttachment: logoJson is Map<String, Object?>
          ? AttachmentSummary.fromJson(logoJson)
          : null,
    );
  }
}

class ShopLogoUpload {
  const ShopLogoUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String filename;
  final Uint8List bytes;
  final String contentType;
}

class ShopSettingsDraft {
  const ShopSettingsDraft({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.enableOnlineInvoices,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.allowOverselling,
    required this.preventSellingAtLoss,
    required this.lowStockThreshold,
    required this.cashierReturnWindowHours,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardPaymentReceipt,
    required this.trustedCardTerminalIds,
    required this.cardCommissionPercent,
    required this.transferCommissionPercent,
    this.requireCustomerForCredit = true,
    this.allowCashierCustomerAccess = true,
    this.warnLowStockBeforeSale = true,
    this.autoPrintKitchenTickets = false,
    this.enableRepairOperations = false,
    this.enableProductionOperations = false,
    this.enableKitchenOperations = false,
    this.enableJobTracking = false,
    this.posCashPurchaseLimit,
    this.inventoryValuationMethod = InventoryValuationMethod.movingAverage,
    this.valuationMethodChangeAcknowledged = false,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool enableOnlineInvoices;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final bool autoPrintKitchenTickets;
  final bool allowOverselling;
  final bool preventSellingAtLoss;
  final int lowStockThreshold;
  final int cashierReturnWindowHours;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardPaymentReceipt;
  final List<String> trustedCardTerminalIds;
  final double cardCommissionPercent;
  final double transferCommissionPercent;
  final bool requireCustomerForCredit;
  final bool allowCashierCustomerAccess;
  final bool warnLowStockBeforeSale;
  final bool enableRepairOperations;
  final bool enableProductionOperations;
  final bool enableKitchenOperations;
  final bool enableJobTracking;
  final double? posCashPurchaseLimit;
  final InventoryValuationMethod inventoryValuationMethod;

  /// One-shot confirmation that the user has read the warning about changing
  /// the valuation method. Never stored — the backend refuses the change
  /// without it once stock has moved, and forgets it immediately after.
  final bool valuationMethodChangeAcknowledged;

  ShopSettingsDraft acknowledgingValuationMethodChange() {
    return copyWith(valuationMethodChangeAcknowledged: true);
  }

  ShopSettingsDraft copyWith({
    InventoryValuationMethod? inventoryValuationMethod,
    bool? valuationMethodChangeAcknowledged,
  }) {
    return ShopSettingsDraft(
      shopName: shopName,
      receiptHeader: receiptHeader,
      receiptFooter: receiptFooter,
      enableOnlineInvoices: enableOnlineInvoices,
      requireOpeningCash: requireOpeningCash,
      autoPrintReceipts: autoPrintReceipts,
      allowOverselling: allowOverselling,
      preventSellingAtLoss: preventSellingAtLoss,
      lowStockThreshold: lowStockThreshold,
      cashierReturnWindowHours: cashierReturnWindowHours,
      enableCashPayments: enableCashPayments,
      enableCardPayments: enableCardPayments,
      enableTransferPayments: enableTransferPayments,
      requireCardPaymentReceipt: requireCardPaymentReceipt,
      trustedCardTerminalIds: trustedCardTerminalIds,
      cardCommissionPercent: cardCommissionPercent,
      transferCommissionPercent: transferCommissionPercent,
      requireCustomerForCredit: requireCustomerForCredit,
      allowCashierCustomerAccess: allowCashierCustomerAccess,
      warnLowStockBeforeSale: warnLowStockBeforeSale,
      autoPrintKitchenTickets: autoPrintKitchenTickets,
      enableRepairOperations: enableRepairOperations,
      enableProductionOperations: enableProductionOperations,
      enableKitchenOperations: enableKitchenOperations,
      enableJobTracking: enableJobTracking,
      posCashPurchaseLimit: posCashPurchaseLimit,
      inventoryValuationMethod:
          inventoryValuationMethod ?? this.inventoryValuationMethod,
      valuationMethodChangeAcknowledged:
          valuationMethodChangeAcknowledged ??
          this.valuationMethodChangeAcknowledged,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'shop_name': shopName,
      'receipt_header': receiptHeader,
      'receipt_footer': receiptFooter,
      'enable_online_invoices': enableOnlineInvoices,
      'require_opening_cash': requireOpeningCash,
      'auto_print_receipts': autoPrintReceipts,
      'auto_print_kitchen_tickets': autoPrintKitchenTickets,
      'allow_overselling': allowOverselling,
      'prevent_selling_at_loss': preventSellingAtLoss,
      'low_stock_threshold': lowStockThreshold,
      'cashier_return_window_hours': cashierReturnWindowHours,
      'enable_cash_payments': enableCashPayments,
      'enable_card_payments': enableCardPayments,
      'enable_transfer_payments': enableTransferPayments,
      'require_card_payment_receipt': requireCardPaymentReceipt,
      'trusted_card_terminal_ids': trustedCardTerminalIds,
      'card_commission_percent': cardCommissionPercent.toStringAsFixed(2),
      'transfer_commission_percent': transferCommissionPercent.toStringAsFixed(
        2,
      ),
      'require_customer_for_credit': requireCustomerForCredit,
      'allow_cashier_customer_access': allowCashierCustomerAccess,
      'warn_low_stock_before_sale': warnLowStockBeforeSale,
      'enable_repair_operations': enableRepairOperations,
      'enable_production_operations': enableProductionOperations,
      'enable_kitchen_operations': enableKitchenOperations,
      'enable_job_tracking': enableJobTracking,
      'pos_cash_purchase_limit': posCashPurchaseLimit?.toStringAsFixed(2),
      'inventory_valuation_method': inventoryValuationMethod.wireValue,
      // Only sent when the user has actually confirmed, so an ordinary save
      // can never carry a stale acknowledgement.
      if (valuationMethodChangeAcknowledged)
        'valuation_method_change_acknowledged': true,
    };
  }
}

bool _boolFromJson(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }
  if (value == null) {
    return fallback;
  }
  return value.toString() == 'true';
}

double _moneyFromJson(Object? value, double fallback) {
  if (value == null) {
    return fallback;
  }
  return double.tryParse(value.toString()) ?? fallback;
}

List<String> _stringListFromJson(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  return value
      .map((item) => item?.toString().trim().toUpperCase() ?? '')
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
