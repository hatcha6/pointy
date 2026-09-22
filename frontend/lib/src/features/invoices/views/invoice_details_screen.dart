import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../cameras/widgets/invoice_footage_section.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
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
    this.surveillanceRepository,
    required this.catalogRepository,
    required this.contactRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
    this.onOpenCashier,
    this.onOpenRegisterSession,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  /// When given (and the shop has checkout cameras), the invoice grows a panel
  /// that plays what the camera saw as this sale was rung up. Null in previews
  /// and in shops with no DVR — the panel then does not exist at all.
  final SurveillanceRepository? surveillanceRepository;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final SaleOrder initialOrder;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  /// Jump from the summary to the cashier who rang the sale up, and to the
  /// drawer session it belongs to. Null leaves those rows as plain text.
  final ValueChanged<int>? onOpenCashier;
  final ValueChanged<int>? onOpenRegisterSession;

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
  void initState() {
    super.initState();
    // The invoice we were handed is a list row: totals and status, no line
    // items (see `OrderListSerializer`). Fetch the real document on open
    // instead of waiting for someone to press refresh.
    unawaited(_viewModel.loadInvoice());
  }

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
                  onPressed: _viewModel.isLoading
                      ? null
                      : () => _sendSms(order),
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
              surveillanceRepository: widget.surveillanceRepository,
              catalogRepository: widget.catalogRepository,
              contactRepository: widget.contactRepository,
              initialOrder: widget.initialOrder,
              capabilities: widget.capabilities,
              analyticsEngine: widget.analyticsEngine,
              onOpenCashier: widget.onOpenCashier,
              onOpenRegisterSession: widget.onOpenRegisterSession,
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
    this.surveillanceRepository,
    required this.catalogRepository,
    required this.contactRepository,
    required this.initialOrder,
    required this.capabilities,
    this.analyticsEngine,
    this.onOpenCashier,
    this.onOpenRegisterSession,
    this.viewModel,
    this.showHeader = false,
  });

  final SaleRepository saleRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  /// When given (and the shop has checkout cameras), the invoice grows a panel
  /// that plays what the camera saw as this sale was rung up. Null in previews
  /// and in shops with no DVR — the panel then does not exist at all.
  final SurveillanceRepository? surveillanceRepository;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final SaleOrder initialOrder;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  /// Jump from the summary to the cashier who rang the sale up, and to the
  /// drawer session it belongs to. Null leaves those rows as plain text.
  final ValueChanged<int>? onOpenCashier;
  final ValueChanged<int>? onOpenRegisterSession;

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
  void initState() {
    super.initState();
    // Only when this view owns the model: the pushed screen that lends us one
    // has already kicked off its own fetch, and a second would be a duplicate
    // request on every invoice opened on a phone.
    if (widget.viewModel == null) {
      unawaited(_viewModel.loadInvoice());
    }
  }

  @override
  void didUpdateWidget(InvoiceDetailsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The master-detail pane can reuse this element as the selection moves down
    // the list; follow the selection instead of showing the invoice we happened
    // to be built with until someone presses refresh.
    if (widget.viewModel == null &&
        widget.initialOrder.id != oldWidget.initialOrder.id) {
      unawaited(_viewModel.showOrder(widget.initialOrder));
    }
  }

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
            // Until the full document lands we only hold the list row, which
            // carries no line items — rendering it would say the invoice has no
            // products. Wait rather than lie.
            : (!_viewModel.hasLoadedDetail && _viewModel.isLoading)
            ? const PointyLoadingArea()
            : AdaptiveMaxWidth(
                width: AppContentWidth.detail,
                child: SaleOrderDetailsContent(
                  order: order,
                  onOpenCashier: widget.onOpenCashier,
                  onOpenRegisterSession: widget.onOpenRegisterSession,
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
                  isAssigningCustomer: _viewModel.isAssigningCustomer,
                  // Fixing who owes a debt is a sales-write operation — the
                  // same right that issues the invoice (sales.add_order).
                  onAssignCustomer: widget.capabilities.canCheckoutSale
                      ? _assignCustomer
                      : null,
                  isConverting: _viewModel.isConverting,
                  onConvert: widget.capabilities.canCheckoutSale
                      ? _convertQuotation
                      : null,
                  footer: widget.surveillanceRepository == null
                      ? null
                      : InvoiceFootageSection(
                          key: ValueKey('footage-${order.id}'),
                          repository: widget.surveillanceRepository!,
                          orderId: order.id,
                          capabilities: widget.capabilities,
                        ),
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
    final trustedTerminalIds = await widget.shopSettingsRepository
        .loadTrustedCardTerminalIds();
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
      moneyAccountId: result.moneyAccountId,
      printProof: result.printProof,
    );
  }

  /// Opens the customer picker and reassigns who owes this debt invoice.
  /// Canceling the picker is a silent no-op. Returns true on success.
  Future<bool> _assignCustomer(SaleOrder order) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (customer == null || !mounted) {
      return false;
    }

    final didAssign = await _viewModel.assignCustomer(customer.id);
    if (!mounted) {
      return didAssign;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            didAssign
                ? l10n.invoiceAssignCustomerSuccess
                : l10n.invoiceAssignCustomerError,
          ),
        ),
      );
    return didAssign;
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
          contactRepository: widget.contactRepository,
          initialOrder: newOrder,
          capabilities: widget.capabilities,
          analyticsEngine: widget.analyticsEngine,
          onOpenCashier: widget.onOpenCashier,
          onOpenRegisterSession: widget.onOpenRegisterSession,
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
