import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/sale_order.dart';
import '../../data/services/order_document_service.dart';
import '../components/components.dart';
import '../formatters.dart';
import '../order_totals.dart';
import 'pointy_quantity_stepper.dart'
    show PointyQuantityStepper, formatSaleQuantity;
import 'quantity_adjustment_dialog.dart';
import '../payment_labels.dart';
import '../query_controls/debounced_search_field.dart';
import '../responsive/responsive.dart';
import '../date_formatters.dart';

typedef SaleOrderReprintAction = Future<bool> Function(SaleOrder order);
typedef SaleOrderShareAction =
    Future<OrderDocumentActionStatus> Function(SaleOrder order);
typedef SaleOrderVoidAction =
    Future<bool> Function(SaleOrder order, String reason);
typedef SaleOrderReturnAction =
    Future<bool> Function(
      SaleOrder order,
      List<SaleReturnLineDraft> lines,
      String reason,
    );

/// Records a payment against a debt (credit) invoice. Returns true on success.
typedef SaleOrderRecordPaymentAction = Future<bool> Function(SaleOrder order);

/// Assigns or changes the customer who owes a debt (credit) invoice. The
/// callback opens the picker, performs the assignment, and surfaces its own
/// success/error feedback. Returns true on success.
typedef SaleOrderAssignCustomerAction = Future<bool> Function(SaleOrder order);

/// Converts an OPEN quotation into a sale. Returns true on success.
typedef SaleOrderConvertAction = Future<bool> Function(SaleOrder order);

/// Exchanges returned line(s) for replacement item(s). Returns true on success.
typedef SaleOrderExchangeAction =
    Future<bool> Function(SaleOrder order, SaleExchangeDraft draft);

/// Searches the catalog for replacement products in the exchange dialog.
typedef ExchangeProductSearch =
    Future<List<ExchangeProductOption>> Function(String query);

class SaleOrderDetailsContent extends StatefulWidget {
  const SaleOrderDetailsContent({
    super.key,
    required this.order,
    this.onReprint,
    this.onShare,
    this.onPrintAudit,
    this.onVoid,
    this.onReturn,
    this.onExchange,
    this.onProductSearch,
    this.onRecordPayment,
    this.onAssignCustomer,
    this.onConvert,
    this.isRecordingPayment = false,
    this.isAssigningCustomer = false,
    this.isConverting = false,
    this.showTitle = true,
    this.useInvoiceLabels = true,
    this.popOnSuccessfulAdjustment = true,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  final SaleOrder order;
  final SaleOrderReprintAction? onReprint;
  final SaleOrderShareAction? onShare;
  final VoidCallback? onPrintAudit;
  final SaleOrderVoidAction? onVoid;
  final SaleOrderReturnAction? onReturn;

  /// When provided (with [onProductSearch]) and the order is adjustable,
  /// surfaces an "استبدال" action that returns line(s) and rings up
  /// replacement item(s) in one operation.
  final SaleOrderExchangeAction? onExchange;
  final ExchangeProductSearch? onProductSearch;

  /// When provided and the order is an unpaid credit invoice, surfaces a
  /// prominent "آجل — المتبقّي X" callout with a "تسجيل دفعة" action.
  final SaleOrderRecordPaymentAction? onRecordPayment;

  /// When provided and the server allows it ([SaleOrder.canAssignCustomer]:
  /// a non-void debt invoice with no payment recorded yet), surfaces an
  /// assign/change-customer action. The callback opens the customer picker.
  final SaleOrderAssignCustomerAction? onAssignCustomer;

  /// When provided and the order is an OPEN quotation, surfaces a
  /// "تحويل إلى بيع" action. The callback opens the conversion dialog.
  final SaleOrderConvertAction? onConvert;
  final bool isRecordingPayment;
  final bool isAssigningCustomer;
  final bool isConverting;
  final bool showTitle;
  final bool useInvoiceLabels;
  final bool popOnSuccessfulAdjustment;
  final EdgeInsetsGeometry padding;

  @override
  State<SaleOrderDetailsContent> createState() =>
      _SaleOrderDetailsContentState();
}

class _SaleOrderDetailsContentState extends State<SaleOrderDetailsContent> {
  bool _isReprinting = false;
  bool _isSharing = false;
  bool _isAdjusting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = widget.order;

    return SingleChildScrollView(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showTitle) ...[
            Text(
              widget.useInvoiceLabels
                  ? l10n.invoiceDetailsTitle(_receiptNumber(l10n, order))
                  : l10n.saleReceiptTitle(_receiptNumber(l10n, order)),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
          ],
          if (_isCreditWithBalance) ...[
            _CreditBalanceCallout(
              order: order,
              isRecordingPayment: widget.isRecordingPayment || _isAdjusting,
              onRecordPayment: widget.onRecordPayment == null
                  ? null
                  : _recordPayment,
            ),
            const SizedBox(height: 12),
          ],
          if (_hasVisibleActions) ...[
            _ActionsSection(
              isBusy: _isBusy,
              isReprinting: _isReprinting,
              isSharing: _isSharing,
              isAdjusting: _isAdjusting,
              isConverting: widget.isConverting,
              isAssigningCustomer: widget.isAssigningCustomer,
              canReturn: _canReturn,
              canVoid: _canVoid,
              canExchange: _canExchange,
              canConvert: _canConvert,
              canAssignCustomer: _canAssignCustomer,
              hasCustomer: order.customer != null,
              onReprint: widget.onReprint == null ? null : _requestReprint,
              onShare: widget.onShare == null ? null : _shareInvoice,
              onPrintAudit: widget.onPrintAudit,
              onReturn: _canReturn ? _showReturnDialog : null,
              onVoid: _canVoid ? _showVoidDialog : null,
              onExchange: _canExchange ? _showExchangeDialog : null,
              onConvert: _canConvert ? _convertQuotation : null,
              onAssignCustomer: _canAssignCustomer ? _assignCustomer : null,
              useInvoiceLabels: widget.useInvoiceLabels,
            ),
            const SizedBox(height: 12),
          ],
          _SummarySection(order: order),
          const SizedBox(height: 16),
          _LinesSection(order: order),
          const SizedBox(height: 16),
          _PaymentsSection(order: order),
          const SizedBox(height: 16),
          _TotalsSection(order: order),
        ],
      ),
    );
  }

  bool get _isBusy => _isReprinting || _isSharing || _isAdjusting;

  bool get _hasReturnableItems {
    return widget.order.lines.any((line) => line.returnableQuantity > 0);
  }

  bool get _canReturn {
    return widget.onReturn != null &&
        widget.order.status == 'paid' &&
        _hasReturnableItems;
  }

  bool get _canVoid {
    return widget.onVoid != null &&
        widget.order.status == 'paid' &&
        _hasReturnableItems;
  }

  bool get _canExchange {
    return widget.onExchange != null &&
        widget.onProductSearch != null &&
        widget.order.status == 'paid' &&
        _hasReturnableItems;
  }

  bool get _hasVisibleActions {
    return widget.onReprint != null ||
        widget.onShare != null ||
        widget.onPrintAudit != null ||
        _canReturn ||
        _canVoid ||
        _canExchange ||
        _canConvert ||
        _canAssignCustomer;
  }

  /// The server flag already encodes the rule (non-void debt invoice with no
  /// payment recorded yet); the callback carries the operator's permission.
  bool get _canAssignCustomer {
    return widget.onAssignCustomer != null && widget.order.canAssignCustomer;
  }

  bool get _isCreditWithBalance {
    return widget.order.saleType == SaleType.credit &&
        widget.order.balanceDue > 0.005;
  }

  /// A quotation can be converted into a sale only while it is still OPEN.
  bool get _canConvert {
    return widget.onConvert != null &&
        widget.order.saleType == SaleType.quotation &&
        widget.order.status == 'open';
  }

  Future<void> _convertQuotation() async {
    await widget.onConvert!(widget.order);
  }

  /// The callback owns the picker and its success/error feedback; this only
  /// holds the section busy while it runs.
  Future<void> _assignCustomer() async {
    setState(() => _isAdjusting = true);
    await widget.onAssignCustomer!(widget.order);
    if (!mounted) {
      return;
    }
    setState(() => _isAdjusting = false);
  }

  Future<void> _recordPayment() async {
    final l10n = AppLocalizations.of(context)!;

    setState(() => _isAdjusting = true);
    final didRecord = await widget.onRecordPayment!(widget.order);
    if (!mounted) {
      return;
    }

    setState(() => _isAdjusting = false);
    if (didRecord) {
      _showMessage(l10n.invoicePaymentSuccess);
    }
  }

  Future<void> _requestReprint() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _isReprinting = true);
    final requested = await widget.onReprint!(widget.order);
    if (!mounted) {
      return;
    }

    setState(() => _isReprinting = false);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            requested
                ? widget.useInvoiceLabels
                      ? l10n.invoiceReprintQueuedMessage
                      : l10n.saleReprintQueuedMessage
                : widget.useInvoiceLabels
                ? l10n.invoiceReprintError
                : l10n.saleReprintError,
          ),
        ),
      );
  }

  Future<void> _shareInvoice() async {
    final l10n = AppLocalizations.of(context)!;

    setState(() => _isSharing = true);
    final status = await widget.onShare!(widget.order);
    if (!mounted) {
      return;
    }

    setState(() => _isSharing = false);
    if (status == OrderDocumentActionStatus.canceled) {
      return;
    }
    _showMessage(
      status == OrderDocumentActionStatus.completed
          ? widget.useInvoiceLabels
                ? l10n.invoiceShareSuccess
                : l10n.saleReceiptShareSuccess
          : widget.useInvoiceLabels
          ? l10n.invoiceShareError
          : l10n.saleReceiptShareError,
    );
  }

  Future<void> _showVoidDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.block_outlined),
          title: Text(l10n.saleVoidTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.saleVoidMessage),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                decoration: InputDecoration(
                  labelText: l10n.saleAdjustmentReasonLabel,
                  hintText: l10n.saleAdjustmentReasonHint,
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(reasonController.text.trim()),
              child: Text(l10n.confirmButton),
            ),
          ],
        );
      },
    );
    if (reason == null || widget.onVoid == null) {
      return;
    }

    await _runAdjustment(
      () => widget.onVoid!(widget.order, reason),
      successMessage: l10n.saleVoidSuccess,
      errorMessage: l10n.saleVoidError,
    );
  }

  Future<void> _showReturnDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showQuantityAdjustmentDialog(
      context,
      icon: Icons.keyboard_return_outlined,
      title: l10n.saleReturnTitle,
      emptyMessage: l10n.saleNoReturnableItems,
      reasonLabel: l10n.saleAdjustmentReasonLabel,
      reasonHint: l10n.saleAdjustmentReasonHint,
      options: [
        for (final line in widget.order.lines)
          if (line.returnableQuantity > 0)
            AdjustmentLineOption(
              lineId: line.id,
              title: saleLineDisplayName(line, l10n),
              subtitle: [
                l10n.saleLineQuantityAndPrice(
                  formatSaleQuantity(line.quantity),
                  formatMoney(line.unitPrice),
                ),
                if (line.returnedQuantity > 0)
                  l10n.saleLineReturnedQuantity(
                    formatSaleQuantity(line.returnedQuantity),
                    formatSaleQuantity(line.quantity),
                  ),
              ].join(' • '),
              maxQuantity: line.returnableQuantity,
              allowDecimal: true,
              decimalEntryTitle: l10n.posUnitQuantityLabel,
              decimalEntryHint: l10n.saleReturnQuantityHint(
                formatSaleQuantity(line.returnableQuantity),
              ),
            ),
      ],
    );
    if (result == null || widget.onReturn == null) {
      return;
    }
    if (result.lines.isEmpty) {
      _showMessage(l10n.saleReturnNoItemsSelected);
      return;
    }

    await _runAdjustment(
      () => widget.onReturn!(
        widget.order,
        [
          for (final selection in result.lines)
            SaleReturnLineDraft(
              lineId: selection.lineId,
              quantity: selection.quantity,
            ),
        ],
        result.reason,
      ),
      successMessage: l10n.saleReturnSuccess,
      errorMessage: l10n.saleReturnError,
    );
  }

  Future<void> _showExchangeDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final draft = await showDialog<SaleExchangeDraft>(
      context: context,
      builder: (context) => _SaleExchangeDialog(
        order: widget.order,
        onProductSearch: widget.onProductSearch!,
      ),
    );
    if (draft == null || widget.onExchange == null) {
      return;
    }

    await _runAdjustment(
      () => widget.onExchange!(widget.order, draft),
      successMessage: l10n.saleExchangeSuccess,
      errorMessage: l10n.saleExchangeError,
    );
  }

  Future<void> _runAdjustment(
    Future<bool> Function() action, {
    required String successMessage,
    required String errorMessage,
  }) async {
    setState(() => _isAdjusting = true);
    final didAdjust = await action();
    if (!mounted) {
      return;
    }

    setState(() => _isAdjusting = false);
    _showMessage(didAdjust ? successMessage : errorMessage);
    if (didAdjust && widget.popOnSuccessfulAdjustment) {
      Navigator.of(context).pop();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ActionsSection extends StatelessWidget {
  const _ActionsSection({
    required this.isBusy,
    required this.isReprinting,
    required this.isSharing,
    required this.isAdjusting,
    required this.isConverting,
    required this.isAssigningCustomer,
    required this.canReturn,
    required this.canVoid,
    required this.canExchange,
    required this.canConvert,
    required this.canAssignCustomer,
    required this.hasCustomer,
    this.onReprint,
    this.onShare,
    this.onPrintAudit,
    this.onReturn,
    this.onVoid,
    this.onExchange,
    this.onConvert,
    this.onAssignCustomer,
    required this.useInvoiceLabels,
  });

  final bool isBusy;
  final bool isReprinting;
  final bool isSharing;
  final bool isAdjusting;
  final bool isConverting;
  final bool isAssigningCustomer;
  final bool canReturn;
  final bool canVoid;
  final bool canExchange;
  final bool canConvert;
  final bool canAssignCustomer;
  final bool hasCustomer;
  final VoidCallback? onReprint;
  final VoidCallback? onShare;
  final VoidCallback? onPrintAudit;
  final VoidCallback? onReturn;
  final VoidCallback? onVoid;
  final VoidCallback? onExchange;
  final VoidCallback? onConvert;
  final VoidCallback? onAssignCustomer;
  final bool useInvoiceLabels;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.invoiceActionsTitle,
      icon: Icons.tune_outlined,
      child: ResponsiveActionBar(
        compactBreakpoint: AppBreakpoints.largePhoneMin,
        expandActionsOnCompact: false,
        spacing: 8,
        runSpacing: 8,
        actions: [
          if (canConvert)
            FilledButton.icon(
              onPressed: isBusy || isConverting ? null : onConvert,
              icon: isConverting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.swap_horiz_outlined),
              label: Text(l10n.convertQuotationButton),
            ),
          if (canAssignCustomer)
            OutlinedButton.icon(
              key: const ValueKey('assign_invoice_customer_button'),
              onPressed: isBusy || isAssigningCustomer
                  ? null
                  : onAssignCustomer,
              icon: isAssigningCustomer
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : Icon(
                      hasCustomer
                          ? Icons.manage_accounts_outlined
                          : Icons.person_add_alt_1_outlined,
                    ),
              label: Text(
                hasCustomer
                    ? l10n.invoiceChangeCustomerButton
                    : l10n.invoiceAssignCustomerButton,
              ),
            ),
          if (onReprint != null)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onReprint,
              icon: isReprinting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
              label: Text(
                isReprinting
                    ? useInvoiceLabels
                          ? l10n.invoiceReprintInProgressButton
                          : l10n.saleReprintInProgressButton
                    : useInvoiceLabels
                    ? l10n.invoiceReprintButton
                    : l10n.saleReprintButton,
              ),
            ),
          if (onShare != null)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onShare,
              icon: isSharing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share_outlined),
              label: Text(
                isSharing
                    ? useInvoiceLabels
                          ? l10n.invoiceShareInProgressButton
                          : l10n.saleReceiptShareInProgressButton
                    : useInvoiceLabels
                    ? l10n.invoiceShareButton
                    : l10n.saleReceiptShareButton,
              ),
            ),
          if (onPrintAudit != null)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onPrintAudit,
              icon: const Icon(Icons.manage_search_outlined),
              label: Text(l10n.printAuditButton),
            ),
          if (canReturn)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onReturn,
              icon: const Icon(Icons.keyboard_return_outlined),
              label: Text(l10n.saleReturnButton),
            ),
          if (canExchange)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onExchange,
              icon: const Icon(Icons.swap_horiz_outlined),
              label: Text(l10n.saleExchangeButton),
            ),
          if (canVoid)
            FilledButton.icon(
              onPressed: isBusy ? null : onVoid,
              icon: isAdjusting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.block_outlined),
              label: Text(l10n.saleVoidButton),
            ),
        ],
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  const _SummarySection({required this.order});

  final SaleOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.invoiceSummaryTitle,
      icon: Icons.fact_check_outlined,
      child: Column(
        children: [
          _DetailRow(
            label: l10n.invoiceNumberLabel,
            value: _receiptNumber(l10n, order),
          ),
          _DetailRow(
            label: l10n.invoiceStatusLabel,
            value: saleOrderStatusLabel(l10n, order.status),
          ),
          if (order.customerName != null && order.customerName!.isNotEmpty)
            _DetailRow(
              label: l10n.invoiceCustomerLabel,
              value: order.customerName!,
            ),
          if (order.registerSessionNumber != null &&
              order.registerSessionNumber!.isNotEmpty)
            _DetailRow(
              label: l10n.invoiceRegisterSessionLabel,
              value: order.registerSessionNumber!,
            ),
          _DetailRow(
            label: l10n.invoiceLineCountLabel,
            value: l10n.lineItemCount(order.lines.length),
          ),
          if (order.createdAt != null)
            _DetailRow(
              label: l10n.invoiceCreatedAtLabel,
              value: formatDateTime(order.createdAt!),
            ),
          if (order.updatedAt != null)
            _DetailRow(
              label: l10n.invoiceUpdatedAtLabel,
              value: formatDateTime(order.updatedAt!),
            ),
          if (order.profit != null)
            _DetailRow(
              label: l10n.invoiceProfitLabel,
              value: [
                formatMoney(order.profit!),
                if (order.profitMarginPercent != null)
                  l10n.invoiceProfitMarginValue(
                    order.profitMarginPercent!.toStringAsFixed(2),
                  ),
              ].join(' • '),
            ),
        ],
      ),
    );
  }
}

class _LinesSection extends StatelessWidget {
  const _LinesSection({required this.order});

  final SaleOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.invoiceLinesTitle,
      icon: Icons.inventory_2_outlined,
      child: order.lines.isEmpty
          ? Text(l10n.invoiceLinesEmpty)
          : Column(
              children: [
                for (final (index, line) in order.lines.indexed) ...[
                  if (index > 0) const SizedBox(height: 8),
                  PointyDataRow(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: saleLineDisplayName(line, l10n),
                    subtitle: [
                      l10n.saleLineQuantityAndPrice(
                        formatSaleQuantity(line.quantity),
                        formatMoney(line.unitPrice),
                      ),
                      if (line.profit != null)
                        l10n.invoiceProfitValue(formatMoney(line.profit!)),
                      if (line.discountTotal > 0)
                        l10n.discountLineValue(formatMoney(line.discountTotal)),
                      if (line.returnedQuantity > 0)
                        l10n.saleLineReturnedQuantity(
                          formatSaleQuantity(line.returnedQuantity),
                          formatSaleQuantity(line.quantity),
                        ),
                    ].join(' • '),
                    trailing: Text(formatMoney(line.total)),
                  ),
                ],
              ],
            ),
    );
  }
}

class _PaymentsSection extends StatelessWidget {
  const _PaymentsSection({required this.order});

  final SaleOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.salePaymentsTitle,
      icon: Icons.payments_outlined,
      child: order.payments.isEmpty
          ? Text(l10n.invoicePaymentsEmpty)
          : Column(
              children: [
                for (final (index, payment) in order.payments.indexed) ...[
                  if (index > 0) const SizedBox(height: 8),
                  PointyDataRow(
                    leading: Icon(paymentMethodIcon(payment.method)),
                    title: paymentMethodLabel(l10n, payment.method),
                    subtitle: [
                      if (payment.createdAt != null)
                        formatDateTime(payment.createdAt!),
                      if (payment.commissionAmount > 0)
                        l10n.salePaymentCommission(
                          formatMoney(payment.commissionAmount),
                          payment.commissionPercent.toStringAsFixed(2),
                        ),
                    ].join(' • '),
                    trailing: Text(formatMoney(payment.amount)),
                  ),
                ],
              ],
            ),
    );
  }
}

class _TotalsSection extends StatelessWidget {
  const _TotalsSection({required this.order});

  final SaleOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.invoiceTotalsTitle,
      icon: Icons.calculate_outlined,
      child: Column(
        children: [
          TotalRow(label: l10n.subtotal, value: order.subtotal),
          if (order.discountTotal > 0)
            TotalRow(
              label: l10n.discountTotalLabel,
              value: -order.discountTotal,
            ),
          if (order.appliedDiscounts.isNotEmpty)
            for (final discount in order.appliedDiscounts)
              TotalRow(
                label: discount.couponCode.isEmpty
                    ? discount.ruleName
                    : l10n.discountCouponAppliedLabel(discount.couponCode),
                value: -discount.discountAmount,
              ),
          const Divider(),
          TotalRow(label: l10n.total, value: order.total, isStrong: true),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// One chosen replacement product line inside [_SaleExchangeDialog].
class _ExchangeReplacement {
  _ExchangeReplacement({required this.option});

  final ExchangeProductOption option;
  double quantity = 1;
}

/// Returns the chosen original line(s) and rings up replacement item(s) in one
/// step. Outbound lines reuse the shared [AdjustmentLineStepper]; replacements
/// are picked via a catalog search ([SaleOrderDetailsContent.onProductSearch]),
/// priced at current price, with a live net-difference summary. The backend is
/// authoritative on money; the summary is an estimate from current prices.
class _SaleExchangeDialog extends StatefulWidget {
  const _SaleExchangeDialog({required this.order, required this.onProductSearch});

  final SaleOrder order;
  final ExchangeProductSearch onProductSearch;

  @override
  State<_SaleExchangeDialog> createState() => _SaleExchangeDialogState();
}

class _SaleExchangeDialogState extends State<_SaleExchangeDialog> {
  late final Map<int, double> _outbound = {
    for (final line in widget.order.lines) line.id: 0,
  };
  final List<_ExchangeReplacement> _replacements = [];
  final TextEditingController _reasonController = TextEditingController();
  PaymentMethod _settlement = PaymentMethod.cash;
  String _query = '';
  List<ExchangeProductOption> _results = const [];
  bool _searching = false;
  bool _showError = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  /// Runs as the user types (the field debounces). An empty query clears the
  /// results; a stale response (the query moved on while awaiting) is discarded
  /// so an earlier search can't overwrite a newer one.
  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _query = '';
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() {
      _query = trimmed;
      _searching = true;
    });
    final results = await widget.onProductSearch(trimmed);
    if (!mounted || trimmed != _query) {
      return;
    }
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  void _addReplacement(ExchangeProductOption option) {
    setState(() {
      final index = _replacements.indexWhere(
        (r) => r.option.variantId == option.variantId,
      );
      if (index >= 0) {
        _replacements[index].quantity += 1;
      } else {
        _replacements.add(_ExchangeReplacement(option: option));
      }
      _showError = false;
    });
  }

  double get _outboundValue {
    var total = 0.0;
    for (final line in widget.order.lines) {
      total += (_outbound[line.id] ?? 0) * line.unitPrice;
    }
    return total;
  }

  double get _replacementValue {
    var total = 0.0;
    for (final replacement in _replacements) {
      total += replacement.quantity * replacement.option.unitPrice;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final sectionStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final returnableLines = widget.order.lines
        .where((line) => line.returnableQuantity > 0)
        .toList(growable: false);
    final net = _replacementValue - _outboundValue;

    return AlertDialog(
      icon: const Icon(Icons.swap_horiz_outlined),
      title: Text(l10n.saleExchangeTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.saleExchangeReturnedSectionTitle, style: sectionStyle),
              if (returnableLines.isEmpty)
                Text(l10n.saleNoReturnableItems)
              else
                for (final line in returnableLines)
                  AdjustmentLineStepper(
                    option: AdjustmentLineOption(
                      lineId: line.id,
                      title: saleLineDisplayName(line, l10n),
                      subtitle: l10n.saleLineQuantityAndPrice(
                        formatSaleQuantity(line.quantity),
                        formatMoney(line.unitPrice),
                      ),
                      maxQuantity: line.returnableQuantity,
                      allowDecimal: true,
                      decimalEntryTitle: l10n.posUnitQuantityLabel,
                      decimalEntryHint: l10n.saleReturnQuantityHint(
                        formatSaleQuantity(line.returnableQuantity),
                      ),
                    ),
                    value: _outbound[line.id] ?? 0,
                    onChanged: (value) {
                      setState(() => _outbound[line.id] = value);
                    },
                  ),
              const Divider(height: 24),
              Text(l10n.saleExchangeReplacementSectionTitle, style: sectionStyle),
              const SizedBox(height: 8),
              DebouncedSearchField(
                value: _query,
                hintText: l10n.saleExchangeSearchLabel,
                clearTooltip: l10n.clearSearchTooltip,
                onChanged: _runSearch,
              ),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: PointyProgressBar(minHeight: 2),
                ),
              if (_results.isNotEmpty)
                for (final option in _results)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(option.label),
                    subtitle: Text(formatMoney(option.unitPrice)),
                    trailing: IconButton(
                      tooltip: l10n.addOneTooltip,
                      onPressed: () => _addReplacement(option),
                      icon: const Icon(Icons.add),
                    ),
                  )
              else if (!_searching && _query.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.saleExchangeNoResults,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final (index, replacement) in _replacements.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(replacement.option.label),
                  subtitle: Text(formatMoney(replacement.option.unitPrice)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PointyQuantityStepper(
                        quantity: replacement.quantity,
                        incrementTooltip: l10n.addOneTooltip,
                        decrementTooltip: l10n.removeOneTooltip,
                        onDecrement: () {
                          setState(() {
                            if (replacement.quantity <= 1) {
                              _replacements.removeAt(index);
                            } else {
                              replacement.quantity -= 1;
                            }
                          });
                        },
                        onIncrement: () {
                          setState(() => replacement.quantity += 1);
                        },
                      ),
                      IconButton(
                        tooltip: l10n.removeOneTooltip,
                        onPressed: () {
                          setState(() => _replacements.removeAt(index));
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              if (_showError) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.saleExchangeInvalidError,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              Text(l10n.saleExchangeSettlementLabel, style: sectionStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final method in PaymentMethod.values)
                    ChoiceChip(
                      label: Text(paymentMethodLabel(l10n, method)),
                      avatar: Icon(paymentMethodIcon(method), size: 18),
                      selected: _settlement == method,
                      onSelected: (_) => setState(() => _settlement = method),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _ExchangeNetSummary(net: net),
              const SizedBox(height: 12),
              AdjustmentReasonField(
                controller: _reasonController,
                label: l10n.saleAdjustmentReasonLabel,
                hint: l10n.saleAdjustmentReasonHint,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.confirmButton)),
      ],
    );
  }

  void _submit() {
    final lines = [
      for (final line in widget.order.lines)
        if ((_outbound[line.id] ?? 0) > 0)
          SaleReturnLineDraft(
            lineId: line.id,
            quantity: _outbound[line.id]!,
          ),
    ];
    final replacementLines = [
      for (final replacement in _replacements)
        if (replacement.quantity > 0)
          SaleExchangeReplacementLineDraft(
            variantId: replacement.option.variantId,
            quantity: replacement.quantity,
          ),
    ];
    if (lines.isEmpty || replacementLines.isEmpty) {
      setState(() => _showError = true);
      return;
    }
    Navigator.of(context).pop(
      SaleExchangeDraft(
        lines: lines,
        replacementLines: replacementLines,
        settlementMethod: _settlement.apiValue,
        reason: _reasonController.text.trim(),
      ),
    );
  }
}

/// Live "customer pays / refund / even" summary for the exchange dialog.
class _ExchangeNetSummary extends StatelessWidget {
  const _ExchangeNetSummary({required this.net});

  final double net;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final String label;
    if (net > 0.005) {
      label = l10n.saleExchangeNetPay(formatMoney(net));
    } else if (net < -0.005) {
      label = l10n.saleExchangeNetRefund(formatMoney(-net));
    } else {
      label = l10n.saleExchangeNetEven;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "آجل — المتبقّي X" callout shown on a debt invoice that still carries a
/// balance, with a primary "تسجيل دفعة" action when [onRecordPayment] is set.
class _CreditBalanceCallout extends StatelessWidget {
  const _CreditBalanceCallout({
    required this.order,
    required this.isRecordingPayment,
    this.onRecordPayment,
  });

  final SaleOrder order;
  final bool isRecordingPayment;
  final VoidCallback? onRecordPayment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailCallout(
      icon: Icons.account_balance_wallet_outlined,
      tone: PointyCalloutTone.warning,
      title: l10n.invoiceCreditBalanceCalloutTitle(
        formatMoney(order.balanceDue),
      ),
      message: order.amountPaid > 0.005
          ? l10n.invoiceCreditBalancePaidValue(formatMoney(order.amountPaid))
          : l10n.invoiceCreditBalanceCalloutBody,
      trailing: onRecordPayment == null
          ? null
          : FilledButton.icon(
              key: const ValueKey('record_invoice_payment_button'),
              onPressed: isRecordingPayment ? null : onRecordPayment,
              icon: isRecordingPayment
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_card_outlined),
              label: Text(l10n.recordInvoicePaymentButton),
            ),
    );
  }
}

String saleLineDisplayName(SaleOrderLine line, AppLocalizations l10n) {
  final productName = line.productName;
  final variantName = line.variantName;
  if (productName != null &&
      productName.isNotEmpty &&
      variantName != null &&
      variantName.isNotEmpty &&
      variantName != productName) {
    return '$productName - $variantName';
  }
  if (productName != null && productName.isNotEmpty) {
    return productName;
  }
  if (variantName != null && variantName.isNotEmpty) {
    return variantName;
  }
  return l10n.saleProductFallback(line.productId);
}

String saleOrderStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'open' => l10n.invoiceStatusOpen,
    'paid' => l10n.invoiceStatusPaid,
    'void' => l10n.invoiceStatusVoid,
    _ => status,
  };
}

IconData saleOrderStatusIcon(String status) {
  return switch (status) {
    'open' => Icons.pending_outlined,
    'paid' => Icons.check_circle_outline,
    'void' => Icons.block_outlined,
    _ => Icons.receipt_long_outlined,
  };
}

String _receiptNumber(AppLocalizations l10n, SaleOrder order) {
  final receiptNumber = order.receiptNumber;
  if (receiptNumber == null || receiptNumber.isEmpty) {
    return l10n.saleReceiptFallback;
  }
  return receiptNumber;
}
