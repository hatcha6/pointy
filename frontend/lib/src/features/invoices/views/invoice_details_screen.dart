import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/responsive/responsive.dart';
import '../../printing/views/print_audit_sheet.dart';
import '../view_models/invoice_details_view_model.dart';

class InvoiceDetailsScreen extends StatefulWidget {
  const InvoiceDetailsScreen({
    super.key,
    required this.saleRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final SaleOrder initialOrder;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  @override
  State<InvoiceDetailsScreen> createState() => _InvoiceDetailsScreenState();
}

class _InvoiceDetailsScreenState extends State<InvoiceDetailsScreen> {
  late final InvoiceDetailsViewModel _viewModel = InvoiceDetailsViewModel(
    widget.saleRepository,
    printingRepository: widget.printingRepository,
    shopSettingsRepository: widget.shopSettingsRepository,
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
            child: InvoiceDetailsView(
              saleRepository: widget.saleRepository,
              printingRepository: widget.printingRepository,
              shopSettingsRepository: widget.shopSettingsRepository,
              initialOrder: widget.initialOrder,
              capabilities: widget.capabilities,
              analyticsEngine: widget.analyticsEngine,
              viewModel: _viewModel,
            ),
          ),
        );
      },
    );
  }
}

/// Embeddable invoice details body: used by [InvoiceDetailsScreen] as a pushed
/// route on compact widths, and by the invoices master-detail pane on desktop.
class InvoiceDetailsView extends StatefulWidget {
  const InvoiceDetailsView({
    super.key,
    required this.saleRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
    this.viewModel,
    this.showHeader = false,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final SaleOrder initialOrder;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  /// When provided, the view uses this view model and does not create or
  /// dispose its own — the owner ([InvoiceDetailsScreen]) manages it.
  final InvoiceDetailsViewModel? viewModel;

  /// When true, renders a compact header row (title + refresh) inside the
  /// view. Used when embedded in a master-detail pane; the pushed screen
  /// keeps its AppBar instead.
  final bool showHeader;

  @override
  State<InvoiceDetailsView> createState() => _InvoiceDetailsViewState();
}

class _InvoiceDetailsViewState extends State<InvoiceDetailsView> {
  late final InvoiceDetailsViewModel _viewModel =
      widget.viewModel ??
      InvoiceDetailsViewModel(
        widget.saleRepository,
        printingRepository: widget.printingRepository,
        shopSettingsRepository: widget.shopSettingsRepository,
        initialOrder: widget.initialOrder,
        analyticsEngine: widget.analyticsEngine,
      );

  @override
  void dispose() {
    if (widget.viewModel == null) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final order = _viewModel.order;

        final body = _viewModel.hasLoadError
            ? Center(child: Text(l10n.invoiceDetailsLoadError))
            : AdaptiveMaxWidth(
                width: AppContentWidth.detail,
                child: SaleOrderDetailsContent(
                  order: order,
                  showTitle: false,
                  popOnSuccessfulAdjustment: false,
                  padding: const EdgeInsets.all(16),
                  onReprint: _viewModel.requestReprint,
                  onShare: _viewModel.shareInvoice,
                  onPrintAudit: () => _showPrintAudit(order),
                  onVoid: _canVoid(order) ? _viewModel.voidInvoice : null,
                  onReturn: _canReturn(order) ? _viewModel.returnItems : null,
                ),
              );

        if (!widget.showHeader) {
          return body;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.invoiceDetailsTitle(_receiptNumber(l10n, order)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.refreshInvoiceDetailsTooltip,
                    onPressed: _viewModel.isLoading
                        ? null
                        : _viewModel.loadInvoice,
                    icon: const Icon(Icons.sync),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
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

  Future<void> _showPrintAudit(SaleOrder order) {
    final l10n = AppLocalizations.of(context)!;
    return showPrintAuditSheet(
      context: context,
      printingRepository: widget.printingRepository,
      documentType: PrintAuditDocumentType.saleOrder,
      documentId: order.id,
      documentNumber: _receiptNumber(l10n, order),
    );
  }
}

String _receiptNumber(AppLocalizations l10n, SaleOrder order) {
  final receiptNumber = order.receiptNumber;
  if (receiptNumber == null || receiptNumber.isEmpty) {
    return l10n.saleReceiptFallback;
  }
  return receiptNumber;
}
