import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/sale_order.dart';
import '../../data/services/order_document_service.dart';
import '../components/components.dart';
import '../formatters.dart';
import '../order_totals.dart';
import 'pointy_quantity_stepper.dart' show formatSaleQuantity;
import '../payment_labels.dart';
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

/// Converts an OPEN quotation into a sale. Returns true on success.
typedef SaleOrderConvertAction = Future<bool> Function(SaleOrder order);

class SaleOrderDetailsContent extends StatefulWidget {
  const SaleOrderDetailsContent({
    super.key,
    required this.order,
    this.onReprint,
    this.onShare,
    this.onPrintAudit,
    this.onVoid,
    this.onReturn,
    this.onRecordPayment,
    this.onConvert,
    this.isRecordingPayment = false,
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

  /// When provided and the order is an unpaid credit invoice, surfaces a
  /// prominent "آجل — المتبقّي X" callout with a "تسجيل دفعة" action.
  final SaleOrderRecordPaymentAction? onRecordPayment;

  /// When provided and the order is an OPEN quotation, surfaces a
  /// "تحويل إلى بيع" action. The callback opens the conversion dialog.
  final SaleOrderConvertAction? onConvert;
  final bool isRecordingPayment;
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
              canReturn: _canReturn,
              canVoid: _canVoid,
              canConvert: _canConvert,
              onReprint: widget.onReprint == null ? null : _requestReprint,
              onShare: widget.onShare == null ? null : _shareInvoice,
              onPrintAudit: widget.onPrintAudit,
              onReturn: _canReturn ? _showReturnDialog : null,
              onVoid: _canVoid ? _showVoidDialog : null,
              onConvert: _canConvert ? _convertQuotation : null,
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

  bool get _hasVisibleActions {
    return widget.onReprint != null ||
        widget.onShare != null ||
        widget.onPrintAudit != null ||
        _canReturn ||
        _canVoid ||
        _canConvert;
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
    final result = await showDialog<_ReturnDialogResult>(
      context: context,
      builder: (context) => _SaleReturnDialog(order: widget.order),
    );
    if (result == null || widget.onReturn == null) {
      return;
    }
    if (result.lines.isEmpty) {
      _showMessage(l10n.saleReturnNoItemsSelected);
      return;
    }

    await _runAdjustment(
      () => widget.onReturn!(widget.order, result.lines, result.reason),
      successMessage: l10n.saleReturnSuccess,
      errorMessage: l10n.saleReturnError,
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
    required this.canReturn,
    required this.canVoid,
    required this.canConvert,
    this.onReprint,
    this.onShare,
    this.onPrintAudit,
    this.onReturn,
    this.onVoid,
    this.onConvert,
    required this.useInvoiceLabels,
  });

  final bool isBusy;
  final bool isReprinting;
  final bool isSharing;
  final bool isAdjusting;
  final bool isConverting;
  final bool canReturn;
  final bool canVoid;
  final bool canConvert;
  final VoidCallback? onReprint;
  final VoidCallback? onShare;
  final VoidCallback? onPrintAudit;
  final VoidCallback? onReturn;
  final VoidCallback? onVoid;
  final VoidCallback? onConvert;
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.swap_horiz_outlined),
              label: Text(l10n.convertQuotationButton),
            ),
          if (onReprint != null)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onReprint,
              icon: isReprinting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
                      child: CircularProgressIndicator(strokeWidth: 2),
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
          if (canVoid)
            FilledButton.icon(
              onPressed: isBusy ? null : onVoid,
              icon: isAdjusting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
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

class _SaleReturnDialog extends StatefulWidget {
  const _SaleReturnDialog({required this.order});

  final SaleOrder order;

  @override
  State<_SaleReturnDialog> createState() => _SaleReturnDialogState();
}

class _SaleReturnDialogState extends State<_SaleReturnDialog> {
  late final Map<int, double> _quantities = {
    for (final line in widget.order.lines) line.id: 0,
  };
  final TextEditingController _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final returnableLines = widget.order.lines
        .where((line) => line.returnableQuantity > 0)
        .toList(growable: false);

    return AlertDialog(
      icon: const Icon(Icons.keyboard_return_outlined),
      title: Text(l10n.saleReturnTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (returnableLines.isEmpty)
                Text(l10n.saleNoReturnableItems)
              else
                for (final line in returnableLines)
                  _ReturnLineStepper(
                    line: line,
                    value: _quantities[line.id] ?? 0,
                    onChanged: (value) {
                      setState(() => _quantities[line.id] = value);
                    },
                  ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                decoration: InputDecoration(
                  labelText: l10n.saleAdjustmentReasonLabel,
                  hintText: l10n.saleAdjustmentReasonHint,
                ),
                maxLines: 2,
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
        FilledButton(
          onPressed: () {
            final lines = [
              for (final line in returnableLines)
                if ((_quantities[line.id] ?? 0) > 0)
                  SaleReturnLineDraft(
                    lineId: line.id,
                    quantity: _quantities[line.id]!,
                  ),
            ];
            Navigator.of(context).pop(
              _ReturnDialogResult(
                lines: lines,
                reason: _reasonController.text.trim(),
              ),
            );
          },
          child: Text(l10n.confirmButton),
        ),
      ],
    );
  }
}

class _ReturnLineStepper extends StatelessWidget {
  const _ReturnLineStepper({
    required this.line,
    required this.value,
    required this.onChanged,
  });

  final SaleOrderLine line;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(saleLineDisplayName(line, l10n)),
      subtitle: Text(
        [
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
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.removeOneTooltip,
            onPressed: value <= 0 ? null : () => onChanged(value - 1),
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 56,
            child: InkWell(
              onTap: line.unit == 'piece' ? null : () => _editWeight(context),
              child: Text(
                formatSaleQuantity(value),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.addOneTooltip,
            onPressed: value >= line.returnableQuantity
                ? null
                : () => onChanged(
                    (value + 1).clamp(0, line.returnableQuantity).toDouble(),
                  ),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

extension on _ReturnLineStepper {
  Future<void> _editWeight(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: value > 0 ? formatSaleQuantity(value) : '',
    );
    final entered = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.posWeightDialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l10n.posWeightDialogTitle,
            helperText: l10n.saleReturnQuantityHint(
              formatSaleQuantity(line.returnableQuantity),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(double.tryParse(controller.text.trim())),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered < 0) {
      return;
    }
    onChanged(entered.clamp(0, line.returnableQuantity).toDouble());
  }
}

class _ReturnDialogResult {
  const _ReturnDialogResult({required this.lines, required this.reason});

  final List<SaleReturnLineDraft> lines;
  final String reason;
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
                      child: CircularProgressIndicator(strokeWidth: 2),
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
