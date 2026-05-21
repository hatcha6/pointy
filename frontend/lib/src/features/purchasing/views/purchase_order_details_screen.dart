import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order_totals.dart';
import '../view_models/purchase_order_details_view_model.dart';
import 'purchase_order_filter_sheet.dart';

part 'purchase_order_actions_panel.dart';
part 'purchase_order_adjustment_dialogs.dart';
part 'purchase_order_receive_dialog.dart';
part 'purchase_order_supplier_payment_dialog.dart';

class PurchaseOrderDetailsScreen extends StatefulWidget {
  const PurchaseOrderDetailsScreen({
    super.key,
    required this.purchaseRepository,
    required this.initialOrder,
    required this.capabilities,
  });

  final PurchaseRepository purchaseRepository;
  final PurchaseOrder initialOrder;
  final AuthorizationCapabilities capabilities;

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
        capabilities: widget.capabilities,
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
            title: Text(l10n.purchaseOrderNumberValue(title)),
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
        _PurchaseOrderTotals(order: order),
      ],
    );
  }
}

class _PurchaseOrderTotals extends StatelessWidget {
  const _PurchaseOrderTotals({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        TotalRow(label: l10n.subtotal, value: order.subtotal),
        if (order.discountTotal > 0)
          TotalRow(label: l10n.discountTotalLabel, value: -order.discountTotal),
        if (order.appliedDiscounts.isNotEmpty)
          for (final discount in order.appliedDiscounts)
            TotalRow(
              label: discount.couponCode.isEmpty
                  ? discount.ruleName
                  : l10n.discountCouponAppliedLabel(discount.couponCode),
              value: -discount.discountAmount,
            ),
        if (order.landedCostTotal > 0)
          TotalRow(
            label: l10n.purchaseLandedCostTotalLabel,
            value: order.landedCostTotal,
          ),
        const Divider(),
        TotalRow(label: l10n.total, value: order.total, isStrong: true),
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
            label: l10n.purchaseOrderNumberLabel,
            value: order.orderNumber.isEmpty
                ? l10n.purchaseOrderFallbackTitle(order.id)
                : order.orderNumber,
          ),
          if (order.supplierInvoiceNumber.isNotEmpty)
            _DetailRow(
              label: l10n.supplierInvoiceNumberLabel,
              value: order.supplierInvoiceNumber,
            ),
          if (order.supplierInvoiceDate != null)
            _DetailRow(
              label: l10n.supplierInvoiceDateLabel,
              value: formatDate(order.supplierInvoiceDate!),
            ),
          _DetailRow(
            label: l10n.purchaseOrderStatusFilterTitle,
            value: purchaseOrderStatusLabel(l10n, order.status),
          ),
          _DetailRow(
            label: l10n.purchaseOrderLineCountLabel,
            value: l10n.purchaseOrderLineCount(order.lineCount),
          ),
          if (order.discountCodes.isNotEmpty)
            _DetailRow(
              label: l10n.discountCouponCodeLabel,
              value: order.discountCodes.join('، '),
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
                formatDate(order.dueDate!),
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
                line.displayName.isEmpty
                    ? l10n.purchaseOrderUnknownProduct
                    : line.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (line.variantSku != null && line.variantSku!.isNotEmpty)
                    line.variantSku!,
                  l10n.purchaseOrderLineQuantity(line.quantity),
                  l10n.purchaseLineReceivedQuantity(line.receivedQuantity),
                  l10n.purchaseLineOpenQuantity(line.receivableQuantity),
                  if (line.damagedQuantity > 0)
                    l10n.purchaseLineDamagedQuantity(line.damagedQuantity),
                  l10n.purchaseLineVarianceValue(
                    _formatSignedQuantity(line.varianceQuantity),
                  ),
                  l10n.unitPriceEach(formatMoney(line.unitCost)),
                  if (line.discountAmount > 0)
                    l10n.discountLineValue(formatMoney(line.discountAmount)),
                  if (line.netUnitCost != null && line.discountAmount > 0)
                    l10n.purchaseLineNetCostValue(
                      formatMoney(line.netUnitCost!),
                    ),
                  if (_costChangeText(l10n, line) != null)
                    _costChangeText(l10n, line)!,
                  if (line.landedCostAllocation != null &&
                      line.landedCostAllocation! > 0)
                    l10n.purchaseLineLandedCostValue(
                      formatMoney(line.landedCostAllocation!),
                    ),
                  if (line.effectiveUnitCost != null &&
                      line.effectiveUnitCost != line.unitCost)
                    l10n.purchaseLineEffectiveCostValue(
                      formatMoney(line.effectiveUnitCost!),
                    ),
                  if (line.adjustedQuantity > 0)
                    l10n.purchaseAdjustmentLineRemaining(
                      line.adjustableQuantity,
                      line.quantity,
                    ),
                ].join(' • '),
              ),
              trailing: Text(formatMoney(line.landedLineTotal ?? line.total)),
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
                            line.displayName.isEmpty
                                ? l10n.purchaseOrderUnknownProduct
                                : line.displayName,
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
                        if (adjustment.replacementLines.isNotEmpty)
                          l10n.purchaseExchangeReplacementLineCount(
                            adjustment.replacementLines.length,
                          ),
                        for (final line in adjustment.replacementLines)
                          l10n.purchaseExchangeReplacementHistoryLine(
                            line.displayName.isEmpty
                                ? l10n.purchaseOrderUnknownProduct
                                : line.displayName,
                            line.quantity,
                            formatMoney(line.unitCost),
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
