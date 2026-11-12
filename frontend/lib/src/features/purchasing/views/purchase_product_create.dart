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
///
/// A [typed] code gets one more reading before it is called unknown, because
/// a person types SKUs as readily as barcodes and no barcode answers to an
/// SKU: the catalog search is asked. The one product carrying exactly that
/// SKU is the answer; any other results mean the text is a search, and
/// [onSearchInstead] hands it back to the search box (null is returned) —
/// what Enter does with it on the till. Only a code nothing matches at all
/// opens the creation wizard. A scanner's code is always a barcode and skips
/// this.
Future<BarcodeResolution?> resolveOrCreatePurchaseBarcode(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required String barcode,
  ValueChanged<bool>? onLookupSettled,
  bool typed = false,
  VoidCallback? onSearchInstead,
}) async {
  final result = await viewModel.resolveBarcode(barcode);
  switch (result) {
    case Ok<BarcodeResolution?>(:final value):
      if (value != null) {
        ScanFeedbackSounds.instance.play(ScanFeedback.success);
        onLookupSettled?.call(true);
        return value;
      }
      if (typed) {
        final matches = await viewModel.searchTypedCode(barcode);
        final code = barcode.trim().toLowerCase();
        final exact = matches
            .where((variant) => variant.sku.trim().toLowerCase() == code)
            .toList(growable: false);
        if (exact.length == 1) {
          ScanFeedbackSounds.instance.play(ScanFeedback.success);
          onLookupSettled?.call(true);
          return BarcodeResolution(variant: exact.single);
        }
        if (matches.isNotEmpty) {
          onSearchInstead?.call();
          return null;
        }
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
///
/// [walkLine] leaves the keyboard on the line the code landed on, ready for
/// its quantity and then Enter through the rest (unit, cost, expiry), instead
/// of going back to the search box — the code is the start of an invoice row.
/// Off where the draft is not on screen to be walked.
///
/// [typed] marks a code typed into the search box rather than scanned: it may
/// be an SKU, or a search (see [resolveOrCreatePurchaseBarcode]).
Future<void> addScannedPurchaseBarcode(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required String barcode,
  bool walkLine = false,
  bool typed = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context)!;
  viewModel.reportScanStatus(PurchaseScanStatus.resolving, barcode: barcode);
  BarcodeResolution? resolution;
  var searchInstead = false;
  try {
    resolution = await resolveOrCreatePurchaseBarcode(
      context,
      viewModel: viewModel,
      barcode: barcode,
      typed: typed,
      onSearchInstead: () => searchInstead = true,
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
  if (searchInstead) {
    // The typed text is a search, not a code: it stays in the box, with its
    // results under it, and nothing claims a barcode was not found.
    viewModel.clearScanStatus();
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
  final landed = resolution?.variant.id;
  if (walkLine && landed != null) {
    viewModel.requestLineEntry(landed);
  } else {
    viewModel.requestSearchFocus();
  }
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
