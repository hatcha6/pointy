class ShopSettings {
  const ShopSettings({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.lowStockThreshold,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final int lowStockThreshold;

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
      lowStockThreshold: (json['low_stock_threshold'] as num?)?.toInt() ?? 5,
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
    required this.lowStockThreshold,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final int lowStockThreshold;

  Map<String, Object?> toJson() {
    return {
      'shop_name': shopName,
      'receipt_header': receiptHeader,
      'receipt_footer': receiptFooter,
      'require_opening_cash': requireOpeningCash,
      'auto_print_receipts': autoPrintReceipts,
      'low_stock_threshold': lowStockThreshold,
    };
  }
}
