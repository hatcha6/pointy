import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_product_create.dart';
import 'purchase_suggestion_strip.dart';

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
      search: _PurchaseProductLookupControls(
        viewModel: viewModel,
        onOpenCameraScanner: () => _openCameraScanner(context),
        onSearchSubmitted: (barcode) => _addBarcode(context, barcode),
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
      suggestionStrip: PurchaseSuggestionStrip.maybeBuild(viewModel),
      statusLine: viewModel.scanStatus != PurchaseScanStatus.idle
          ? _PurchaseScanStatusLine(viewModel: viewModel)
          : null,
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
                CatalogEmptyState.cleared(viewModel.query),
              ),
            ),
            gridDelegate: PointyProductCardGrid.delegateFor(
              width: constraints.maxWidth,
              spacing: spacing.gutter,
            ),
            itemBuilder: (context, variant) {
              return TutorTarget(
                anchor: TutorAnchor.purchaseProductTile,
                // The SKU, as on the till: a lesson that says "order more أرز"
                // must point at أرز, not at whichever tile mounted first.
                id: variant.sku,
                child: ProductTile.variant(
                  key: ValueKey(variant.id),
                  variant: variant,
                  showPrice: false,
                  showStock: true,
                  cartQuantity: draftQuantities[variant.id] ?? 0,
                  onTap: viewModel.isSubmitting
                      ? null
                      : () {
                          unawaited(
                            viewModel
                                .addVariant(
                                  variant,
                                  source: 'purchase_catalog_tile',
                                )
                                // Focus goes back to the search field once the
                                // line lands, so the next product can be looked
                                // up or scanned without a tap. (It used to be
                                // dropped outright, which left the buyer with no
                                // focused field at all.)
                                .then((_) => viewModel.requestSearchFocus()),
                          );
                        },
                ),
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
    await addScannedPurchaseBarcode(
      context,
      viewModel: viewModel,
      barcode: barcode,
    );
    return viewModel.scanStatus == PurchaseScanStatus.found;
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

/// The purchasing catalog's search field, owning its own focus node so the view
/// model can pull focus back between the buyer's actions — the same
/// resting-focus behaviour the POS has had since the search-autofocus work.
/// Receiving a delivery is the same shape of job as ringing up a queue: scan,
/// glance, scan again, and every tap needed in between is one the buyer's hands
/// have to leave the scanner for.
class _PurchaseProductLookupControls extends StatefulWidget {
  const _PurchaseProductLookupControls({
    required this.viewModel,
    required this.onOpenCameraScanner,
    required this.onSearchSubmitted,
  });

  final PurchaseViewModel viewModel;
  final VoidCallback onOpenCameraScanner;
  final Future<bool> Function(String barcode) onSearchSubmitted;

  @override
  State<_PurchaseProductLookupControls> createState() =>
      _PurchaseProductLookupControlsState();
}

class _PurchaseProductLookupControlsState
    extends State<_PurchaseProductLookupControls> {
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'purchase_product_search',
  );

  PurchaseViewModel get _viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel.searchFocusController.addListener(_handleFocusRequest);
  }

  @override
  void didUpdateWidget(covariant _PurchaseProductLookupControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewModel, widget.viewModel)) {
      oldWidget.viewModel.searchFocusController.removeListener(
        _handleFocusRequest,
      );
      widget.viewModel.searchFocusController.addListener(_handleFocusRequest);
    }
  }

  @override
  void dispose() {
    _viewModel.searchFocusController.removeListener(_handleFocusRequest);
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Takes focus at the view model's request, deferred to after the frame (the
  /// request usually fires mid-rebuild) and suppressed while a sheet or dialog
  /// is up, or on a phone layout — so it never steals the caret from the
  /// pricing sheet or pops a soft keyboard unbidden.
  void _handleFocusRequest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        return;
      }
      if (AppBreakpoints.of(context).index < AppBreakpoint.tablet.index) {
        return;
      }
      _searchFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;

    return TutorTarget(
      anchor: TutorAnchor.purchaseCatalogSearchField,
      child: ProductQueryControls(
        query: viewModel.query,
        catalogRepository: viewModel.catalogRepository,
        allowAvailabilityFilter: false,
        searchHint: l10n.purchaseProductLookupHint,
        searchFieldKey: const ValueKey('purchase_product_lookup_field'),
        searchFocusNode: _searchFocusNode,
        searchResetSignal: viewModel.searchResetController,
        autofocus:
            AppBreakpoints.of(context).index >= AppBreakpoint.tablet.index,
        onSearchChanged: viewModel.updateSearch,
        onOpenCameraScanner: viewModel.isSubmitting
            ? null
            : widget.onOpenCameraScanner,
        onSearchSubmitted: viewModel.isSubmitting
            ? null
            : (barcode) => widget.onSearchSubmitted(barcode),
        onQueryChanged: viewModel.applyQuery,
      ),
    );
  }
}

/// Where the last scan got to, above the grid. A buyer working through a pallet
/// watches the scanner, not the draft — this is the line that tells them the
/// gun was heard, and names the product it landed on.
class _PurchaseScanStatusLine extends StatelessWidget {
  const _PurchaseScanStatusLine({required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final status = viewModel.scanStatus;
    final message = switch (status) {
      PurchaseScanStatus.resolving => l10n.barcodeScanResolving,
      PurchaseScanStatus.found => l10n.barcodeScanAdded(
        viewModel.lastScannedProductName ?? '',
      ),
      PurchaseScanStatus.notFound => l10n.barcodeScanNotFound(
        viewModel.lastScannedBarcode ?? '',
      ),
      PurchaseScanStatus.error => l10n.barcodeScanError,
      PurchaseScanStatus.idle => '',
    };
    final color = switch (status) {
      PurchaseScanStatus.found => colors.primaryStrong,
      PurchaseScanStatus.notFound || PurchaseScanStatus.error => colors.danger,
      PurchaseScanStatus.resolving ||
      PurchaseScanStatus.idle => colors.mutedInk,
    };

    return Row(
      children: [
        if (status == PurchaseScanStatus.resolving)
          const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          )
        else
          Icon(
            status == PurchaseScanStatus.found
                ? Icons.check_circle_outline
                : Icons.error_outline,
            size: 18,
            color: color,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
        IconButton(
          tooltip: l10n.clearBarcodeStatusTooltip,
          onPressed: viewModel.clearScanStatus,
          icon: const Icon(Icons.close),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
