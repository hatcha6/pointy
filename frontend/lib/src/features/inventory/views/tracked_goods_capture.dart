import 'package:flutter/widgets.dart';

import '../../../data/models/receipt_capture.dart';
import '../../../data/models/tracking_mode.dart';
import '../../../shared/tracking/unit_intake_permissions.dart';
import 'batch_capture_sheet.dart';
import 'unit_capture_sheet.dart';

/// One line's tracked goods, as the capture sheets need to see them.
///
/// Quantities are BASE units: identifiers count articles, not packs, and the
/// server validates a capture against exactly that — a carton of twelve is
/// twelve lot units and twelve serials.
class TrackedGoodsCaptureRequest {
  const TrackedGoodsCaptureRequest({
    required this.mode,
    required this.productLabel,
    required this.lotQuantity,
    required this.unitCount,
    required this.baseUnitCost,
    this.existing,
    this.suggestedExpiry,
    this.expiryRequired = false,
    this.allowCaptureLater = false,
    this.allowSplitCosts = true,
    this.assetTypeId,
    this.identifierKind = '',
    this.permissions = UnitIntakePermissions.none,
  });

  final TrackingMode mode;
  final String productLabel;

  /// What the lots must add up to: the sound goods. Damaged goods are units
  /// but join no lot a customer could be sold from.
  final double lotQuantity;

  /// How many articles get a number — sound and damaged alike.
  final int unitCount;

  /// What one article cost, which each captured one is stamped with.
  final double baseUnitCost;
  final ReceiptLineCapture? existing;
  final DateTime? suggestedExpiry;

  /// The product's `expiry_required`: every lot must say when it goes off.
  final bool expiryRequired;
  final bool allowCaptureLater;
  final bool allowSplitCosts;
  final int? assetTypeId;
  final String identifierKind;
  final UnitIntakePermissions permissions;
}

/// Open the right capture sheets for a tracked line, in the order a receiver
/// actually works: the lot header once — it is printed once on the carton —
/// then the scan loop for each article beneath it, which names that lot above
/// its scan field.
///
/// The one implementation behind every screen that names stock as it comes
/// in: the purchase order (typed while the order is entered), the receiving
/// form, a supplier's replacement and the counter purchase. [lots] and [units]
/// let a screen that offers the two as separate buttons open just one.
///
/// Null when the receiver backed out of a sheet; nothing they typed in it is
/// kept, and the line's capture stays as it was.
Future<ReceiptLineCapture?> captureTrackedGoods(
  BuildContext context,
  TrackedGoodsCaptureRequest request, {
  bool lots = true,
  bool units = true,
}) async {
  final mode = request.mode;
  var batches = request.existing?.batches ?? const <ReceiptBatchCapture>[];
  if (lots && mode.tracksLots && request.lotQuantity > 0) {
    final captured = await showBatchCaptureSheet(
      context,
      productLabel: request.productLabel,
      expectedQuantity: request.lotQuantity,
      initial: batches,
      suggestedExpiry: request.suggestedExpiry,
      // A serialised pack's lot is one header over the whole scan loop.
      singleLot: mode.tracksUnits,
      expiryRequired: request.expiryRequired,
    );
    if (captured == null || !context.mounted) {
      return null;
    }
    batches = captured;
  }

  var scanned = request.existing?.units ?? const <ReceiptUnitCapture>[];
  if (units && mode.tracksUnits && request.unitCount > 0) {
    final captured = await showUnitCaptureSheet(
      context,
      productLabel: request.productLabel,
      expectedCount: request.unitCount,
      lineUnitCost: request.baseUnitCost,
      initial: scanned,
      allowCaptureLater: request.allowCaptureLater,
      allowSplitCosts: request.allowSplitCosts,
      assetTypeId: request.assetTypeId,
      identifierKind: request.identifierKind,
      lot: batches.isEmpty ? null : batches.first,
      canSetPrice: request.permissions.canSetPrice,
      canSetWarranty: request.permissions.canSetWarranty,
    );
    if (captured == null || !context.mounted) {
      return null;
    }
    scanned = captured;
  }
  return ReceiptLineCapture(units: scanned, batches: batches);
}

/// Keeps a line's one lot covering the whole line after its quantity or pack
/// changes. A split across several lots is left alone — which lot grew is not
/// something to guess — and the line then shows its lots as owed.
List<ReceiptBatchCapture> resizeSingleLot(
  List<ReceiptBatchCapture> batches,
  double baseQuantity,
) {
  if (batches.length != 1) {
    return batches;
  }
  return [batches.single.copyWith(quantity: baseQuantity)];
}
