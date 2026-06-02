import 'dart:typed_data';

import 'attachment_summary.dart';

class ShopSettings {
  const ShopSettings({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
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
    this.logoAttachment,
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
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
  final AttachmentSummary? logoAttachment;

  factory ShopSettings.fromJson(Map<String, Object?> json) {
    final logoJson = json['logo_attachment'];
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
  });

  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
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

  Map<String, Object?> toJson() {
    return {
      'shop_name': shopName,
      'receipt_header': receiptHeader,
      'receipt_footer': receiptFooter,
      'require_opening_cash': requireOpeningCash,
      'auto_print_receipts': autoPrintReceipts,
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
