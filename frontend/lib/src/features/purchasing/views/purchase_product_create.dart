import 'dart:async';

import 'package:flutter/material.dart';

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
}) async {
  final result = await viewModel.resolveBarcode(barcode);
  switch (result) {
    case Ok<BarcodeResolution?>(:final value):
      if (value != null) {
        ScanFeedbackSounds.instance.play(ScanFeedback.success);
        return value;
      }
      ScanFeedbackSounds.instance.play(ScanFeedback.notFound);
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

/// Presents the full product-creation workflow — the same robust wizard used in
/// the catalog — prefilled with [barcode], and returns the created product's
/// default variant so the caller can drop it straight into the purchase order.
///
/// Backs the form with its own [CatalogViewModel] over the shared catalog
/// repository (the wizard is written against that view model); the instance is
/// disposed with the sheet.
Future<ProductVariant?> showPurchaseProductForm(
  BuildContext context, {
  required String barcode,
  required PurchaseViewModel viewModel,
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

  final String barcode;
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
