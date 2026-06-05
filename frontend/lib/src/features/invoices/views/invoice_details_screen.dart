import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/invoice_details_view_model.dart';

class InvoiceDetailsScreen extends StatefulWidget {
  const InvoiceDetailsScreen({
    super.key,
    required this.saleRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
  });

  final SaleRepository saleRepository;
  final SaleOrder initialOrder;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  @override
  State<InvoiceDetailsScreen> createState() => _InvoiceDetailsScreenState();
}

class _InvoiceDetailsScreenState extends State<InvoiceDetailsScreen> {
  late final InvoiceDetailsViewModel _viewModel = InvoiceDetailsViewModel(
    widget.saleRepository,
    initialOrder: widget.initialOrder,
    analyticsEngine: widget.analyticsEngine,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final order = _viewModel.order;

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.invoiceDetailsTitle(_receiptNumber(l10n, order))),
            actions: [
              IconButton(
                tooltip: l10n.refreshInvoiceDetailsTooltip,
                onPressed: _viewModel.isLoading ? null : _viewModel.loadInvoice,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: _viewModel.hasLoadError
                ? Center(child: Text(l10n.invoiceDetailsLoadError))
                : AdaptiveMaxWidth(
                    width: AppContentWidth.detail,
                    child: SaleOrderDetailsContent(
                      order: order,
                      showTitle: false,
                      popOnSuccessfulAdjustment: false,
                      padding: const EdgeInsets.all(16),
                      onReprint: _viewModel.requestReprint,
                      onVoid: _canVoid(order) ? _viewModel.voidInvoice : null,
                      onReturn: _canReturn(order)
                          ? _viewModel.returnItems
                          : null,
                    ),
                  ),
          ),
        );
      },
    );
  }

  bool _canVoid(SaleOrder order) {
    return order.canVoid || _canManagerAdjust(order);
  }

  bool _canReturn(SaleOrder order) {
    return order.canReturn || _canManagerAdjust(order);
  }

  bool _canManagerAdjust(SaleOrder order) {
    return widget.capabilities.canManageShopSettings &&
        order.status == 'paid' &&
        order.lines.any((line) => line.returnableQuantity > 0);
  }

  String _receiptNumber(AppLocalizations l10n, SaleOrder order) {
    final receiptNumber = order.receiptNumber;
    if (receiptNumber == null || receiptNumber.isEmpty) {
      return l10n.saleReceiptFallback;
    }
    return receiptNumber;
  }
}
