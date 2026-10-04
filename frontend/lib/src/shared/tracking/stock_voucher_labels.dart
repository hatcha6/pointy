import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// What moved a unit or a lot, as the shop says it — one word per ledger
/// voucher type. The server's own codes (`purchase_receipt`) were printed as
/// they came, which put English on the page a warranty claim is answered from.
///
/// A type this client does not know yet still reads as a stock movement rather
/// than as its code.
String stockVoucherLabel(AppLocalizations l10n, String voucherType) {
  return switch (voucherType) {
    'sale' => l10n.stockVoucherSale,
    'sale_return' => l10n.stockVoucherSaleReturn,
    'purchase_receipt' => l10n.stockVoucherPurchaseReceipt,
    'purchase_return' => l10n.stockVoucherPurchaseReturn,
    'production' => l10n.stockVoucherProduction,
    'stock_count' => l10n.stockVoucherStockCount,
    'adjustment' => l10n.stockVoucherAdjustment,
    'opening' => l10n.stockVoucherOpening,
    'transfer' => l10n.stockVoucherTransfer,
    'transfer_receipt' => l10n.stockVoucherTransferReceipt,
    'consignment_cost' => l10n.stockVoucherConsignmentCost,
    'consignment_intake' => l10n.stockVoucherConsignmentIntake,
    'consignment_return' => l10n.stockVoucherConsignmentReturn,
    'refurbishment' => l10n.stockVoucherRefurbishment,
    _ => l10n.stockVoucherOther,
  };
}
