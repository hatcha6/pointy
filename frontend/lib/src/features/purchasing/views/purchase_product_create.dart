import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/barcode_resolution.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../catalog/view_models/catalog_view_model.dart';
import '../../catalog/views/product_create_surface.dart';
import '../view_models/purchase_view_model.dart';

/// Resolves a scanned code — variant barcode or packaging (unit) barcode — or
/// walks the user through the full product-creation workflow when nothing
/// matches. A failed lookup (unreadable/rejected code, request error) chimes
/// and throws instead of offering to create a product that may well exist.
Future<BarcodeResolution?> resolveOrCreatePurchaseBarcode(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required String barcode,
  ValueChanged<bool>? onLookupSettled,
}) async {
  final result = await viewModel.resolveBarcode(barcode);
  switch (result) {
    case Ok<BarcodeResolution?>(:final value):
      if (value != null) {
        ScanFeedbackSounds.instance.play(ScanFeedback.success);
        onLookupSettled?.call(true);
        return value;
      }
      ScanFeedbackSounds.instance.play(ScanFeedback.notFound);
      // Reported BEFORE the creation wizard opens: the lookup is genuinely
      // over, and leaving the caller's status on "searching" for however long
      // somebody spends filling in a new product would be a lie (and a spinner
      // running behind a modal).
      onLookupSettled?.call(false);
    case Error<BarcodeResolution?>():
      ScanFeedbackSounds.instance.play(ScanFeedback.error);
      throw Exception('barcode lookup failed');
  }
  if (!context.mounted) {
    return null;
  }
  final created = await showPurchaseProductForm(
    context,
    barcode: barcode,
    viewModel: viewModel,
  );
  return created == null ? null : BarcodeResolution(variant: created);
}

/// Resolves a scanned code and adds it to the draft, reporting each step on the
/// view model's scan status so the catalog pane's status line can narrate it,
/// clearing the search box, and returning focus there for the next scan.
///
/// Shared by the two places a code arrives — the hardware wedge (the screen)
/// and the search field's submit (the catalog pane) — because a scan must
/// behave identically whichever door it comes through.
Future<void> addScannedPurchaseBarcode(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required String barcode,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context)!;
  viewModel.reportScanStatus(PurchaseScanStatus.resolving, barcode: barcode);
  BarcodeResolution? resolution;
  try {
    resolution = await resolveOrCreatePurchaseBarcode(
      context,
      viewModel: viewModel,
      barcode: barcode,
      onLookupSettled: (found) => viewModel.reportScanStatus(
        found ? PurchaseScanStatus.found : PurchaseScanStatus.notFound,
        barcode: barcode,
      ),
    );
  } on Exception {
    viewModel.reportScanStatus(PurchaseScanStatus.error, barcode: barcode);
    if (!context.mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.barcodeScanError)));
    return;
  }
  if (resolution != null) {
    await viewModel.addVariant(
      resolution.variant,
      unit: resolution.unit,
      source: 'purchase_barcode_lookup',
    );
    viewModel.reportScanStatus(
      PurchaseScanStatus.found,
      barcode: barcode,
      productName: resolution.variant.displayLabel,
    );
  }
  // The wedge burst landed in the (focused) search field and started a
  // debounced search; clearing it stops the barcode reappearing ~350ms later,
  // and pulling focus back leaves the buyer ready for the next box.
  viewModel.requestSearchReset();
  viewModel.requestSearchFocus();
}

/// Opens the product-creation workflow from the purchasing workspace with
/// nothing scanned, and drops whatever it creates onto the open order. The
/// buyer reaches for this because the boxes in their hands are not in the
/// catalog yet — so creating the products and ordering them is one action, not
/// two, and «إنشاء وإضافة آخر» puts each one on the order as it is created.
Future<void> createPurchaseProduct(
  BuildContext context, {
  required PurchaseViewModel viewModel,
}) async {
  final created = await showPurchaseProductForm(
    context,
    viewModel: viewModel,
    onCreatedAnother: (variant) => unawaited(
      viewModel.addVariant(variant, source: 'purchase_new_product'),
    ),
  );
  if (created != null) {
    await viewModel.addVariant(created, source: 'purchase_new_product');
  }
  // Same resting focus the scan path leaves behind: the buyer is back at the
  // search field, ready for the next item off the pallet.
  viewModel.requestSearchFocus();
}

/// Presents the catalog's own new-product panel (see
/// [showProductCreateSurface]) prefilled with [barcode] when a scan opened it,
/// and returns the created product's default variant so the caller can drop it
/// straight into the purchase order.
///
/// A scan wants exactly its own product, so «إنشاء وإضافة آخر» is offered only
/// when nothing was scanned; each product it creates goes to
/// [onCreatedAnother]. No opening stock: the order itself is about to bring
/// the stock in, and entering it twice would double the shelf.
Future<ProductVariant?> showPurchaseProductForm(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  String? barcode,
  ValueChanged<ProductVariant>? onCreatedAnother,
}) async {
  void refreshCatalog() => unawaited(viewModel.loadCatalog());
  final created = await showProductCreateSurface(
    context,
    // The form is written against a catalog view model; this one lives and
    // dies with the panel.
    viewModel: CatalogViewModel(
      viewModel.catalogRepository,
      analyticsEngine: viewModel.analyticsEngine,
    ),
    disposeViewModel: true,
    initialBarcode: barcode,
    offerAddAnother: barcode == null && onCreatedAnother != null,
    onCreatedAnother: (product) {
      // Surfaces the fresh product in the purchase catalog grid too.
      refreshCatalog();
      final variant = product.defaultVariant;
      if (variant != null) {
        onCreatedAnother?.call(variant);
      }
    },
  );
  if (created == null) {
    return null;
  }
  refreshCatalog();
  return created.defaultVariant;
}
