import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../settings/views/integration_action_button.dart';
import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/scale_barcode.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/unit_options.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../view_models/pos_view_model.dart';
import 'modifier_sheet.dart';
import 'pos_search_outcome_line.dart';
import 'pos_unit_pick.dart';
import 'pos_variant_picker_sheet.dart';
import 'pos_voucher_brand_sheet.dart';
import 'pos_voucher_menu.dart';
import 'pos_voucher_picker_sheet.dart';
import 'weight_entry_sheet.dart';

class PosCatalogPane extends StatelessWidget {
  const PosCatalogPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
    this.rechargeProviders = const [],
    this.onRecharge,
    this.onTransferVoucherBalance,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// Moves money from the wallet into the voucher balance and says whether any
  /// moved; null for a user who cannot do it from the till.
  final Future<bool> Function()? onTransferVoucherBalance;

  /// The providers this shop can top up, by backend key. Empty draws no
  /// button at all — a grocer must not be able to tell this feature shipped.
  final List<String> rechargeProviders;

  /// Opens the top-up flow for one provider.
  final void Function(String providerKey)? onRecharge;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        viewModel.catalogLayout,
        viewModel.voucherMenu,
      ]),
      builder: (context, _) => _buildPane(context),
    );
  }

  Widget _buildPane(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final layout = viewModel.catalogLayout.layout;
    // The «كروت دفتر» chip opens the company's own menu in the grid's place;
    // typing a search brings the grid back.
    final showsVoucherMenu = viewModel.showsVoucherMenu;
    final products = _PosCatalogProducts(
      viewModel: viewModel,
      capabilities: capabilities,
      layout: layout,
      emptyMessage: l10n.emptyCatalog,
      cartQuantities: _cartQuantitiesByProduct(viewModel.cart),
    );

    return PointyCatalogPane(
      title: l10n.catalogTitle,
      isLoading: showsVoucherMenu
          ? viewModel.voucherMenu.isRefreshing
          : viewModel.isLoading,
      resultCount:
          showsVoucherMenu ||
              (viewModel.isLoading && viewModel.products.isEmpty)
          ? null
          : viewModel.products.length,
      hasMoreResults: viewModel.hasMoreProducts,
      notice: !showsVoucherMenu && viewModel.errorMessage != null
          ? PointyInlineMessage.warning(message: l10n.sampleCatalogNotice)
          : null,
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onRecharge != null && rechargeProviders.isNotEmpty) ...[
            PosRechargeButton(
              providers: rechargeProviders,
              onSelected: onRecharge!,
            ),
            SizedBox(width: AdaptiveSpacing.of(context).sm),
          ],
          CatalogLayoutToggle(
            layout: layout,
            onChanged: (next) {
              viewModel.catalogLayout.setLayout(next);
              // A layout switch is between sales, not inside one: hand the
              // caret back to the search so the next scan lands there.
              viewModel.requestSearchFocus();
            },
          ),
        ],
      ),
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
          if (category.isPointyVouchers) {
            // Picking the chip again re-reads the menu behind what is held,
            // so a promotion that just started shows without waiting.
            unawaited(viewModel.voucherMenu.refresh());
          }
          viewModel.applyQuery(
            viewModel.query.copyWith(categories: [category]),
          );
        },
      ),
      statusLine: viewModel.barcodeScanStatus != BarcodeScanStatus.idle
          ? _BarcodeScanStatusLine(viewModel: viewModel)
          : (showsVoucherMenu ? null : _searchOutcomeLine(l10n, viewModel)),
      grid: showsVoucherMenu
          ? PosVoucherMenuPane(
              viewModel: viewModel,
              capabilities: capabilities,
              fallback: products,
              onTransferVoucherBalance: onTransferVoucherBalance,
            )
          : products,
    );
  }

  /// How the search results were found, when it is not simply as typed —
  /// only while there are results to explain (the empty state speaks for
  /// itself).
  static Widget? _searchOutcomeLine(
    AppLocalizations l10n,
    PosViewModel viewModel,
  ) {
    if (viewModel.isLoading || viewModel.products.isEmpty) {
      return null;
    }
    final message = posSearchOutcomeMessage(l10n, viewModel.searchOutcome);
    return message == null ? null : PosSearchOutcomeLine(message: message);
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

/// The catalog's products as cards or as table rows — the one place both
/// layouts are built, so a tap runs the same selection flow in either.
class _PosCatalogProducts extends StatelessWidget {
  const _PosCatalogProducts({
    required this.viewModel,
    required this.capabilities,
    required this.layout,
    required this.emptyMessage,
    required this.cartQuantities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final CatalogLayout layout;
  final String emptyMessage;
  final Map<int, double> cartQuantities;

  @override
  Widget build(BuildContext context) {
    final products = viewModel.products;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        Widget emptyState(BuildContext context) => CatalogEmptyState(
          query: viewModel.query,
          emptyMessage: emptyMessage,
          allowAvailabilityFilter: false,
          hiddenOutOfStock: viewModel.searchOutcome?.hiddenOutOfStock ?? 0,
          onClear: viewModel.applyQuery,
        );

        Widget item(BuildContext context, Product product) {
          final onTap = canCheckout
              ? () => _selectProduct(context, product)
              : null;
          final cartQuantity = cartQuantities[product.id] ?? 0;
          return TutorTarget(
            anchor: TutorAnchor.posProductTile,
            // The SKU, so a lesson can say "tap خبز" and have the
            // spotlight land on خبز rather than on whichever tile
            // mounted first.
            id: product.defaultVariant?.sku,
            child: layout == CatalogLayout.list
                ? ProductTile.row(
                    key: ValueKey(product.id),
                    product: product,
                    cartQuantity: cartQuantity,
                    onTap: onTap,
                  )
                : ProductTile(
                    key: ValueKey(product.id),
                    product: product,
                    cartQuantity: cartQuantity,
                    onTap: onTap,
                  ),
          );
        }

        if (layout == CatalogLayout.list) {
          return PointyCatalogTable<Product>(
            items: products,
            onLoadMore: viewModel.loadMoreCatalog,
            hasMore: viewModel.hasMoreProducts,
            isLoadingInitial: viewModel.isLoading,
            isLoadingMore: viewModel.isLoadingMore,
            loadMoreExtent: PointyProductCardGrid.loadMoreExtent,
            emptyBuilder: emptyState,
            itemBuilder: item,
          );
        }

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
              emptyBuilder: emptyState,
              gridDelegate: PointyProductCardGrid.delegateFor(
                width: constraints.maxWidth,
                spacing: spacing.gutter,
                short: AppBreakpoints.isShortHeight(context),
              ),
              itemBuilder: item,
            );
          },
        );
      },
    );
  }

  Future<void> _addPickedStockUnit(
    BuildContext context,
    ProductVariant variant,
  ) {
    return pickAndAddStockUnit(
      context,
      viewModel: viewModel,
      variant: variant,
      source: 'variant_picker',
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

  /// Wraps the whole tap-to-add flow — variant picker, weight entry, modifier
  /// sheet and all their nesting — so a background refresh cannot reorder the
  /// grid under the cashier's finger midway through it.
  Future<void> _selectProduct(BuildContext context, Product product) {
    return viewModel.duringCriticalInteraction(
      () => _selectProductFlow(context, product),
    );
  }

  Future<void> _selectProductFlow(BuildContext context, Product product) async {
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
        // One of the company's own cards, found by searching: the same sheet
        // the menu opens, with its countries and flags.
        final menu = viewModel.voucherMenu.menu;
        final brand = product.isVoucher
            ? menu?.brandForProduct(product.id)
            : null;
        if (menu != null && brand != null) {
          final card = await showPosVoucherBrandSheet(
            context,
            brand: brand,
            menu: menu,
            showsProfit: viewModel.isCostRevealed,
          );
          if (card != null && context.mounted) {
            viewModel.addVariant(card, source: 'voucher_menu');
          }
          return;
        }
        if (product.isVoucher) {
          final card = await showPosVoucherPickerSheet(
            context,
            product: product,
            variants: result.variants,
            checkAvailability: () => viewModel.loadVoucherAvailability(product),
          );
          if (card != null && context.mounted) {
            // One card, one line: [addVariant] never merges a card.
            viewModel.addVariant(card, source: 'variant_picker');
          }
          return;
        }
        final variant = await showPosVariantPickerSheet(
          context,
          product: product,
          variants: result.variants,
        );
        if (variant != null && context.mounted) {
          final defaultUnit = defaultSaleUnitOption(product, variant.unitPrice);
          if (variant.trackingMode.tracksUnits ||
              product.trackingMode.tracksUnits) {
            // The same rule the single-variant path applies: an identified
            // article is picked, never implied. A product that happens to have
            // three storage sizes is still a shelf of individual handsets.
            await _addPickedStockUnit(context, variant);
          } else if (defaultUnit.allowsFractional) {
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
      case PosProductSelectionStatus.chooseStockUnit:
        final variant = result.stockUnitVariant;
        if (variant == null) {
          return;
        }
        await _addPickedStockUnit(context, variant);
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
        return TutorTarget(
          anchor: TutorAnchor.posCatalogSearchField,
          child: ProductQueryControls(
            query: viewModel.query,
            catalogRepository: viewModel.catalogRepository,
            allowAvailabilityFilter: false,
            defaultOrdering: PosViewModel.defaultOrdering,
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
                ? viewModel.submitLookup
                : null,
            onQueryChanged: viewModel.applyQuery,
          ),
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
      // A serialized model read off its box is one article per pick, chosen
      // in the picker — never a quantity of "some" handsets.
      if (entry.variant.trackingMode.tracksUnits) {
        for (var picked = 0; picked < entry.quantity; picked += 1) {
          if (!context.mounted || _viewModel.isCheckingOut) {
            return;
          }
          final before = _viewModel.cart.length;
          await pickAndAddStockUnit(
            context,
            viewModel: _viewModel,
            variant: entry.variant,
            source: 'camera_scanner',
          );
          if (_viewModel.cart.length == before) {
            break;
          }
        }
        continue;
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

/// What to say when a scale label did not read the way its sticker intended.
///
/// Null when the scan was an ordinary one, or when the label read cleanly —
/// the common case, which keeps its plain "added" line.
String? _scaleWarningMessage(
  BuildContext context,
  AppLocalizations l10n,
  PosViewModel viewModel,
) {
  final resolved = viewModel.lastScaleQuantity;
  if (resolved == null || !resolved.hasWarning) {
    return null;
  }
  final product = viewModel.lastScannedProductName ?? '';
  return switch (resolved.warning) {
    kScaleWarnNotFractional => l10n.scaleLabelWarnNotFractional(product),
    kScaleWarnUnitMismatch => l10n.scaleLabelWarnUnitMismatch(product),
    kScaleWarnNoUnitPrice => l10n.scaleLabelWarnNoUnitPrice(product),
    kScaleWarnRoundingDrift => l10n.scaleLabelWarnRoundingDrift(
      product,
      formatMoney(resolved.labelTotal ?? 0),
      formatMoney(resolved.rungTotal ?? 0),
    ),
    _ => null,
  };
}

class _BarcodeScanStatusLine extends StatelessWidget {
  const _BarcodeScanStatusLine({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final status = viewModel.barcodeScanStatus;
    // A scale label that could not be read the way the sticker intended still
    // rings — refusing the sale over a rounding step would be worse — but the
    // cashier is told, in the same line that would otherwise just say "added".
    final scaleWarning = status == BarcodeScanStatus.found
        ? _scaleWarningMessage(context, l10n, viewModel)
        : null;
    final message = switch (status) {
      BarcodeScanStatus.resolving => l10n.barcodeScanResolving,
      BarcodeScanStatus.found =>
        scaleWarning ??
            l10n.barcodeScanAdded(viewModel.lastScannedProductName ?? ''),
      BarcodeScanStatus.notFound => l10n.barcodeScanNotFound(
        viewModel.lastScannedBarcode ?? '',
      ),
      BarcodeScanStatus.error => l10n.barcodeScanError,
      BarcodeScanStatus.alreadyInCart => l10n.barcodeScanAlreadyInCart(
        viewModel.lastScannedProductName ?? '',
      ),
      BarcodeScanStatus.unavailable => l10n.barcodeScanUnitUnavailable(
        viewModel.lastScannedProductName ?? '',
      ),
      BarcodeScanStatus.idle => '',
    };
    final color = switch (status) {
      BarcodeScanStatus.found =>
        scaleWarning == null ? colors.primaryStrong : colors.warning,
      BarcodeScanStatus.alreadyInCart => colors.warning,
      BarcodeScanStatus.notFound ||
      BarcodeScanStatus.error ||
      BarcodeScanStatus.unavailable => colors.danger,
      BarcodeScanStatus.resolving || BarcodeScanStatus.idle => colors.mutedInk,
    };

    // What the server could read off a GS1 symbol but not act on — a lot it
    // has never received, a date that disagrees with the lot, a reader that
    // strips its separators. Already in Arabic, and more use to the cashier
    // than "unknown barcode". The reader one first: it breaks every scan.
    final scanWarning =
        viewModel.scannerConfigurationWarning ??
        viewModel.trackedScanWarnings.firstOrNull;
    final row = Row(
      children: [
        if (status == BarcodeScanStatus.resolving)
          const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          )
        else
          Icon(
            status == BarcodeScanStatus.found && scaleWarning == null
                ? Icons.check_circle_outline
                : status == BarcodeScanStatus.found
                ? Icons.scale_outlined
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
    final warningText = scanWarning?.message.trim() ?? '';
    if (warningText.isEmpty) {
      return row;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.qr_code_2_outlined, size: 18, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                warningText,
                key: const ValueKey('pos_scan_gs1_warning'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.warning),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The till's entry into the resale recharge flow.
///
/// Nothing here but the till's wording: the shape of the control — named
/// button for one provider, menu for several — is
/// [IntegrationActionButton], shared with the expenses screen so the two
/// entry points cannot drift apart.
///
/// Public so the screenshot harness and widget tests can render the real
/// button in a real catalog header rather than a stand-in.
class PosRechargeButton extends StatelessWidget {
  const PosRechargeButton({
    super.key,
    required this.providers,
    required this.onSelected,
  });

  final List<String> providers;
  final void Function(String providerKey) onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IntegrationActionButton(
      providers: providers,
      onSelected: onSelected,
      icon: Icons.sim_card_outlined,
      menuLabel: l10n.rechargeCatalogAction,
      labelFor: l10n.rechargeCatalogActionFor,
      buttonKey: const ValueKey('pos_recharge_button'),
    );
  }
}
