import '../models/integration_card.dart';
import '../models/sale_order.dart';

/// Overlay the provider's just-received recharge answers onto [order] so a
/// printed receipt carries them inline.
///
/// A provider line (a top-up or a card) sells `pending`: the sale is recorded,
/// then the till performs the charge and the provider answers with the thing
/// sold — a card's PIN, a recharge's serial. That answer ([recharges]) is the
/// authoritative record of what was just bought; it is the same reply that
/// carries the PIN. Printing straight from it means the receipt shows the code
/// even when a re-read of the order has not caught up with the charge yet — the
/// gap that printed "لم يتم إصدار الكرت" on a card that was in fact handed over,
/// then left the code to be found later in the invoice.
///
/// Only a completed charge that came with a slip is overlaid, and only onto a
/// line that already sold a top-up: a refusal or an unknown outcome is left
/// exactly as the server recorded it, so the receipt stays honest about a card
/// that was never issued.
SaleOrder orderWithPerformedRecharges(
  SaleOrder order,
  List<IntegrationChargeResult> recharges,
) {
  final byLine = <int, IntegrationChargeResult>{
    for (final row in recharges)
      if (row.orderLine != null && row.isCharged && row.receipt.isNotEmpty)
        row.orderLine!: row,
  };
  if (byLine.isEmpty) return order;
  var changed = false;
  final lines = order.lines
      .map((line) {
        final row = byLine[line.id];
        final integration = line.integration;
        if (row == null || integration == null) return line;
        changed = true;
        return line.copyWith(
          integration: integration.copyWith(
            status: 'confirmed',
            kind: row.kind.isNotEmpty ? row.kind : null,
            providerReference: row.providerReference.isNotEmpty
                ? row.providerReference
                : null,
            receipt: row.receipt,
          ),
        );
      })
      .toList(growable: false);
  return changed ? order.copyWith(lines: lines) : order;
}
