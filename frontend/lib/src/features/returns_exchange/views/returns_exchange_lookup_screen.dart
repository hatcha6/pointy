import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/return_window_label.dart';
import '../../invoices/view_models/invoice_details_view_model.dart';
import '../view_models/returns_desk_view_model.dart';
import 'returns_search_results.dart';

/// Returns desk: one search box for whatever the customer brought — the
/// receipt (its number, the end of it, or its QR code), the goods (barcode,
/// SKU, IMEI or name, sold inside the shop's return window), or their phone
/// number — then return or exchange items on the invoice it leads to, without
/// access to the full invoice list. Gated by
/// [AuthorizationCapabilities.canProcessReturnsByLookup]; the backend
/// (``sales.process_return_lookup``) enforces the scope and the window.
class ReturnsExchangeLookupScreen extends StatefulWidget {
  const ReturnsExchangeLookupScreen({
    super.key,
    required this.saleRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.catalogRepository,
    this.trackedStockRepository,
    required this.capabilities,
    required this.navigation,
    this.analyticsEngine,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final CatalogRepository catalogRepository;

  /// The shelf an exchange picks a serialized replacement from; see
  /// [SaleOrderDetailsContent.trackedStockRepository].
  final TrackedStockRepository? trackedStockRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final AnalyticsEngine? analyticsEngine;

  @override
  State<ReturnsExchangeLookupScreen> createState() =>
      _ReturnsExchangeLookupScreenState();
}

class _ReturnsExchangeLookupScreenState
    extends State<ReturnsExchangeLookupScreen> {
  final TextEditingController _queryController = TextEditingController();
  late final ReturnsDeskViewModel _viewModel = ReturnsDeskViewModel(
    widget.saleRepository,
    detailsFactory: _detailsFor,
  )..addListener(_reportOpenFailure);

  @override
  void dispose() {
    _queryController.dispose();
    _viewModel
      ..removeListener(_reportOpenFailure)
      ..dispose();
    super.dispose();
  }

  InvoiceDetailsViewModel _detailsFor(SaleOrder order) {
    return InvoiceDetailsViewModel(
      widget.saleRepository,
      printingRepository: widget.printingRepository,
      shopSettingsRepository: widget.shopSettingsRepository,
      catalogRepository: widget.catalogRepository,
      initialOrder: order,
      analyticsEngine: widget.analyticsEngine,
    );
  }

  Future<void> _search() async {
    await _viewModel.search(_queryController.text);
    if (!mounted) {
      return;
    }
    // The next scan replaces this one instead of appending to it.
    _queryController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _queryController.text.length,
    );
  }

  void _reportOpenFailure() {
    if (_viewModel.openFailure == null || !mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.returnsSearchOpenFailed)));
    _viewModel.dismissOpenFailure();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: AppNavigationDestination.returnsExchange,
        navigation: widget.navigation,
      ),
      appBar: PointyAppBar(
        leading: const PointyNavigationMenuButton(),
        title: Text(l10n.returnsLookupTitle),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _viewModel,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSearchBar(l10n),
                Expanded(child: _buildBody(l10n)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSearchBar(AppLocalizations l10n) {
    final searching = _viewModel.isSearching;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _queryController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: l10n.returnsLookupFieldLabel,
                hintText: l10n.returnsLookupPrompt,
                prefixIcon: const Icon(Icons.search),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 56,
            // Search stays inert until there is something to look up, so an
            // empty tap reads as "nothing to search yet" instead of a frozen
            // screen.
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _queryController,
              builder: (context, value, _) {
                final canSearch = !searching && value.text.trim().isNotEmpty;
                return FilledButton.icon(
                  onPressed: canSearch ? _search : null,
                  icon: searching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(l10n.returnsLookupSearchButton),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    final details = _viewModel.details;
    if (details != null) {
      return _buildInvoice(l10n, details);
    }
    final failure = _viewModel.searchFailure;
    if (failure != null) {
      return PointyErrorState(
        icon: Icons.cloud_off_outlined,
        title: l10n.returnsLookupFailedTitle,
        message: l10n.returnsLookupFailedMessage,
        action: FilledButton.icon(
          onPressed: _viewModel.isSearching ? null : _viewModel.retry,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }
    final result = _viewModel.result;
    if (result == null) {
      return PointyEmptyState(
        icon: Icons.swap_horiz_outlined,
        title: l10n.returnsLookupEmpty,
      );
    }
    if (result.isEmpty) {
      return PointyEmptyState(
        icon: Icons.search_off_outlined,
        title: l10n.returnsLookupNotFound,
        message: result.windowHours == 0
            ? l10n.returnsSearchWindowClosedHint
            : l10n.returnsLookupNotFoundHint(
                formatReturnWindow(l10n, result.windowHours),
              ),
      );
    }
    return ReturnsSearchResults(
      result: result,
      openingOrderId: _viewModel.openingOrderId,
      onOpenInvoice: _viewModel.openInvoice,
    );
  }

  Widget _buildInvoice(AppLocalizations l10n, InvoiceDetailsViewModel details) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_viewModel.canGoBackToResults)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: TextButton.icon(
                onPressed: _viewModel.isSearching
                    ? null
                    : _viewModel.backToResults,
                icon: const BackButtonIcon(),
                label: Text(l10n.returnsSearchBackToResults),
              ),
            ),
          ),
        Expanded(
          child: ListenableBuilder(
            listenable: details,
            builder: (context, _) {
              return SaleOrderDetailsContent(
                // A different invoice is a different document: start its
                // dialogs and busy flags over.
                key: ObjectKey(details),
                order: details.order,
                popOnSuccessfulAdjustment: false,
                preselectedLineId: _viewModel.preselectedLineId,
                onReprint: details.requestReprint,
                onVoid: details.voidInvoice,
                onReturn: details.returnItems,
                onExchange: widget.capabilities.canCheckoutSale
                    ? details.exchangeItems
                    : null,
                onProductSearch: widget.capabilities.canCheckoutSale
                    ? details.searchReplacementProducts
                    : null,
                trackedStockRepository: widget.trackedStockRepository,
              );
            },
          ),
        ),
      ],
    );
  }
}
