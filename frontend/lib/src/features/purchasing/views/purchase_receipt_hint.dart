import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/tracking_mode.dart';

/// What the receiver will be asked for when a line's goods arrive. A lot of
/// paint is named but never dated, so only goods whose lots must expire say
/// so. Blank for goods counted rather than named.
String purchaseReceiptHint(
  AppLocalizations l10n,
  TrackingMode mode, {
  required bool expiryRequired,
}) {
  return switch (mode) {
    TrackingMode.serial => l10n.purchaseLineUnitsAtReceipt,
    TrackingMode.serialBatch =>
      expiryRequired
          ? l10n.purchaseLineSerialLotExpiryAtReceipt
          : l10n.purchaseLineSerialLotAtReceipt,
    TrackingMode.batch =>
      expiryRequired
          ? l10n.purchaseLineLotsAtReceipt
          : l10n.purchaseLineLotsNoExpiryAtReceipt,
    TrackingMode.quantity => '',
  };
}
