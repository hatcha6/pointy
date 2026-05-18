class ShopSettings {
  const ShopSettings({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.allowOverselling,
    required this.lowStockThreshold,
    required this.cashierReturnWindowHours,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final bool allowOverselling;
  final int lowStockThreshold;
  final int cashierReturnWindowHours;

  factory ShopSettings.fromJson(Map<String, Object?> json) {
    return ShopSettings(
      shopName: json['shop_name']?.toString() ?? '',
      receiptHeader: json['receipt_header']?.toString() ?? '',
      receiptFooter: json['receipt_footer']?.toString() ?? '',
      requireOpeningCash: json['require_opening_cash'] is bool
          ? json['require_opening_cash'] as bool
          : json['require_opening_cash']?.toString() != 'false',
      autoPrintReceipts: json['auto_print_receipts'] is bool
          ? json['auto_print_receipts'] as bool
          : json['auto_print_receipts']?.toString() == 'true',
      allowOverselling: json['allow_overselling'] is bool
          ? json['allow_overselling'] as bool
          : json['allow_overselling']?.toString() == 'true',
      lowStockThreshold: (json['low_stock_threshold'] as num?)?.toInt() ?? 5,
      cashierReturnWindowHours:
          (json['cashier_return_window_hours'] as num?)?.toInt() ?? 42,
    );
  }
}

class ShopSettingsDraft {
  const ShopSettingsDraft({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.allowOverselling,
    required this.lowStockThreshold,
    required this.cashierReturnWindowHours,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final bool allowOverselling;
  final int lowStockThreshold;
  final int cashierReturnWindowHours;

  Map<String, Object?> toJson() {
    return {
      'shop_name': shopName,
      'receipt_header': receiptHeader,
      'receipt_footer': receiptFooter,
      'require_opening_cash': requireOpeningCash,
      'auto_print_receipts': autoPrintReceipts,
      'allow_overselling': allowOverselling,
      'low_stock_threshold': lowStockThreshold,
      'cashier_return_window_hours': cashierReturnWindowHours,
    };
  }
}
