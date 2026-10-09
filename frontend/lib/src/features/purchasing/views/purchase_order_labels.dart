import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/barcode_label.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/units.dart';
import '../../catalog/views/label_batch_print_sheet.dart';

/// The order's products as a label batch: one row per variant, its sticker
/// count already the number of pieces the order brought — or will bring, when
/// nothing has been received yet — so nobody walks product to product
/// remembering how many of each to print.
///
/// Counts are in pieces: a line bought by the carton of 12 asks for 12
/// stickers per carton. The same variant on two lines (two packagings) is one
/// row. Serial-tracked goods are listed but not printable here — a handset's
/// sticker is its own number, printed when it is received.
List<LabelBatchEntry> purchaseOrderLabelEntries({
  required List<PurchaseOrderLine> lines,
  required AppLocalizations l10n,
}) {
  final byVariant = <int, List<PurchaseOrderLine>>{};
  for (final line in lines) {
    byVariant.putIfAbsent(line.variantId, () => []).add(line);
  }
  return [for (final group in byVariant.values) _entryFor(group, l10n)];
}

LabelBatchEntry _entryFor(
  List<PurchaseOrderLine> group,
  AppLocalizations l10n,
) {
  final line = group.first;
  final name = line.displayName;
  final received = group.fold<double>(
    0,
    (sum, line) => sum + line.toBaseQuantity(line.receivedQuantity),
  );
  final ordered = group.fold<double>(
    0,
    (sum, line) => sum + line.toBaseQuantity(line.quantity),
  );
  final pieces = received > 0 ? received : ordered;
  final barcode = line.variantBarcode.trim();
  final subtitle = received > 0
      ? l10n.purchaseOrderLabelsReceived(formatQuantity(received), barcode)
      : l10n.purchaseOrderLabelsOrdered(formatQuantity(ordered), barcode);
  return LabelBatchEntry(
    title: name,
    subtitle: subtitle,
    copiesEditable: true,
    unavailableReason: line.trackingMode.tracksUnits
        ? l10n.purchaseOrderLabelsSerialized
        : null,
    lines: [
      BarcodeLabelPrintLine(
        label: BarcodeLabelDraft(
          productId: line.productId,
          variantId: line.variantId,
          displayName: name,
          productName: line.productName ?? name,
          variantName: line.variantName ?? '',
          sku: line.variantSku ?? '',
          barcode: barcode,
          unitPrice: line.sellingPrice ?? 0,
        ),
        // A weighed line (2.5 kg) still wants at least one sticker.
        copies: pieces.ceil().clamp(1, 999),
        expiryDate: line.tracksExpiry ? line.expiryDate : null,
      ),
    ],
  );
}

/// Opens the order's label batch (see [purchaseOrderLabelEntries]).
Future<void> showPurchaseOrderLabelsSheet(
  BuildContext context, {
  required List<PurchaseOrderLine> lines,
  required PrintingRepository printingRepository,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showLabelBatchPrintSheet(
    context,
    title: l10n.purchaseOrderLabelsTitle,
    subtitle: l10n.purchaseOrderLabelsSubtitle,
    entries: purchaseOrderLabelEntries(lines: lines, l10n: l10n),
    printingRepository: printingRepository,
  );
}
