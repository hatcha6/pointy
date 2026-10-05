import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_transfer.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/tracking/unit_pick_sheet.dart';

/// True when this transfer cannot leave until somebody names its articles.
bool transferNeedsUnitPicks(StockTransfer transfer) {
  return transfer.lines.any((line) => line.trackingMode.tracksUnits);
}

/// Which handsets are actually in the van (§6.5), on the shared picker.
///
/// Not auto-picked, and this is the one place a transfer differs from a sale.
/// The till may take the oldest handset off the shelf because the customer is
/// holding whichever one it hands them; a driver has already physically chosen
/// five, and a system that picked a different five would make the far end's
/// *«sent 5, arrived 4, missing 351…333»* reconciliation a lie about which
/// handset is gone.
///
/// Returns the picks keyed by transfer line, or null when dismissed.
Future<Map<int, TransferLinePick>?> pickTransferUnits(
  BuildContext context, {
  required StockTransfer transfer,
  required TrackedStockRepository repository,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final chosen = await showUnitPickSheet(
    context,
    title: l10n.transferPickUnitsTitle,
    message: l10n.transferPickUnitsBody,
    confirmLabel: l10n.transferSendAction,
    lines: transferUnitPickLines(transfer),
    loadUnits: transferUnitLoader(transfer, repository),
  );
  if (chosen == null) {
    return null;
  }
  return {
    for (final entry in chosen.entries)
      entry.key: TransferLinePick(unitIds: entry.value),
  };
}

/// One section per serialised line, asking for exactly its base quantity.
List<UnitPickLine> transferUnitPickLines(StockTransfer transfer) {
  return [
    for (final line in transfer.lines)
      if (line.trackingMode.tracksUnits)
        UnitPickLine(
          key: line.id,
          title: line.variantName,
          count: line.baseQuantity.round(),
          variantId: line.variantId,
        ),
  ];
}

/// The handsets on the shelf the van leaves from — not necessarily this
/// till's: "sellable here" offered the wrong shelf for any transfer sent from
/// another warehouse. Identified and in stock only; a placeholder has no
/// number for the far end to reconcile by.
UnitPickLoader transferUnitLoader(
  StockTransfer transfer,
  TrackedStockRepository repository,
) {
  return (int variantId, {String code = ''}) => repository.loadUnits(
    variantId: variantId,
    warehouseId: transfer.sourceId,
    status: StockUnitStatus.inStock,
    isIdentified: true,
    code: code,
  );
}
