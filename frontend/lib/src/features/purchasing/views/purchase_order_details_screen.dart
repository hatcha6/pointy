import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order_totals.dart';
import '../view_models/purchase_order_details_view_model.dart';
import 'purchase_order_filter_sheet.dart';

class PurchaseOrderDetailsScreen extends StatefulWidget {
  const PurchaseOrderDetailsScreen({
    super.key,
    required this.purchaseRepository,
    required this.initialOrder,
  });

  final PurchaseRepository purchaseRepository;
  final PurchaseOrder initialOrder;

  @override
  State<PurchaseOrderDetailsScreen> createState() =>
      _PurchaseOrderDetailsScreenState();
}

class _PurchaseOrderDetailsScreenState
    extends State<PurchaseOrderDetailsScreen> {
  late final PurchaseOrderDetailsViewModel _viewModel =
      PurchaseOrderDetailsViewModel(
        widget.purchaseRepository,
        initialOrder: widget.initialOrder,
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
        final title = order.orderNumber.isEmpty
            ? l10n.purchaseOrderFallbackTitle(order.id)
            : order.orderNumber;

        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(
                tooltip: l10n.refreshPurchaseOrderDetailsTooltip,
                onPressed: _viewModel.isLoading ? null : _viewModel.loadOrder,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: _viewModel.hasLoadError
                ? Center(child: Text(l10n.purchaseOrderDetailsLoadError))
                : _PurchaseOrderDetailsBody(viewModel: _viewModel),
          ),
        );
      },
    );
  }
}

class _PurchaseOrderDetailsBody extends StatelessWidget {
  const _PurchaseOrderDetailsBody({required this.viewModel});

  final PurchaseOrderDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final order = viewModel.order;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _PurchaseOrderSummary(order: order),
        const SizedBox(height: 12),
        _PurchaseOrderActions(viewModel: viewModel),
        const SizedBox(height: 16),
        _PurchaseOrderLines(order: order),
        const SizedBox(height: 16),
        _PurchaseOrderAdjustmentHistory(order: order),
        const SizedBox(height: 16),
        OrderTotals(
          subtotalLabel: AppLocalizations.of(context)!.subtotal,
          totalLabel: AppLocalizations.of(context)!.total,
          subtotal: order.subtotal,
          total: order.total,
        ),
      ],
    );
  }
}

class _PurchaseOrderSummary extends StatelessWidget {
  const _PurchaseOrderSummary({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _Section(
      title: l10n.purchaseOrderDetailsSummaryTitle,
      child: Column(
        children: [
          _DetailRow(
            label: l10n.purchaseOrderStatusFilterTitle,
            value: purchaseOrderStatusLabel(l10n, order.status),
          ),
          _DetailRow(
            label: l10n.purchaseOrderLineCountLabel,
            value: l10n.purchaseOrderLineCount(order.lineCount),
          ),
          if (order.createdAt != null)
            _DetailRow(
              label: l10n.purchaseOrderCreatedAtLabel,
              value: formatDateTime(order.createdAt!),
            ),
          if (order.submittedAt != null)
            _DetailRow(
              label: l10n.purchaseOrderSubmittedAtLabel,
              value: formatDateTime(order.submittedAt!),
            ),
          if (order.receivedAt != null)
            _DetailRow(
              label: l10n.purchaseOrderReceivedAtLabel,
              value: formatDateTime(order.receivedAt!),
            ),
        ],
      ),
    );
  }
}

class _PurchaseOrderActions extends StatelessWidget {
  const _PurchaseOrderActions({required this.viewModel});

  final PurchaseOrderDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _Section(
      title: l10n.purchaseOrderActionsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (viewModel.hasStatusError) ...[
            Text(
              l10n.purchaseOrderStatusChangeError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          if (viewModel.hasAdjustmentError) ...[
            Text(
              l10n.purchaseOrderAdjustmentError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (viewModel.canSubmit)
                FilledButton.icon(
                  onPressed: viewModel.isChangingStatus
                      ? null
                      : () => _runAction(
                          context,
                          viewModel.submit,
                          l10n.purchaseOrderSubmitSuccess,
                        ),
                  icon: const Icon(Icons.send_outlined),
                  label: Text(l10n.submitPurchaseOrderAction),
                ),
              if (viewModel.canReceive)
                FilledButton.icon(
                  onPressed: viewModel.isChangingStatus
                      ? null
                      : () => _runAction(
                          context,
                          viewModel.receive,
                          l10n.purchaseOrderReceiveSuccess,
                        ),
                  icon: const Icon(Icons.inventory_outlined),
                  label: Text(l10n.receivePurchaseOrderAction),
                ),
              if (viewModel.canCancel)
                OutlinedButton.icon(
                  onPressed: viewModel.isChangingStatus
                      ? null
                      : () => _runAction(
                          context,
                          viewModel.cancel,
                          l10n.purchaseOrderCancelSuccess,
                        ),
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(l10n.cancelPurchaseOrderAction),
                ),
              if (viewModel.canReturn)
                OutlinedButton.icon(
                  onPressed: viewModel.isAdjusting
                      ? null
                      : () => _showAdjustmentDialog(
                          context,
                          title: l10n.purchaseReturnTitle,
                          icon: Icons.keyboard_return_outlined,
                          action: viewModel.returnItems,
                          successMessage: l10n.purchaseReturnSuccess,
                        ),
                  icon: const Icon(Icons.keyboard_return_outlined),
                  label: Text(l10n.returnPurchaseItemsAction),
                ),
              if (viewModel.canRefund)
                OutlinedButton.icon(
                  onPressed: viewModel.isAdjusting
                      ? null
                      : () => _showAdjustmentDialog(
                          context,
                          title: l10n.purchaseRefundTitle,
                          icon: Icons.payments_outlined,
                          action: viewModel.refundItems,
                          successMessage: l10n.purchaseRefundSuccess,
                        ),
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(l10n.refundPurchaseItemsAction),
                ),
              if (viewModel.canExchange)
                OutlinedButton.icon(
                  onPressed: viewModel.isAdjusting
                      ? null
                      : () => _showAdjustmentDialog(
                          context,
                          title: l10n.purchaseExchangeTitle,
                          icon: Icons.swap_horiz_outlined,
                          action: viewModel.exchangeItems,
                          successMessage: l10n.purchaseExchangeSuccess,
                        ),
                  icon: const Icon(Icons.swap_horiz_outlined),
                  label: Text(l10n.exchangePurchaseItemsAction),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    Future<bool> Function() action,
    String Function(String orderNumber) message,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final didChange = await action();
    if (!context.mounted || !didChange) {
      return;
    }
    final orderNumber = viewModel.order.orderNumber;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message(orderNumber))));
  }

  Future<void> _showAdjustmentDialog(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Future<bool> Function({
      required List<PurchaseAdjustmentLineDraft> lines,
      String reason,
    })
    action,
    required String Function(String orderNumber) successMessage,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_PurchaseAdjustmentDialogResult>(
      context: context,
      builder: (context) {
        return _PurchaseAdjustmentDialog(
          title: title,
          icon: icon,
          order: viewModel.order,
        );
      },
    );
    if (result == null) {
      return;
    }
    if (result.lines.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseAdjustmentNoItemsSelected)),
        );
      return;
    }

    final didAdjust = await action(lines: result.lines, reason: result.reason);
    if (!context.mounted || !didAdjust) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(successMessage(viewModel.order.orderNumber))),
      );
  }
}

class _PurchaseOrderLines extends StatelessWidget {
  const _PurchaseOrderLines({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _Section(
      title: l10n.purchaseOrderLinesTitle,
      child: Column(
        children: [
          for (final (index, line) in order.lines.indexed) ...[
            if (index > 0) const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                line.productName ?? l10n.purchaseOrderUnknownProduct,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (line.productSku != null && line.productSku!.isNotEmpty)
                    line.productSku!,
                  l10n.purchaseOrderLineQuantity(line.quantity),
                  l10n.unitPriceEach(formatMoney(line.unitCost)),
                  if (_costChangeText(l10n, line) != null)
                    _costChangeText(l10n, line)!,
                  if (line.adjustedQuantity > 0)
                    l10n.purchaseAdjustmentLineRemaining(
                      line.adjustableQuantity,
                      line.quantity,
                    ),
                ].join(' • '),
              ),
              trailing: Text(formatMoney(line.total)),
            ),
          ],
        ],
      ),
    );
  }

  String? _costChangeText(AppLocalizations l10n, PurchaseOrderLine line) {
    final previousCost = line.previousUnitCost;
    final change = line.effectiveUnitCostChange;
    if (previousCost == null && change == null) {
      return null;
    }
    final parts = [
      if (previousCost != null)
        l10n.purchaseOrderPreviousCostValue(formatMoney(previousCost)),
      if (change != null)
        l10n.purchaseOrderCostChangeValue(_formatSignedMoney(change)),
      if (line.unitCostChangePercent != null)
        l10n.purchaseOrderCostChangePercentValue(
          _formatSignedPercent(line.unitCostChangePercent!),
        ),
    ];
    return parts.join('، ');
  }

  String _formatSignedMoney(double value) {
    final amount = formatMoney(value.abs());
    if (value > 0) {
      return '+$amount';
    }
    if (value < 0) {
      return '-$amount';
    }
    return amount;
  }

  String _formatSignedPercent(double value) {
    final amount = value.abs().toStringAsFixed(2);
    if (value > 0) {
      return '+$amount';
    }
    if (value < 0) {
      return '-$amount';
    }
    return amount;
  }
}

class _PurchaseOrderAdjustmentHistory extends StatelessWidget {
  const _PurchaseOrderAdjustmentHistory({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _Section(
      title: l10n.purchaseOrderAdjustmentsTitle,
      child: order.adjustments.isEmpty
          ? Text(l10n.purchaseAdjustmentHistoryEmpty)
          : Column(
              children: [
                for (final (index, adjustment)
                    in order.adjustments.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_adjustmentIcon(adjustment.type)),
                    title: Text(_adjustmentTypeLabel(l10n, adjustment.type)),
                    subtitle: Text(
                      [
                        if (adjustment.createdAt != null)
                          formatDateTime(adjustment.createdAt!),
                        l10n.purchaseAdjustmentHistoryLineCount(
                          adjustment.lines.length,
                        ),
                        if (adjustment.reason.isNotEmpty) adjustment.reason,
                      ].join(' • '),
                    ),
                    trailing: Text(formatMoney(adjustment.amount)),
                  ),
                ],
              ],
            ),
    );
  }

  IconData _adjustmentIcon(PurchaseAdjustmentType type) {
    return switch (type) {
      PurchaseAdjustmentType.returnItems => Icons.keyboard_return_outlined,
      PurchaseAdjustmentType.refund => Icons.payments_outlined,
      PurchaseAdjustmentType.exchange => Icons.swap_horiz_outlined,
    };
  }
}

String _adjustmentTypeLabel(
  AppLocalizations l10n,
  PurchaseAdjustmentType type,
) {
  return switch (type) {
    PurchaseAdjustmentType.returnItems => l10n.purchaseAdjustmentTypeReturn,
    PurchaseAdjustmentType.refund => l10n.purchaseAdjustmentTypeRefund,
    PurchaseAdjustmentType.exchange => l10n.purchaseAdjustmentTypeExchange,
  };
}

class _PurchaseAdjustmentDialog extends StatefulWidget {
  const _PurchaseAdjustmentDialog({
    required this.title,
    required this.icon,
    required this.order,
  });

  final String title;
  final IconData icon;
  final PurchaseOrder order;

  @override
  State<_PurchaseAdjustmentDialog> createState() =>
      _PurchaseAdjustmentDialogState();
}

class _PurchaseAdjustmentDialogState extends State<_PurchaseAdjustmentDialog> {
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
    final adjustableLines = widget.order.lines
        .where((line) => line.adjustableQuantity > 0)
        .toList(growable: false);

    return AlertDialog(
      icon: Icon(widget.icon),
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (adjustableLines.isEmpty)
                Text(l10n.purchaseNoAdjustableItems)
              else
                for (final line in adjustableLines)
                  _PurchaseAdjustmentLineStepper(
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
                  labelText: l10n.purchaseAdjustmentReasonLabel,
                  hintText: l10n.purchaseAdjustmentReasonHint,
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
              for (final line in adjustableLines)
                if ((_quantities[line.id] ?? 0) > 0)
                  PurchaseAdjustmentLineDraft(
                    lineId: line.id,
                    quantity: _quantities[line.id]!,
                  ),
            ];
            Navigator.of(context).pop(
              _PurchaseAdjustmentDialogResult(
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

class _PurchaseAdjustmentLineStepper extends StatelessWidget {
  const _PurchaseAdjustmentLineStepper({
    required this.line,
    required this.value,
    required this.onChanged,
  });

  final PurchaseOrderLine line;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(line.productName ?? l10n.purchaseOrderUnknownProduct),
      subtitle: Text(
        [
          l10n.purchaseOrderLineQuantity(line.quantity),
          l10n.unitPriceEach(formatMoney(line.unitCost)),
          l10n.purchaseAdjustmentLineRemaining(
            line.adjustableQuantity,
            line.quantity,
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
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: l10n.addOneTooltip,
            onPressed: value >= line.adjustableQuantity
                ? null
                : () => onChanged(value + 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _PurchaseAdjustmentDialogResult {
  const _PurchaseAdjustmentDialogResult({
    required this.lines,
    required this.reason,
  });

  final List<PurchaseAdjustmentLineDraft> lines;
  final String reason;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
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
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
