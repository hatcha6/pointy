import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/barcode_label.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/units.dart';
import 'label_batch_print_sheet.dart';

/// The products a new-product run just made, as a label batch: one row per
/// variant, so the goods typed in can be stickered before they reach the
/// shelf.
///
/// A row asks for as many stickers as its opening stock, or one when none was
/// entered. Services and made-to-order items are left out — nothing to stick a
/// label on. Serial-tracked goods are listed but not printable here — a
/// handset's sticker is its own number.
List<LabelBatchEntry> createdProductLabelEntries({
  required List<Product> products,
  required AppLocalizations l10n,
}) {
  return [
    for (final product in products)
      if (!product.isService && !product.isPrepared)
        for (final variant in _variantsOf(product))
          _entryFor(product, variant, l10n),
  ];
}

List<ProductVariant> _variantsOf(Product product) {
  final active = product.activeVariants;
  if (active.isNotEmpty) {
    return active;
  }
  final fallback = product.defaultVariant;
  return fallback == null ? const [] : [fallback];
}

LabelBatchEntry _entryFor(
  Product product,
  ProductVariant variant,
  AppLocalizations l10n,
) {
  // A variant inside its product's payload may not name its product; the
  // sticker needs that name.
  final draft = BarcodeLabelDraft.fromVariant(
    variant.productDetail == null
        ? variant.copyWith(productDetail: product)
        : variant,
  );
  final barcode = draft.barcode.trim();
  final stock = variant.quantityOnHand;
  return LabelBatchEntry(
    title: draft.displayName.trim().isEmpty ? product.name : draft.displayName,
    subtitle: stock > 0
        ? l10n.createdProductLabelsStock(formatQuantity(stock), barcode)
        : barcode,
    copiesEditable: true,
    unavailableReason: product.trackingMode.tracksUnits
        ? l10n.purchaseOrderLabelsSerialized
        : barcode.isEmpty
        ? l10n.createdProductLabelsNoBarcode
        : null,
    lines: [
      BarcodeLabelPrintLine(
        label: draft,
        // A weighed opening stock (2.5 kg) still wants at least one sticker.
        copies: stock > 0 ? stock.ceil().clamp(1, 999) : 1,
      ),
    ],
  );
}

/// Offers the run's stickers (see [createdProductLabelEntries]) once the
/// person is done creating products. Says nothing when none of them could
/// print — a sheet of greyed rows is a question with no answer.
Future<void> showCreatedProductLabelsSheet(
  BuildContext context, {
  required List<Product> products,
  required PrintingRepository printingRepository,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final entries = createdProductLabelEntries(products: products, l10n: l10n);
  if (!entries.any((entry) => entry.printable)) {
    return;
  }
  await showLabelBatchPrintSheet(
    context,
    title: l10n.createdProductLabelsTitle,
    subtitle: l10n.createdProductLabelsSubtitle,
    entries: entries,
    printingRepository: printingRepository,
  );
}
