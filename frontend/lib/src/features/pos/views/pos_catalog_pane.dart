import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/unit_options.dart';
import '../view_models/pos_view_model.dart';
import 'modifier_sheet.dart';
import 'pos_variant_picker_sheet.dart';
import 'weight_entry_sheet.dart';

class PosCatalogPane extends StatelessWidget {
  const PosCatalogPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyCatalogPane(
      title: l10n.catalogTitle,
      isLoading: viewModel.isLoading,
      resultCount: viewModel.isLoading && viewModel.products.isEmpty
          ? null
          : viewModel.products.length,
      hasMoreResults: viewModel.hasMoreProducts,
      notice: viewModel.errorMessage != null
          ? PointyInlineMessage.warning(message: l10n.sampleCatalogNotice)
          : null,
      search: _PosProductLookupControls(
        viewModel: viewModel,
        capabilities: capabilities,
      ),
      categoryStrip: QuickAccessCategoryStrip(
        catalogRepository: viewModel.catalogRepository,
        selectedCategories: viewModel.query.categories,
        allLabel: l10n.posAllProductsFilterLabel,
        onSelectAll: () {
          viewModel.applyQuery(viewModel.query.copyWith(categories: const []));
        },
        onSelectCategory: (category) {
          viewModel.applyQuery(
            viewModel.query.copyWith(categories: [category]),
          );
        },
      ),
      statusLine: viewModel.barcodeScanStatus != BarcodeScanStatus.idle
          ? _BarcodeScanStatusLine(viewModel: viewModel)
          : null,
      grid: _PosCatalogGrid(
        viewModel: viewModel,
        capabilities: capabilities,
        emptyMessage: l10n.emptyCatalog,
        cartQuantities: _cartQuantitiesByProduct(viewModel.cart),
      ),
    );
  }

  /// Sums cart quantities per product so each catalog card can show how many
  /// of that product are already in the open sale.
  static Map<int, double> _cartQuantitiesByProduct(List<CartLine> cart) {
    final quantities = <int, double>{};
    for (final line in cart) {
      quantities.update(
        line.variant.productId,
        (value) => value + line.quantity,
        ifAbsent: () => line.quantity,
      );
    }
    return quantities;
  }
}

class _PosCatalogGrid extends StatelessWidget {
  const _PosCatalogGrid({
    required this.viewModel,
    required this.capabilities,
    required this.emptyMessage,
    required this.cartQuantities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final String emptyMessage;
  final Map<int, double> cartQuantities;

  @override
  Widget build(BuildContext context) {
    final products = viewModel.products;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final spacing = AdaptiveSpacing.of(context);

            return InfiniteScrollGrid<Product>(
              items: products,
              onLoadMore: viewModel.loadMoreCatalog,
              hasMore: viewModel.hasMoreProducts,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              loadMoreExtent: PointyProductCardGrid.loadMoreExtent,
              skeletonItemBuilder: (_) => const PointySkeletonCard(),
              skeletonItemCount: 12,
              emptyBuilder: (context) =>
                  _PosCatalogEmptyState(message: emptyMessage),
              gridDelegate: PointyProductCardGrid.delegateFor(
                width: constraints.maxWidth,
                spacing: spacing.gutter,
              ),
              itemBuilder: (context, product) {
                return ProductTile(
                  key: ValueKey(product.id),
                  product: product,
                  cartQuantity: cartQuantities[product.id] ?? 0,
                  onTap: canCheckout
                      ? () => _selectProduct(context, product)
                      : null,
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _addWeighedVariant(
    BuildContext context,
    Product product,
    ProductVariant variant, {
    required String source,
  }) async {
    final weight = await showWeightEntrySheet(context, variant: variant);
    if (weight == null || !context.mounted) {
      return;
    }
    if (product.modifierGroups.isEmpty) {
      viewModel.addVariant(variant, quantity: weight, source: source);
      return;
    }
    final modifiers = await showModifierSheet(
      context,
      product: product,
      variant: variant,
    );
    if (modifiers != null && context.mounted) {
      viewModel.addVariant(
        variant,
        quantity: weight,
        modifiers: modifiers,
        source: source,
      );
    }
  }

  Future<void> _addWithModifiers(
    BuildContext context,
    Product product,
    ProductVariant variant, {
    required String source,
  }) async {
    final modifiers = await showModifierSheet(
      context,
      product: product,
      variant: variant,
    );
    if (modifiers != null && context.mounted) {
      final unit = defaultSaleUnitOption(product, variant.unitPrice);
      viewModel.addVariant(
        variant,
        modifiers: modifiers,
        unit: unit.isBase ? null : unit,
        source: source,
      );
    }
  }

  Future<void> _selectProduct(BuildContext context, Product product) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    // The add itself returns keyboard focus to the search field (via the view
    // model's search-focus signal) once the line lands, so the cashier can look
    // up or scan the next item straight away.
    final result = await viewModel.selectProductForSale(product);
    if (!context.mounted) {
      return;
    }
    switch (result.status) {
      case PosProductSelectionStatus.added:
        return;
      case PosProductSelectionStatus.weighVariant:
        final weighed = result.weighedVariant;
        if (weighed != null && context.mounted) {
          await _addWeighedVariant(
            context,
            product,
            weighed,
            source: 'product_tile',
          );
        }
      case PosProductSelectionStatus.chooseModifiers:
        final variant = result.modifierVariant;
        if (variant != null && context.mounted) {
          await _addWithModifiers(
            context,
            product,
            variant,
            source: 'product_tile',
          );
        }
      case PosProductSelectionStatus.chooseVariant:
        final variant = await showPosVariantPickerSheet(
          context,
          product: product,
          variants: result.variants,
        );
        if (variant != null && context.mounted) {
          final defaultUnit = defaultSaleUnitOption(product, variant.unitPrice);
          if (defaultUnit.allowsFractional) {
            await _addWeighedVariant(
              context,
              product,
              variant,
              source: 'variant_picker',
            );
          } else if (product.modifierGroups.isNotEmpty) {
            await _addWithModifiers(
              context,
              product,
              variant,
              source: 'variant_picker',
            );
          } else {
            viewModel.addVariant(
              variant,
              unit: defaultUnit.isBase ? null : defaultUnit,
              source: 'variant_picker',
            );
          }
        }
      case PosProductSelectionStatus.unavailable:
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.posProductHasNoActiveVariants)),
          );
      case PosProductSelectionStatus.error:
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.catalogLoadError)));
    }
  }
}

class _PosCatalogEmptyState extends StatelessWidget {
  const _PosCatalogEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PointyEmptyState(icon: Icons.inventory_2_outlined, title: message);
  }
}

class _PosProductLookupControls extends StatefulWidget {
  const _PosProductLookupControls({
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  State<_PosProductLookupControls> createState() =>
      _PosProductLookupControlsState();
}

class _PosProductLookupControlsState extends State<_PosProductLookupControls> {
  // Owned here (not by the TextField) so the view model can pull focus back to
  // the search field between the cashier's actions.
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'pos_product_search',
  );

  PosViewModel get _viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel.searchFocusController.addListener(_handleFocusRequest);
  }

  @override
  void didUpdateWidget(covariant _PosProductLookupControls oldWidget) {
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

  /// Pulls keyboard focus onto the search field at the view model's request.
  /// Deferred to after the frame — the request usually fires during a rebuild
  /// (e.g. right after a line is added) — and suppressed when a modal is up (a
  /// payment sheet, a dialog) or on the compact phone layout, so it never
  /// steals the caret from a sheet or pops the soft keyboard unbidden. The
  /// view model only ever fires it between actions, never mid quantity-edit.
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
    final capabilities = widget.capabilities;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        return ProductQueryControls(
          query: viewModel.query,
          catalogRepository: viewModel.catalogRepository,
          allowAvailabilityFilter: false,
          searchHint: l10n.posProductLookupHint,
          searchFieldKey: const ValueKey('product_lookup_field'),
          searchFocusNode: _searchFocusNode,
          // Clears the field (and cancels its debounce) after a scan so a
          // scanned barcode never lingers in the search box.
          searchResetSignal: viewModel.searchResetController,
          autofocus:
              AppBreakpoints.of(context).index >= AppBreakpoint.tablet.index,
          onSearchChanged: viewModel.updateSearch,
          onOpenCameraScanner:
              canCheckout &&
                  !viewModel.isCheckingOut &&
                  !viewModel.isResolvingBarcode
              ? () => _openCameraScanner(context)
              : null,
          onSearchSubmitted:
              canCheckout &&
                  !viewModel.isCheckingOut &&
                  !viewModel.isResolvingBarcode
              ? viewModel.addVariantByBarcode
              : null,
          onQueryChanged: viewModel.applyQuery,
        );
      },
    );
  }

  Future<void> _openCameraScanner(BuildContext context) async {
    final entries = await showCameraBarcodeScannerSheet(
      context,
      mode: CameraBarcodeScannerMode.multiple,
      lookupVariant: _lookupVariantByBarcode,
      enableQuantity: true,
    );
    if (entries == null || entries.isEmpty) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    for (final entry in entries) {
      if (_viewModel.isCheckingOut) {
        return;
      }
      _viewModel.addVariant(
        entry.variant,
        quantity: entry.quantity.toDouble(),
        source: 'camera_scanner',
      );
    }
  }

  Future<ProductVariant?> _lookupVariantByBarcode(String barcode) async {
    final result = await _viewModel.catalogRepository
        .findProductVariantByBarcode(barcode, activeOnly: true);
    // Camera scans resolve inside the sheet, bypassing the view model's
    // barcode path — chime here so every scan still gets audible feedback.
    switch (result) {
      case Ok<ProductVariant?>(:final value):
        ScanFeedbackSounds.instance.play(
          value == null ? ScanFeedback.notFound : ScanFeedback.success,
        );
        return value;
      case Error<ProductVariant?>():
        ScanFeedbackSounds.instance.play(ScanFeedback.error);
        throw Exception('barcode lookup failed');
    }
  }
}

class _BarcodeScanStatusLine extends StatelessWidget {
  const _BarcodeScanStatusLine({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final status = viewModel.barcodeScanStatus;
    final message = switch (status) {
      BarcodeScanStatus.resolving => l10n.barcodeScanResolving,
      BarcodeScanStatus.found => l10n.barcodeScanAdded(
        viewModel.lastScannedProductName ?? '',
      ),
      BarcodeScanStatus.notFound => l10n.barcodeScanNotFound(
        viewModel.lastScannedBarcode ?? '',
      ),
      BarcodeScanStatus.error => l10n.barcodeScanError,
      BarcodeScanStatus.idle => '',
    };
    final color = switch (status) {
      BarcodeScanStatus.found => colors.primaryStrong,
      BarcodeScanStatus.notFound || BarcodeScanStatus.error => colors.danger,
      BarcodeScanStatus.resolving || BarcodeScanStatus.idle => colors.mutedInk,
    };

    return Row(
      children: [
        if (status == BarcodeScanStatus.resolving)
          const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          )
        else
          Icon(
            status == BarcodeScanStatus.found
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
          onPressed: viewModel.clearBarcodeScanStatus,
          icon: const Icon(Icons.close),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
