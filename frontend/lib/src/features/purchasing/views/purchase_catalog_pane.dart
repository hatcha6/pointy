import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/typed_lookup_text.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/order/order.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_product_create.dart';
import 'purchase_suggestion_strip.dart';

class PurchaseCatalogPane extends StatelessWidget {
  const PurchaseCatalogPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PurchaseViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final draftQuantities = _draftQuantitiesByVariant();

    // Arrows in here move between results; Esc anywhere outside the search
    // box goes back to it.
    return ArrowKeyNavigationRegion(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              FocusManager.instance.primaryFocus?.context
                      ?.findAncestorWidgetOfExactType<EditableText>() ==
                  null) {
            viewModel.requestSearchFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: _pane(context, l10n, draftQuantities),
      ),
    );
  }

  Widget _pane(
    BuildContext context,
    AppLocalizations l10n,
    Map<int, double> draftQuantities,
  ) {
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
      // A delivery routinely contains something the catalog has never seen.
      // Until now the only way to enter it was to scan a code the box may not
      // carry; this is the same wizard, reachable on purpose.
      headerAction: capabilities.canCreateProduct
          ? _CreateProductButton(viewModel: viewModel)
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
        // A provider's cards are never bought on a purchase order.
        includeSystemCategories: false,
      ),
      suggestionStrip: PurchaseSuggestionStrip.maybeBuild(viewModel),
      statusLine: viewModel.scanStatus != PurchaseScanStatus.idle
          ? _PurchaseScanStatusLine(viewModel: viewModel)
          : null,
      grid: CatalogResultsKeyboardRegion(
        focus: viewModel.resultsFocus,
        child: LayoutBuilder(
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
                allowAvailabilityFilter: false,
                onClear: viewModel.applyQuery,
              ),
              gridDelegate: PointyProductCardGrid.delegateFor(
                width: constraints.maxWidth,
                spacing: spacing.gutter,
                short: AppBreakpoints.isShortHeight(context),
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
                            // Enter on a result reached with the arrows: the
                            // buyer is typing an invoice, so walk the new line
                            // (quantity, cost, expiry). A click goes back to the
                            // search field instead, so the next product can be
                            // looked up or scanned without a tap.
                            final viaKeyboard = _activatedByKeyboard();
                            unawaited(
                              viewModel
                                  .addVariant(
                                    variant,
                                    source: 'purchase_catalog_tile',
                                  )
                                  .then(
                                    (_) => viaKeyboard
                                        ? viewModel.requestLineEntry(variant.id)
                                        : viewModel.requestSearchFocus(),
                                  ),
                            );
                          },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Whether a tile's tap is really Enter or Space on a focused tile.
  static bool _activatedByKeyboard() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.enter) ||
        pressed.contains(LogicalKeyboardKey.numpadEnter) ||
        pressed.contains(LogicalKeyboardKey.space);
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

  /// Enter in the search box. A code is looked up exactly; a NAME is not —
  /// «حليب» + Enter used to go to the barcode lookup, miss, and open the new
  /// product wizard with «حليب» as its barcode. Returning false hands the text
  /// back to the search box, which runs the search; ↓ then walks the results.
  /// The POS reads Enter the same way (`PosBarcodeActions.submitLookup`).
  Future<bool> _addBarcode(BuildContext context, String barcode) async {
    if (looksLikeTypedName(barcode)) {
      return false;
    }
    await addScannedPurchaseBarcode(
      context,
      viewModel: viewModel,
      barcode: barcode,
      // Typed by a person (a wedge's Enter never reaches the field): walk the
      // line it landed on.
      walkLine: true,
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

/// Opens the product-creation wizard and drops the result onto the order.
///
/// Labelled from tablet width up and an icon on a phone: the header also
/// carries the pane title and the result count, and on a 375pt till there is
/// not room for all three.
class _CreateProductButton extends StatelessWidget {
  const _CreateProductButton({required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final onPressed = viewModel.isSubmitting
        ? null
        : () => unawaited(createPurchaseProduct(context, viewModel: viewModel));
    if (AppBreakpoints.of(context).index < AppBreakpoint.tablet.index) {
      return IconButton.filled(
        key: const ValueKey('purchase_create_product_button'),
        tooltip: l10n.purchaseCreateProductTooltip,
        onPressed: onPressed,
        icon: const Icon(Icons.add),
      );
    }
    return Tooltip(
      message: l10n.purchaseCreateProductTooltip,
      child: FilledButton.icon(
        key: const ValueKey('purchase_create_product_button'),
        onPressed: onPressed,
        icon: const Icon(Icons.add),
        label: Text(l10n.purchaseCreateProductButton),
      ),
    );
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
  void _handleFocusRequest() =>
      focusSearchAfterFrame(context, _searchFocusNode);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;

    return CallbackShortcuts(
      // ↓ from the search box to the first result (or, with none on screen,
      // whatever sits below — a category chip). Caught here,
      // above the field, before the app-wide text shortcuts treat it as caret
      // movement.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () {
          if (!_viewModel.resultsFocus.focusFirst()) {
            _searchFocusNode.focusInDirection(TraversalDirection.down);
          }
        },
      },
      child: TutorTarget(
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
