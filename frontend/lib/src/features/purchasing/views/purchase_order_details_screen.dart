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
        _PurchaseReceiptHistory(order: order),
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
          if (order.dueDate != null)
            _DetailRow(
              label: l10n.purchaseOrderDueDateLabel,
              value: [
                _formatDate(order.dueDate!),
                if (order.isOverdue) l10n.purchaseOrderOverdueValue,
              ].join(' • '),
            ),
          if (order.paymentStatus.isNotEmpty)
            _DetailRow(
              label: l10n.purchaseOrderPaymentStatusLabel,
              value: _paymentStatusLabel(l10n, order.paymentStatus),
            ),
          _DetailRow(
            label: l10n.purchaseOrderPaidTotalLabel,
            value: formatMoney(order.paidTotal),
          ),
          if (order.creditAppliedTotal > 0)
            _DetailRow(
              label: l10n.purchaseOrderCreditAppliedLabel,
              value: formatMoney(order.creditAppliedTotal),
            ),
          if (order.adjustmentCreditTotal > 0)
            _DetailRow(
              label: l10n.purchaseOrderAdjustmentCreditLabel,
              value: formatMoney(order.adjustmentCreditTotal),
            ),
          _DetailRow(
            label: l10n.purchaseOrderBalanceDueLabel,
            value: formatMoney(order.balanceDue),
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
          if (viewModel.hasPaymentError) ...[
            Text(
              l10n.purchaseOrderPaymentError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (viewModel.canRecordPayment)
                FilledButton.icon(
                  onPressed: viewModel.isRecordingPayment
                      ? null
                      : () => _showSupplierPaymentDialog(context),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: Text(l10n.recordSupplierPaymentAction),
                ),
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
                      : () => _showReceivingDialog(context),
                  icon: const Icon(Icons.inventory_outlined),
                  label: Text(l10n.receivePurchaseLinesAction),
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

  Future<void> _showSupplierPaymentDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_SupplierPaymentDialogResult>(
      context: context,
      builder: (context) => _SupplierPaymentDialog(order: viewModel.order),
    );
    if (result == null) {
      return;
    }

    final didRecord = await viewModel.recordPayment(
      method: result.method,
      amount: result.amount,
      reference: result.reference,
      notes: result.notes,
    );
    if (!context.mounted || !didRecord) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.supplierPaymentSuccess(viewModel.order.orderNumber),
          ),
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

  Future<void> _showReceivingDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_PurchaseReceiveDialogResult>(
      context: context,
      builder: (context) => _PurchaseReceiveDialog(order: viewModel.order),
    );
    if (result == null) {
      return;
    }
    if (result.lines.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseReceiveNoItemsSelected)),
        );
      return;
    }

    final didReceive = await viewModel.receiveLines(
      lines: result.lines,
      note: result.note,
    );
    if (!context.mounted || !didReceive) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.purchaseOrderReceiveSuccess(viewModel.order.orderNumber),
          ),
        ),
      );
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
                  l10n.purchaseLineReceivedQuantity(line.receivedQuantity),
                  l10n.purchaseLineOpenQuantity(line.receivableQuantity),
                  if (line.damagedQuantity > 0)
                    l10n.purchaseLineDamagedQuantity(line.damagedQuantity),
                  l10n.purchaseLineVarianceValue(
                    _formatSignedQuantity(line.varianceQuantity),
                  ),
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

  String _formatSignedQuantity(int value) {
    if (value > 0) {
      return '+$value';
    }
    return '$value';
  }
}

class _PurchaseReceiptHistory extends StatelessWidget {
  const _PurchaseReceiptHistory({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _Section(
      title: l10n.purchaseReceiptHistoryTitle,
      child: order.receipts.isEmpty
          ? Text(l10n.purchaseReceiptHistoryEmpty)
          : Column(
              children: [
                for (final (index, receipt) in order.receipts.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text(
                      receipt.createdAt == null
                          ? l10n.purchaseReceiptHistoryItemFallback
                          : formatDateTime(receipt.createdAt!),
                    ),
                    subtitle: Text(
                      [
                        l10n.purchaseReceiptHistoryLineCount(
                          receipt.lines.length,
                        ),
                        for (final line in receipt.lines)
                          [
                            line.productName ??
                                l10n.purchaseOrderUnknownProduct,
                            l10n.purchaseLineReceivedQuantity(
                              line.quantityReceived,
                            ),
                            if (line.quantityDamaged > 0)
                              l10n.purchaseLineDamagedQuantity(
                                line.quantityDamaged,
                              ),
                            if (line.quantityRejected > 0)
                              l10n.purchaseLineRejectedQuantity(
                                line.quantityRejected,
                              ),
                          ].join('، '),
                        if (receipt.note.isNotEmpty) receipt.note,
                      ].join(' • '),
                    ),
                  ),
                ],
              ],
            ),
    );
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
                        if (_adjustmentMethodLabel(l10n, adjustment) != null)
                          l10n.purchaseAdjustmentSettlementMethod(
                            _adjustmentMethodLabel(l10n, adjustment)!,
                          ),
                        for (final credit in adjustment.credits)
                          l10n.purchaseAdjustmentSupplierCreditCreated(
                            formatMoney(credit.amount),
                          ),
                        for (final credit in adjustment.credits)
                          if (credit.remainingAmount != null)
                            l10n.purchaseAdjustmentSupplierCreditRemaining(
                              formatMoney(credit.remainingAmount!),
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

String? _adjustmentMethodLabel(
  AppLocalizations l10n,
  PurchaseOrderAdjustment adjustment,
) {
  final method = adjustment.settlementMethod ?? adjustment.refundMethod;
  if (method == null || method.isEmpty) {
    return null;
  }
  return _supplierPaymentMethodLabel(
    l10n,
    SupplierPaymentMethod.fromApiValue(method),
  );
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

class _SupplierPaymentDialog extends StatefulWidget {
  const _SupplierPaymentDialog({required this.order});

  final PurchaseOrder order;

  @override
  State<_SupplierPaymentDialog> createState() => _SupplierPaymentDialogState();
}

class _SupplierPaymentDialogState extends State<_SupplierPaymentDialog> {
  late SupplierPaymentMethod _method = SupplierPaymentMethod.cash;
  late final TextEditingController _amountController = TextEditingController(
    text: widget.order.balanceDue.toStringAsFixed(2),
  );
  final TextEditingController _referenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  bool _showAmountError = false;

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final methods = const [
      SupplierPaymentMethod.cash,
      SupplierPaymentMethod.transfer,
      SupplierPaymentMethod.card,
      SupplierPaymentMethod.supplierCredit,
    ];

    return AlertDialog(
      icon: const Icon(Icons.account_balance_wallet_outlined),
      title: Text(l10n.supplierPaymentTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<SupplierPaymentMethod>(
                initialValue: _method,
                decoration: InputDecoration(
                  labelText: l10n.paymentMethodLabel,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final method in methods)
                    DropdownMenuItem(
                      value: method,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_supplierPaymentMethodIcon(method), size: 18),
                          const SizedBox(width: 8),
                          Text(_supplierPaymentMethodLabel(l10n, method)),
                        ],
                      ),
                    ),
                ],
                onChanged: (method) {
                  if (method == null) {
                    return;
                  }
                  setState(() => _method = method);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l10n.supplierPaymentAmountLabel,
                  errorText: _showAmountError
                      ? l10n.supplierPaymentPositiveAmountError
                      : null,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _referenceController,
                decoration: InputDecoration(
                  labelText: l10n.supplierPaymentReferenceLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: l10n.supplierPaymentNotesLabel,
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
        FilledButton(onPressed: _submit, child: Text(l10n.confirmButton)),
      ],
    );
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null ||
        amount <= 0 ||
        amount > widget.order.balanceDue + 0.005) {
      setState(() => _showAmountError = true);
      return;
    }
    Navigator.of(context).pop(
      _SupplierPaymentDialogResult(
        method: _method,
        amount: amount,
        reference: _referenceController.text.trim(),
        notes: _notesController.text.trim(),
      ),
    );
  }
}

class _SupplierPaymentDialogResult {
  const _SupplierPaymentDialogResult({
    required this.method,
    required this.amount,
    required this.reference,
    required this.notes,
  });

  final SupplierPaymentMethod method;
  final double amount;
  final String reference;
  final String notes;
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

class _PurchaseReceiveDialog extends StatefulWidget {
  const _PurchaseReceiveDialog({required this.order});

  final PurchaseOrder order;

  @override
  State<_PurchaseReceiveDialog> createState() => _PurchaseReceiveDialogState();
}

class _PurchaseReceiveDialogState extends State<_PurchaseReceiveDialog> {
  late final List<PurchaseOrderLine> _receivableLines = widget.order.lines
      .where((line) => line.receivableQuantity > 0)
      .toList(growable: false);
  late final Map<int, TextEditingController> _receivedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '${line.receivableQuantity}'),
  };
  late final Map<int, TextEditingController> _damagedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  late final Map<int, TextEditingController> _rejectedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  final TextEditingController _noteController = TextEditingController();
  bool _showQuantityError = false;

  @override
  void dispose() {
    for (final controller in _receivedControllers.values) {
      controller.dispose();
    }
    for (final controller in _damagedControllers.values) {
      controller.dispose();
    }
    for (final controller in _rejectedControllers.values) {
      controller.dispose();
    }
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      icon: const Icon(Icons.inventory_2_outlined),
      title: Text(l10n.purchaseReceiveTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_receivableLines.isEmpty)
                Text(l10n.purchaseReceiveNoOpenLines)
              else
                for (final line in _receivableLines)
                  _PurchaseReceiveLineInput(
                    line: line,
                    receivedController: _receivedControllers[line.id]!,
                    damagedController: _damagedControllers[line.id]!,
                    rejectedController: _rejectedControllers[line.id]!,
                    onChanged: () => setState(() {}),
                  ),
              if (_showQuantityError) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.purchaseReceiveInvalidQuantityError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _noteController,
                decoration: InputDecoration(
                  labelText: l10n.purchaseReceiveNoteLabel,
                  hintText: l10n.purchaseReceiveNoteHint,
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
          onPressed: _receivableLines.isEmpty ? null : _submit,
          child: Text(l10n.confirmButton),
        ),
      ],
    );
  }

  void _submit() {
    final lines = <PurchaseReceiveLineDraft>[];
    for (final line in _receivableLines) {
      final received = int.tryParse(_receivedControllers[line.id]!.text.trim());
      final damaged = int.tryParse(_damagedControllers[line.id]!.text.trim());
      final rejected = int.tryParse(_rejectedControllers[line.id]!.text.trim());
      if (received == null ||
          damaged == null ||
          rejected == null ||
          received < 0 ||
          damaged < 0 ||
          rejected < 0) {
        setState(() => _showQuantityError = true);
        return;
      }
      if (received > 0 || damaged > 0 || rejected > 0) {
        lines.add(
          PurchaseReceiveLineDraft(
            purchaseLineId: line.id,
            quantityReceived: received,
            quantityDamaged: damaged,
            quantityRejected: rejected,
          ),
        );
      }
    }
    if (lines.isEmpty) {
      setState(() => _showQuantityError = true);
      return;
    }
    Navigator.of(context).pop(
      _PurchaseReceiveDialogResult(
        lines: lines,
        note: _noteController.text.trim(),
      ),
    );
  }
}

class _PurchaseReceiveLineInput extends StatelessWidget {
  const _PurchaseReceiveLineInput({
    required this.line,
    required this.receivedController,
    required this.damagedController,
    required this.rejectedController,
    required this.onChanged,
  });

  final PurchaseOrderLine line;
  final TextEditingController receivedController;
  final TextEditingController damagedController;
  final TextEditingController rejectedController;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final received = int.tryParse(receivedController.text.trim()) ?? 0;
    final damaged = int.tryParse(damagedController.text.trim()) ?? 0;
    final rejected = int.tryParse(rejectedController.text.trim()) ?? 0;
    final afterDelivered =
        line.receivedQuantity + line.damagedQuantity + received + damaged;
    final afterOpen = line.receivableQuantity - received - damaged - rejected;
    final afterVariance = afterDelivered - line.quantity;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            line.productName ?? l10n.purchaseOrderUnknownProduct,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (line.productSku != null && line.productSku!.isNotEmpty)
                line.productSku!,
              l10n.purchaseReceiveExpectedValue(line.quantity),
              l10n.purchaseReceiveAlreadyValue(line.receivedQuantity),
              l10n.purchaseReceiveOpenValue(line.receivableQuantity),
              if (line.damagedQuantity > 0)
                l10n.purchaseLineDamagedQuantity(line.damagedQuantity),
              if (line.rejectedQuantity > 0)
                l10n.purchaseLineRejectedQuantity(line.rejectedQuantity),
              l10n.purchaseReceiveOpenAfterValue(afterOpen < 0 ? 0 : afterOpen),
              l10n.purchaseReceiveAfterVarianceValue(
                _formatSignedInt(afterVariance),
              ),
            ].join(' • '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: receivedController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveReceivedLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: damagedController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveDamagedLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: rejectedController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveRejectedLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PurchaseReceiveDialogResult {
  const _PurchaseReceiveDialogResult({required this.lines, required this.note});

  final List<PurchaseReceiveLineDraft> lines;
  final String note;
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

String _paymentStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'partial' => l10n.purchasePaymentStatusPartial,
    'paid' => l10n.purchasePaymentStatusPaid,
    'credit' => l10n.purchasePaymentStatusCredit,
    _ => l10n.purchasePaymentStatusUnpaid,
  };
}

String _supplierPaymentMethodLabel(
  AppLocalizations l10n,
  SupplierPaymentMethod method,
) {
  return switch (method) {
    SupplierPaymentMethod.cash => l10n.paymentMethodCash,
    SupplierPaymentMethod.card => l10n.paymentMethodCard,
    SupplierPaymentMethod.transfer => l10n.paymentMethodTransfer,
    SupplierPaymentMethod.supplierCredit => l10n.supplierPaymentMethodCredit,
    SupplierPaymentMethod.refund => l10n.purchaseAdjustmentTypeRefund,
  };
}

IconData _supplierPaymentMethodIcon(SupplierPaymentMethod method) {
  return switch (method) {
    SupplierPaymentMethod.cash => Icons.payments_outlined,
    SupplierPaymentMethod.card => Icons.credit_card_outlined,
    SupplierPaymentMethod.transfer => Icons.account_balance_outlined,
    SupplierPaymentMethod.supplierCredit => Icons.savings_outlined,
    SupplierPaymentMethod.refund => Icons.keyboard_return_outlined,
  };
}

String _formatSignedInt(int value) {
  if (value > 0) {
    return '+$value';
  }
  return '$value';
}

String _formatDate(DateTime dateTime) {
  final date = dateTime.toLocal();
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}/$month/$day';
}
