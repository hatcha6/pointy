import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/api_session.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/shell/shell.dart';
import '../../invoices/view_models/invoice_details_view_model.dart';

/// Returns desk: enter an invoice's receipt number to fetch that single invoice
/// and return or exchange items on it — without access to the full invoice
/// list. Gated by [AuthorizationCapabilities.canProcessReturnsByLookup]; the
/// backend (``sales.process_return_lookup``) enforces the scope and the
/// cashier-window override.
class ReturnsExchangeLookupScreen extends StatefulWidget {
  const ReturnsExchangeLookupScreen({
    super.key,
    required this.saleRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.catalogRepository,
    required this.capabilities,
    required this.navigation,
    this.analyticsEngine,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final CatalogRepository catalogRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final AnalyticsEngine? analyticsEngine;

  @override
  State<ReturnsExchangeLookupScreen> createState() =>
      _ReturnsExchangeLookupScreenState();
}

class _ReturnsExchangeLookupScreenState
    extends State<ReturnsExchangeLookupScreen> {
  final TextEditingController _receiptController = TextEditingController();
  InvoiceDetailsViewModel? _viewModel;
  bool _searching = false;

  /// The failure behind the last lookup, or null when none failed. A 404
  /// means the receipt number genuinely matches no invoice; anything else
  /// (offline, server error) must not be reported as a missing invoice —
  /// the cashier would tell a customer their real receipt is invalid.
  Exception? _failure;

  bool get _receiptNotFound {
    final failure = _failure;
    return failure is PosApiException && failure.statusCode == 404;
  }

  @override
  void dispose() {
    _receiptController.dispose();
    _viewModel?.dispose();
    super.dispose();
  }

  InvoiceDetailsViewModel _viewModelFor(SaleOrder order) {
    return InvoiceDetailsViewModel(
      widget.saleRepository,
      printingRepository: widget.printingRepository,
      shopSettingsRepository: widget.shopSettingsRepository,
      catalogRepository: widget.catalogRepository,
      initialOrder: order,
      analyticsEngine: widget.analyticsEngine,
    );
  }

  Future<void> _lookup() async {
    final receipt = _receiptController.text.trim();
    if (receipt.isEmpty) {
      return;
    }
    setState(() {
      _searching = true;
      _failure = null;
    });
    final result = await widget.saleRepository.lookupByReceipt(receipt);
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = false;
      switch (result) {
        case Ok<SaleOrder>(value: final order):
          _viewModel?.dispose();
          _viewModel = _viewModelFor(order);
        case Error<SaleOrder>(exception: final exception):
          _viewModel?.dispose();
          _viewModel = null;
          _failure = exception;
      }
    });
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _receiptController,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        labelText: l10n.returnsLookupFieldLabel,
                        hintText: l10n.returnsLookupPrompt,
                        prefixIcon: const Icon(Icons.receipt_long_outlined),
                      ),
                      onSubmitted: (_) => _lookup(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    // Search stays inert until there is a receipt number to look
                    // up, so an empty tap reads as "nothing to search yet"
                    // instead of a frozen screen.
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _receiptController,
                      builder: (context, value, _) {
                        final canSearch =
                            !_searching && value.text.trim().isNotEmpty;
                        return FilledButton.icon(
                          onPressed: canSearch ? _lookup : null,
                          icon: _searching
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
            ),
            Expanded(child: _buildResult(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(AppLocalizations l10n) {
    final viewModel = _viewModel;
    if (viewModel != null) {
      return ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          return SaleOrderDetailsContent(
            order: viewModel.order,
            popOnSuccessfulAdjustment: false,
            onReprint: viewModel.requestReprint,
            onVoid: viewModel.voidInvoice,
            onReturn: viewModel.returnItems,
            onExchange: widget.capabilities.canCheckoutSale
                ? viewModel.exchangeItems
                : null,
            onProductSearch: widget.capabilities.canCheckoutSale
                ? viewModel.searchReplacementProducts
                : null,
          );
        },
      );
    }
    if (_failure != null && !_receiptNotFound) {
      return PointyErrorState(
        icon: Icons.cloud_off_outlined,
        title: l10n.returnsLookupFailedTitle,
        message: l10n.returnsLookupFailedMessage,
        action: FilledButton.icon(
          onPressed: _searching ? null : _lookup,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (_receiptNotFound) {
      return PointyEmptyState(
        icon: Icons.search_off_outlined,
        title: l10n.returnsLookupNotFound,
        message: l10n.returnsLookupNotFoundHint,
      );
    }
    return PointyEmptyState(
      icon: Icons.swap_horiz_outlined,
      title: l10n.returnsLookupEmpty,
    );
  }
}
