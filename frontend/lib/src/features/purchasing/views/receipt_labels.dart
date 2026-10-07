import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/barcode_label.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/date_formatters.dart';
import '../../catalog/views/label_batch_print_sheet.dart';

/// What a delivery just brought, as stickers: each handset with its own
/// number and price, each lot's goods dated with that lot's expiry.
///
/// Printed while the boxes are still open is the only time a shop labels a
/// handset reliably — later it is one of forty on a shelf. Untracked goods
/// print from the product page as they always did.
List<LabelBatchEntry> receiptLabelEntries({
  required List<PurchaseOrderLine> orderLines,
  required List<PurchaseReceiveLineDraft> received,
  required AppLocalizations l10n,
}) {
  final linesById = {for (final line in orderLines) line.id: line};
  final entries = <LabelBatchEntry>[];
  for (final draft in received) {
    final line = linesById[draft.purchaseLineId];
    final capture = draft.capture;
    if (line == null || capture == null || draft.quantityReceived <= 0) {
      continue;
    }
    final name = line.displayName;
    final mode = line.trackingMode;
    if (mode.tracksUnits) {
      // The capture lists what arrived sound first and the damaged after it,
      // the order the server reads it in; only the sound ones get a sticker.
      final sound = line.toBaseQuantity(draft.quantityReceived).round();
      final units = [
        for (final unit in capture.units.take(sound))
          if (unit.isIdentified) unit,
      ];
      if (units.isEmpty) continue;
      final lotExpiry = capture.batches.isEmpty
          ? null
          : capture.batches.first.expiryDate;
      entries.add(
        LabelBatchEntry(
          title: name,
          subtitle: l10n.labelBatchUnitsEntry(units.length),
          lines: [
            for (final unit in units)
              BarcodeLabelPrintLine(
                label: BarcodeLabelDraft(
                  displayName: name,
                  productName: line.productName ?? name,
                  sku: unit.code,
                  barcode: unit.code,
                  unitPrice: unit.listPrice ?? line.sellingPrice ?? 0,
                ),
                copies: 1,
                expiryDate: lotExpiry,
              ),
          ],
        ),
      );
      continue;
    }
    if (mode.tracksLots) {
      for (final lot in capture.batches) {
        if (lot.quantity <= 0) continue;
        final code = lot.code.trim();
        final expiry = lot.expiryDate;
        entries.add(
          LabelBatchEntry(
            title: name,
            subtitle: expiry == null
                ? l10n.labelBatchLotEntryNoDate(code)
                : l10n.labelBatchLotEntry(code, formatDate(expiry)),
            copiesEditable: true,
            lines: [
              BarcodeLabelPrintLine(
                label: BarcodeLabelDraft(
                  displayName: name,
                  productName: line.productName ?? name,
                  sku: line.variantSku ?? '',
                  barcode: line.variantBarcode,
                  unitPrice: line.sellingPrice ?? 0,
                ),
                copies: lot.quantity.round().clamp(1, 999),
                expiryDate: expiry,
              ),
            ],
          ),
        );
      }
    }
  }
  return entries;
}

/// The receipt's success message, carrying an offer to print what it brought
/// when it brought anything that wants a sticker of its own.
void showReceiptDoneSnackBar(
  BuildContext context, {
  required ScaffoldMessengerState messenger,
  required String message,
  required List<LabelBatchEntry> entries,
  PrintingRepository? printingRepository,
}) {
  final l10n = AppLocalizations.of(context)!;
  final printing = printingRepository;
  final offer = printing != null && entries.any((entry) => entry.printable);
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: offer
            ? const Duration(seconds: 10)
            : const Duration(seconds: 4),
        action: offer
            ? SnackBarAction(
                label: l10n.receiptLabelsAction,
                onPressed: () {
                  if (!context.mounted) return;
                  showLabelBatchPrintSheet(
                    context,
                    title: l10n.receiptLabelsTitle,
                    subtitle: l10n.receiptLabelsSubtitle,
                    entries: entries,
                    printingRepository: printing,
                  );
                },
              )
            : null,
      ),
    );
}
