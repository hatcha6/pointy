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
import '../../../shared/order/sale_order_details_content.dart';
import '../../invoices/view_models/invoice_details_view_model.dart';
import '../../../shared/components/pointy_progress.dart';

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
    this.analyticsEngine,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final CatalogRepository catalogRepository;
  final AuthorizationCapabilities capabilities;
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
  bool _notFound = false;

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
      _notFound = false;
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
        case Error<SaleOrder>():
          _viewModel?.dispose();
          _viewModel = null;
          _notFound = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.returnsLookupTitle)),
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
                    child: FilledButton.icon(
                      onPressed: _searching ? null : _lookup,
                      icon: _searching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: PointySpinner(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      label: Text(l10n.returnsLookupSearchButton),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _notFound
                  ? Icons.search_off_outlined
                  : Icons.swap_horiz_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              _notFound ? l10n.returnsLookupNotFound : l10n.returnsLookupEmpty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
