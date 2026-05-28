import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payment_labels.dart';
import '../../../shared/responsive/responsive.dart';

Future<void> showSaleOrderDetailsSheet(
  BuildContext context,
  SaleOrder order, {
  Future<bool> Function(SaleOrder order)? onReprint,
  Future<bool> Function(SaleOrder order, String reason)? onVoid,
  Future<bool> Function(
    SaleOrder order,
    List<SaleReturnLineDraft> lines,
    String reason,
  )?
  onReturn,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) {
      return _SaleOrderDetailsSheet(
        order: order,
        onReprint: onReprint,
        onVoid: onVoid,
        onReturn: onReturn,
      );
    },
  );
}

class _SaleOrderDetailsSheet extends StatefulWidget {
  const _SaleOrderDetailsSheet({
    required this.order,
    this.onReprint,
    this.onVoid,
    this.onReturn,
  });

  final SaleOrder order;
  final Future<bool> Function(SaleOrder order)? onReprint;
  final Future<bool> Function(SaleOrder order, String reason)? onVoid;
  final Future<bool> Function(
    SaleOrder order,
    List<SaleReturnLineDraft> lines,
    String reason,
  )?
  onReturn;

  @override
  State<_SaleOrderDetailsSheet> createState() => _SaleOrderDetailsSheetState();
}

class _SaleOrderDetailsSheetState extends State<_SaleOrderDetailsSheet> {
  bool _isReprinting = false;
  bool _isAdjusting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = widget.order;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.saleReceiptTitle(
              order.receiptNumber ?? l10n.saleReceiptFallback,
            ),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: order.lines.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final line = order.lines[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_saleLineDisplayName(line, l10n)),
                subtitle: Text(
                  [
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
                ),
                trailing: Text(formatMoney(line.total)),
              );
            },
          ),
          const Divider(),
          if (order.discountTotal > 0) ...[
            Row(
              children: [
                Text(l10n.subtotal),
                const Spacer(),
                Text(formatMoney(order.subtotal)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(l10n.discountTotalLabel),
                const Spacer(),
                Text('-${formatMoney(order.discountTotal)}'),
              ],
            ),
            if (order.appliedDiscounts.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final discount in order.appliedDiscounts)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        discount.couponCode.isEmpty
                            ? discount.ruleName
                            : l10n.discountCouponAppliedLabel(
                                discount.couponCode,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      '-${formatMoney(discount.discountAmount)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Text(l10n.total, style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                formatMoney(order.total),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          if (order.profit != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  l10n.invoiceProfitLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatMoney(order.profit!),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    if (order.profitMarginPercent != null)
                      Text(
                        l10n.invoiceProfitMarginValue(
                          order.profitMarginPercent!.toStringAsFixed(2),
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ],
            ),
          ],
          if (order.payments.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.salePaymentsTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            for (final payment in order.payments)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(paymentMethodIcon(payment.method)),
                title: Text(paymentMethodLabel(l10n, payment.method)),
                subtitle: payment.commissionAmount == 0
                    ? null
                    : Text(
                        l10n.salePaymentCommission(
                          formatMoney(payment.commissionAmount),
                          payment.commissionPercent.toStringAsFixed(2),
                        ),
                      ),
                trailing: Text(formatMoney(payment.amount)),
              ),
          ],
          if (widget.onReprint != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isBusy ? null : _requestReprint,
              icon: _isReprinting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
              label: Text(
                _isReprinting
                    ? l10n.saleReprintInProgressButton
                    : l10n.saleReprintButton,
              ),
            ),
          ],
          if (_canAdjustOrder) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : _showReturnDialog,
                    icon: const Icon(Icons.keyboard_return_outlined),
                    label: Text(l10n.saleReturnButton),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isBusy ? null : _showVoidDialog,
                    icon: _isAdjusting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.block_outlined),
                    label: Text(l10n.saleVoidButton),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool get _isBusy => _isReprinting || _isAdjusting;

  bool get _canAdjustOrder {
    return widget.order.status == 'paid' &&
        (widget.onVoid != null || widget.onReturn != null) &&
        widget.order.lines.any((line) => line.returnableQuantity > 0);
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
            requested ? l10n.saleReprintQueuedMessage : l10n.saleReprintError,
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
    if (didAdjust) {
      Navigator.of(context).pop();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
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
      title: Text(_saleLineDisplayName(line, l10n)),
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

String _saleLineDisplayName(SaleOrderLine line, AppLocalizations l10n) {
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

class _ReturnDialogResult {
  const _ReturnDialogResult({required this.lines, required this.reason});

  final List<SaleReturnLineDraft> lines;
  final String reason;
}
