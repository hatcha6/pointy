import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/payments/record_payment_dialog.dart';
import '../../../shared/responsive/responsive.dart';
import '../../printing/views/print_audit_sheet.dart';
import '../view_models/invoice_details_view_model.dart';
import 'convert_quotation_dialog.dart';

class InvoiceDetailsScreen extends StatefulWidget {
  const InvoiceDetailsScreen({
    super.key,
    required this.saleRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.catalogRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final CatalogRepository catalogRepository;
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
    catalogRepository: widget.catalogRepository,
    initialOrder: widget.initialOrder,
    analyticsEngine: widget.analyticsEngine,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _sendSms(SaleOrder order) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _viewModel.sendInvoiceSms();
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.invoiceSendSmsSuccess : l10n.invoiceSendSmsError,
        ),
      ),
    );
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
              if ((order.customerPhone ?? '').trim().isNotEmpty)
                IconButton(
                  tooltip: l10n.invoiceSendSmsTooltip,
                  onPressed:
                      _viewModel.isLoading ? null : () => _sendSms(order),
                  icon: const Icon(Icons.sms_outlined),
                ),
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
              catalogRepository: widget.catalogRepository,
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
    required this.catalogRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
    this.viewModel,
    this.showHeader = false,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final CatalogRepository catalogRepository;
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
        catalogRepository: widget.catalogRepository,
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
                  onExchange: _canExchange(order)
                      ? _viewModel.exchangeItems
                      : null,
                  onProductSearch: _canExchange(order)
                      ? _viewModel.searchReplacementProducts
                      : null,
                  isRecordingPayment: _viewModel.isRecordingPayment,
                  onRecordPayment: _recordPayment,
                  isConverting: _viewModel.isConverting,
                  onConvert: widget.capabilities.canCheckoutSale
                      ? _convertQuotation
                      : null,
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

  /// An exchange rings up a replacement sale, so it also needs checkout rights.
  bool _canExchange(SaleOrder order) {
    return widget.capabilities.canCheckoutSale &&
        (order.canExchange || _canManagerAdjust(order));
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

  /// Opens the per-invoice payment dialog (cards allowed) and records the
  /// payment. Returns true on success so the shared surface can confirm.
  Future<bool> _recordPayment(SaleOrder order) async {
    final trustedTerminalIds =
        await widget.shopSettingsRepository.loadTrustedCardTerminalIds();
    if (!mounted) {
      return false;
    }
    final l10n = AppLocalizations.of(context)!;
    final result = await showRecordPaymentDialog(
      context,
      title: l10n.invoicePaymentTitle,
      maxAmount: order.balanceDue,
      balanceLabel: l10n.invoicePaymentBalanceValue(
        formatMoney(order.balanceDue),
      ),
      methods: customerPaymentMethodOptions(l10n),
      proofToggleLabel: l10n.invoicePaymentPrintProofLabel,
      trustedCardTerminalIds: trustedTerminalIds,
    );
    if (result == null) {
      return false;
    }

    return _viewModel.recordPayment(
      method: PaymentMethod.fromApiValue(result.methodApiValue),
      amount: result.amount,
      cardReceiptUrl: result.cardReceiptUrl,
      printProof: result.printProof,
    );
  }

  /// Opens the convert dialog for an OPEN quotation, performs the conversion,
  /// and on success replaces this screen with the NEW sale's details.
  Future<bool> _convertQuotation(SaleOrder order) async {
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<ConvertQuotationResult>(
      context: context,
      builder: (_) => ConvertQuotationDialog(order: order),
    );
    if (result == null) {
      return false;
    }

    final newOrder = await _viewModel.convertQuotation(
      saleType: result.saleType,
      amountReceived: result.amountReceived,
    );
    if (!mounted) {
      return newOrder != null;
    }

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            newOrder != null
                ? l10n.convertQuotationSuccess
                : l10n.convertQuotationError,
          ),
        ),
      );
    if (newOrder == null) {
      return false;
    }

    // Open the freshly-created sale, replacing the (now-converted) quotation.
    navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceDetailsScreen(
          saleRepository: widget.saleRepository,
          printingRepository: widget.printingRepository,
          shopSettingsRepository: widget.shopSettingsRepository,
          catalogRepository: widget.catalogRepository,
          initialOrder: newOrder,
          capabilities: widget.capabilities,
          analyticsEngine: widget.analyticsEngine,
        ),
      ),
    );
    return true;
  }
}

String _receiptNumber(AppLocalizations l10n, SaleOrder order) {
  final receiptNumber = order.receiptNumber;
  if (receiptNumber == null || receiptNumber.isEmpty) {
    return l10n.saleReceiptFallback;
  }
  return receiptNumber;
}
