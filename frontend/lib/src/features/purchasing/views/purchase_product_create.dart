import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/barcode_resolution.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/responsive/responsive.dart';
import '../../catalog/view_models/catalog_view_model.dart';
import '../../catalog/views/product_form.dart';
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
/// buyer reaches for this because the box in their hands is not in the catalog
/// yet — so creating the product and ordering it is one action, not two.
Future<void> createPurchaseProduct(
  BuildContext context, {
  required PurchaseViewModel viewModel,
}) async {
  final created = await showPurchaseProductForm(context, viewModel: viewModel);
  if (created == null) {
    return;
  }
  await viewModel.addVariant(created, source: 'purchase_new_product');
  // Same resting focus the scan path leaves behind: the buyer is back at the
  // search field, ready for the next item off the pallet.
  viewModel.requestSearchFocus();
}

/// Presents the full product-creation workflow — the same robust wizard used in
/// the catalog — prefilled with [barcode] when a scan opened it, and returns the
/// created product's default variant so the caller can drop it straight into
/// the purchase order.
///
/// Backs the form with its own [CatalogViewModel] over the shared catalog
/// repository (the wizard is written against that view model); the instance is
/// disposed with the sheet.
Future<ProductVariant?> showPurchaseProductForm(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  String? barcode,
}) {
  return showAdaptiveFormSurface<ProductVariant?>(
    context: context,
    size: AdaptiveModalSize.standard,
    desktopPresentation: AdaptiveFormPresentation.sidePanel,
    maxHeightFactor: 0.9,
    builder: (sheetContext) {
      return _PurchaseProductFormSheet(
        barcode: barcode,
        purchaseViewModel: viewModel,
      );
    },
  );
}

class _PurchaseProductFormSheet extends StatefulWidget {
  const _PurchaseProductFormSheet({
    required this.barcode,
    required this.purchaseViewModel,
  });

  final String? barcode;
  final PurchaseViewModel purchaseViewModel;

  @override
  State<_PurchaseProductFormSheet> createState() =>
      _PurchaseProductFormSheetState();
}

class _PurchaseProductFormSheetState extends State<_PurchaseProductFormSheet> {
  late final CatalogViewModel _catalogViewModel = CatalogViewModel(
    widget.purchaseViewModel.catalogRepository,
    analyticsEngine: widget.purchaseViewModel.analyticsEngine,
  );

  @override
  void dispose() {
    _catalogViewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ProductForm(
        viewModel: _catalogViewModel,
        initialBarcode: widget.barcode,
        onCreated: (product) {
          // Refresh the purchase catalog so the fresh product surfaces in the
          // grid, then hand its default variant back to the caller to add to
          // the current purchase order.
          unawaited(widget.purchaseViewModel.loadCatalog());
          Navigator.of(context).pop<ProductVariant?>(product.defaultVariant);
        },
      ),
    );
  }
}
