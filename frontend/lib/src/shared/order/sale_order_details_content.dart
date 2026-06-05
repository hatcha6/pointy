import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/sale_order.dart';
import '../components/components.dart';
import '../formatters.dart';
import '../order_totals.dart';
import '../payment_labels.dart';
import '../responsive/responsive.dart';
import '../date_formatters.dart';

typedef SaleOrderReprintAction = Future<bool> Function(SaleOrder order);
typedef SaleOrderVoidAction =
    Future<bool> Function(SaleOrder order, String reason);
typedef SaleOrderReturnAction =
    Future<bool> Function(
      SaleOrder order,
      List<SaleReturnLineDraft> lines,
      String reason,
    );

class SaleOrderDetailsContent extends StatefulWidget {
  const SaleOrderDetailsContent({
    super.key,
    required this.order,
    this.onReprint,
    this.onVoid,
    this.onReturn,
    this.showTitle = true,
    this.useInvoiceLabels = true,
    this.popOnSuccessfulAdjustment = true,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  final SaleOrder order;
  final SaleOrderReprintAction? onReprint;
  final SaleOrderVoidAction? onVoid;
  final SaleOrderReturnAction? onReturn;
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
          if (_hasVisibleActions) ...[
            _ActionsSection(
              isBusy: _isBusy,
              isReprinting: _isReprinting,
              isAdjusting: _isAdjusting,
              canReturn: _canReturn,
              canVoid: _canVoid,
              onReprint: widget.onReprint == null ? null : _requestReprint,
              onReturn: _canReturn ? _showReturnDialog : null,
              onVoid: _canVoid ? _showVoidDialog : null,
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

  bool get _isBusy => _isReprinting || _isAdjusting;

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
    return widget.onReprint != null || _canReturn || _canVoid;
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
                  border: const OutlineInputBorder(),
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
    required this.isAdjusting,
    required this.canReturn,
    required this.canVoid,
    this.onReprint,
    this.onReturn,
    this.onVoid,
    required this.useInvoiceLabels,
  });

  final bool isBusy;
  final bool isReprinting;
  final bool isAdjusting;
  final bool canReturn;
  final bool canVoid;
  final VoidCallback? onReprint;
  final VoidCallback? onReturn;
  final VoidCallback? onVoid;
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
                        line.quantity,
                        formatMoney(line.unitPrice),
                      ),
                      if (line.profit != null)
                        l10n.invoiceProfitValue(formatMoney(line.profit!)),
                      if (line.discountTotal > 0)
                        l10n.discountLineValue(formatMoney(line.discountTotal)),
                      if (line.returnedQuantity > 0)
                        l10n.saleLineReturnedQuantity(
                          line.returnedQuantity,
                          line.quantity,
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
  late final Map<int, int> _quantities = {
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
                  border: const OutlineInputBorder(),
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
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(saleLineDisplayName(line, l10n)),
      subtitle: Text(
        [
          l10n.saleLineQuantityAndPrice(
            line.quantity,
            formatMoney(line.unitPrice),
          ),
          if (line.returnedQuantity > 0)
            l10n.saleLineReturnedQuantity(line.returnedQuantity, line.quantity),
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
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: l10n.addOneTooltip,
            onPressed: value >= line.returnableQuantity
                ? null
                : () => onChanged(value + 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _ReturnDialogResult {
  const _ReturnDialogResult({required this.lines, required this.reason});

  final List<SaleReturnLineDraft> lines;
  final String reason;
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
