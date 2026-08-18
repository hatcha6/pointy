import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/barcode_resolution.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_product_create.dart';

class PurchaseCatalogPane extends StatelessWidget {
  const PurchaseCatalogPane({super.key, required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final draftQuantities = _draftQuantitiesByVariant();

    return PointyCatalogPane(
      title: l10n.purchaseCatalogTitle,
      isLoading: viewModel.isLoading,
      resultCount: viewModel.isLoading && viewModel.variants.isEmpty
          ? null
          : viewModel.variants.length,
      hasMoreResults: viewModel.hasMoreProducts,
      notice: viewModel.errorMessage != null
          ? PointyInlineMessage.warning(message: l10n.sampleCatalogNotice)
          : null,
      search: ProductQueryControls(
        query: viewModel.query,
        catalogRepository: viewModel.catalogRepository,
        allowAvailabilityFilter: false,
        searchHint: l10n.purchaseProductLookupHint,
        searchFieldKey: const ValueKey('purchase_product_lookup_field'),
        autofocus:
            AppBreakpoints.of(context).index >= AppBreakpoint.tablet.index,
        onSearchChanged: viewModel.updateSearch,
        onOpenCameraScanner: viewModel.isSubmitting
            ? null
            : () => _openCameraScanner(context),
        onSearchSubmitted: viewModel.isSubmitting
            ? null
            : (barcode) => _addBarcode(context, barcode),
        onQueryChanged: viewModel.applyQuery,
      ),
      categoryStrip: QuickAccessCategoryStrip(
        catalogRepository: viewModel.catalogRepository,
        selectedCategories: viewModel.query.categories,
        allLabel: l10n.posAllProductsFilterLabel,
        onSelectAll: () => viewModel.applyQuery(
          viewModel.query.copyWith(categories: const []),
        ),
        onSelectCategory: (category) => viewModel.applyQuery(
          viewModel.query.copyWith(categories: [category]),
        ),
      ),
      grid: LayoutBuilder(
        builder: (context, constraints) {
          final spacing = AdaptiveSpacing.of(context);
          return InfiniteScrollGrid<ProductVariant>(
            items: viewModel.variants,
            onLoadMore: viewModel.loadMoreCatalog,
            hasMore: viewModel.hasMoreProducts,
            isLoadingInitial: viewModel.isLoading,
            isLoadingMore: viewModel.isLoadingMore,
            loadMoreExtent: PointyProductCardGrid.loadMoreExtent,
            skeletonItemBuilder: (_) => const PointySkeletonCard(),
            skeletonItemCount: 12,
            emptyBuilder: (context) => CatalogEmptyState(
              query: viewModel.query,
              emptyMessage: l10n.emptyCatalog,
              onClear: () => viewModel.applyQuery(
                viewModel.query.copyWith(search: '', categories: const []),
              ),
            ),
            gridDelegate: PointyProductCardGrid.delegateFor(
              width: constraints.maxWidth,
              spacing: spacing.gutter,
            ),
            itemBuilder: (context, variant) {
              return ProductTile.variant(
                key: ValueKey(variant.id),
                variant: variant,
                showPrice: false,
                showStock: true,
                cartQuantity: draftQuantities[variant.id] ?? 0,
                onTap: viewModel.isSubmitting
                    ? null
                    : () {
                        // Release the search field's focus so typing right
                        // after the tap sets the quantity (scan-then-type).
                        FocusManager.instance.primaryFocus?.unfocus();
                        unawaited(
                          viewModel.addVariant(
                            variant,
                            source: 'purchase_catalog_tile',
                          ),
                        );
                      },
              );
            },
          );
        },
      ),
    );
  }

  /// Maps each variant in the draft to its quantity so catalog cards can show a
  /// badge for items already added to the purchase.
  Map<int, double> _draftQuantitiesByVariant() {
    final quantities = <int, double>{};
    for (final line in viewModel.draft) {
      quantities[line.variant.id] = line.quantity.toDouble();
    }
    return quantities;
  }

  Future<bool> _addBarcode(BuildContext context, String barcode) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    BarcodeResolution? resolution;
    try {
      resolution = await resolveOrCreatePurchaseBarcode(
        context,
        viewModel: viewModel,
        barcode: barcode,
      );
    } on Exception {
      if (!context.mounted) {
        return false;
      }
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.barcodeScanError)));
      return false;
    }
    if (resolution == null) {
      return false;
    }
    await viewModel.addVariant(
      resolution.variant,
      unit: resolution.unit,
      source: 'purchase_barcode_lookup',
    );
    return true;
  }

  Future<void> _openCameraScanner(BuildContext context) async {
    final entries = await showCameraBarcodeScannerSheet(
      context,
      mode: CameraBarcodeScannerMode.multiple,
      lookupVariant: _lookupVariantByBarcode,
      createMissingVariant: (barcode) {
        return showPurchaseProductForm(
          context,
          barcode: barcode,
          viewModel: viewModel,
        );
      },
      enableQuantity: true,
    );
    if (entries == null || entries.isEmpty) {
      return;
    }
    for (final entry in entries) {
      await viewModel.addVariant(
        entry.variant,
        quantity: entry.quantity.toDouble(),
        source: 'purchase_camera_scanner',
      );
    }
  }

  Future<ProductVariant?> _lookupVariantByBarcode(String barcode) async {
    // Camera scans resolve inside the sheet, bypassing the wedge path —
    // chime here so every scan still gets audible feedback.
    ProductVariant? variant;
    try {
      variant = await viewModel.findVariantByBarcode(barcode);
    } on Exception {
      ScanFeedbackSounds.instance.play(ScanFeedback.error);
      rethrow;
    }
    ScanFeedbackSounds.instance.play(
      variant == null ? ScanFeedback.notFound : ScanFeedback.success,
    );
    return variant;
  }
}
