import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/components/components.dart';
import '../../../shared/documents/document_lifecycle.dart';
import '../../../shared/documents/document_trail_sheet.dart';
import '../../../shared/documents/document_trail_scope.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/quantity_adjustment_dialog.dart';
import '../../../shared/order_totals.dart';
import '../../../shared/units.dart';
import '../../../shared/payment_labels.dart';
import '../../../shared/payments/record_payment_dialog.dart';
import '../../../shared/responsive/responsive.dart';
import '../../printing/views/print_audit_sheet.dart';
import '../view_models/purchase_order_details_view_model.dart';
import 'purchase_order_filter_sheet.dart';

part 'purchase_order_actions_panel.dart';
part 'purchase_order_adjustment_dialogs.dart';
part 'purchase_order_receive_dialog.dart';

class PurchaseOrderDetailsScreen extends StatefulWidget {
  const PurchaseOrderDetailsScreen({
    super.key,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.initialOrder,
    required this.capabilities,
    this.onEditDraft,
  });

  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final PurchaseOrder initialOrder;
  final AuthorizationCapabilities capabilities;

  /// Opens the given draft order in the purchasing screen for editing. The
  /// future completes when the editor is dismissed, after which this screen
  /// reloads the (possibly changed) order. Null disables the Edit action.
  final Future<void> Function(PurchaseOrder order)? onEditDraft;

  @override
  State<PurchaseOrderDetailsScreen> createState() =>
      _PurchaseOrderDetailsScreenState();
}

class _PurchaseOrderDetailsScreenState
    extends State<PurchaseOrderDetailsScreen> {
  late final PurchaseOrderDetailsViewModel _viewModel =
      PurchaseOrderDetailsViewModel(
        widget.purchaseRepository,
        printingRepository: widget.printingRepository,
        shopSettingsRepository: widget.shopSettingsRepository,
        initialOrder: widget.initialOrder,
        capabilities: widget.capabilities,
      );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _handleEditDraft() async {
    final onEditDraft = widget.onEditDraft;
    if (onEditDraft == null) {
      return;
    }
    await onEditDraft(_viewModel.order);
    if (mounted) {
      // The draft may have changed (or been submitted) in the editor.
      await _viewModel.loadOrder();
    }
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
              _PurchaseOrderDocumentMenu(
                viewModel: _viewModel,
                printingRepository: widget.printingRepository,
              ),
            ],
          ),
          // Workflow actions live in a pinned footer with a single, clear next
          // step — never competing with the document utilities in the app bar.
          bottomNavigationBar: _viewModel.hasLoadError
              ? null
              : _PurchaseOrderActionFooter(
                  viewModel: _viewModel,
                  onEdit: widget.onEditDraft == null ? null : _handleEditDraft,
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
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final order = viewModel.order;

    return AdaptiveMaxWidth(
      width: AppContentWidth.detail,
      child: ListView(
        padding: EdgeInsets.all(spacing.lg),
        children: [
          _PurchaseOrderHero(order: order),
          SizedBox(height: spacing.md),
          if (_PurchaseOrderErrors.hasAny(viewModel)) ...[
            _PurchaseOrderErrors(viewModel: viewModel),
            SizedBox(height: spacing.md),
          ],
          _PurchaseOrderStatusCallout(order: order),
          SizedBox(height: spacing.md),
          _PurchaseOrderMetrics(order: order),
          SizedBox(height: spacing.md),
          _PurchaseOrderDetails(order: order),
          SizedBox(height: spacing.md),
          _PurchaseOrderLines(order: order),
          SizedBox(height: spacing.md),
          _PurchaseReceiptHistory(order: order),
          SizedBox(height: spacing.md),
          _PurchaseOrderAdjustmentHistory(order: order),
          SizedBox(height: spacing.md),
          _Section(
            title: l10n.total,
            icon: Icons.summarize_outlined,
            child: _PurchaseOrderTotals(order: order),
          ),
        ],
      ),
    );
  }
}

/// Gradient header: PO number, the order total as the headline figure, and
/// status / supplier / line-count / due-date metadata as pills.
class _PurchaseOrderHero extends StatelessWidget {
  const _PurchaseOrderHero({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = order.orderNumber.isEmpty
        ? l10n.purchaseOrderFallbackTitle(order.id)
        : order.orderNumber;
    final supplierName = order.supplierName?.trim() ?? '';

    return PointyDetailHero(
      icon: Icons.receipt_long_outlined,
      title: title,
      value: formatMoney(order.total),
      pills: [
        PointyHeroPill(
          label: purchaseOrderStatusLabel(l10n, order.status),
          icon: _purchaseOrderStatusIcon(order.status),
        ),
        if (supplierName.isNotEmpty)
          PointyHeroPill(
            label: supplierName,
            icon: Icons.local_shipping_outlined,
          ),
        PointyHeroPill(
          label: l10n.lineItemCount(order.lineCount),
          icon: Icons.inventory_2_outlined,
        ),
        if (order.dueDate != null)
          PointyHeroPill(
            label: order.isOverdue
                ? '${formatDate(order.dueDate!)} • ${l10n.purchaseOrderOverdueValue}'
                : formatDate(order.dueDate!),
            icon: Icons.event_outlined,
          ),
      ],
    );
  }
}

/// Plain-language "what's the state / what's next" sentence, toned and badged
/// by status so the order reads at a glance.
class _PurchaseOrderStatusCallout extends StatelessWidget {
  const _PurchaseOrderStatusCallout({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final status = order.status;
    final owing = order.balanceDue > 0.005;

    final String title;
    String? message;
    final PointyCalloutTone tone;
    final IconData icon;

    if (status == 'cancelled') {
      title = l10n.purchaseOrderCalloutCancelledTitle;
      // Who retracted it, when, and the reason they gave — the questions a
      // bare "this order was cancelled" leaves the reader holding.
      message = DocumentRetraction(
        docStatus: order.docStatus,
        cancelledAt: order.cancelledAt,
        cancelledByUsername: order.cancelledByUsername,
        cancelReason: order.cancelReason,
      ).messageWith(l10n, l10n.purchaseOrderCalloutCancelledMessage);
      tone = PointyCalloutTone.neutral;
      icon = Icons.cancel_outlined;
    } else if (status == 'draft') {
      title = l10n.purchaseOrderCalloutDraftTitle;
      message = l10n.purchaseOrderCalloutDraftMessage;
      tone = PointyCalloutTone.primary;
      icon = Icons.send_outlined;
    } else if (status == 'submitted') {
      title = l10n.purchaseOrderCalloutAwaitingTitle;
      message = l10n.purchaseOrderCalloutAwaitingMessage;
      tone = PointyCalloutTone.primary;
      icon = Icons.local_shipping_outlined;
    } else if (status == 'partial' || status == 'partially_received') {
      title = l10n.purchaseOrderCalloutPartialTitle;
      message = l10n.purchaseOrderCalloutPartialMessage;
      tone = PointyCalloutTone.warning;
      icon = Icons.inventory_outlined;
    } else if (status == 'received') {
      if (owing) {
        title = l10n.purchaseOrderCalloutReceivedDueTitle;
        message = l10n.purchaseOutstandingAmountValue(
          formatMoney(order.balanceDue),
        );
        tone = order.isOverdue
            ? PointyCalloutTone.danger
            : PointyCalloutTone.warning;
        icon = Icons.account_balance_wallet_outlined;
      } else {
        title = l10n.purchaseOrderCalloutCompleteTitle;
        message = l10n.purchaseOrderCalloutCompleteMessage;
        tone = PointyCalloutTone.success;
        icon = Icons.check_circle_outline;
      }
    } else {
      title = purchaseOrderStatusLabel(l10n, status);
      tone = PointyCalloutTone.neutral;
      icon = Icons.info_outline;
    }

    return PointyDetailCallout(
      icon: icon,
      title: title,
      message: message,
      tone: tone,
      trailing: PointyStatusPill(
        label: purchaseOrderStatusLabel(l10n, status),
        icon: _purchaseOrderStatusIcon(status),
        color: _purchaseOrderStatusColor(colors, status),
      ),
    );
  }
}

/// The headline figures: total, paid, balance and (once receiving starts)
/// received-vs-ordered progress, colour-coded.
class _PurchaseOrderMetrics extends StatelessWidget {
  const _PurchaseOrderMetrics({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    final ordered = order.lines.fold<double>(0, (sum, l) => sum + l.quantity);
    final received = order.lines.fold<double>(
      0,
      (sum, l) => sum + l.receivedQuantity,
    );
    final showProgress =
        order.status != 'draft' && order.status != 'cancelled' && ordered > 0;
    final owing = order.balanceDue > 0.005;

    return PointyMetricGrid(
      maxColumns: 3,
      minTileWidth: 170,
      gap: PointyMetricGridGap.compact,
      metrics: [
        PointyMetricGridItem(
          label: l10n.total,
          value: formatMoney(order.total),
          icon: Icons.receipt_long_outlined,
          accentColor: colors.primaryStrong,
        ),
        PointyMetricGridItem(
          label: l10n.purchaseOrderPaidTotalLabel,
          value: formatMoney(order.paidTotal),
          icon: Icons.payments_outlined,
          accentColor: colors.success,
        ),
        PointyMetricGridItem(
          label: l10n.purchaseOrderBalanceDueLabel,
          value: formatMoney(order.balanceDue),
          icon: Icons.account_balance_wallet_outlined,
          accentColor: owing
              ? (order.isOverdue ? colors.danger : colors.warning)
              : colors.success,
        ),
        if (showProgress)
          PointyMetricGridItem(
            label: l10n.purchaseOrderReceivedProgressLabel,
            value: l10n.purchaseOrderReceivedProgressValue(
              formatQuantity(received),
              formatQuantity(ordered),
            ),
            icon: Icons.inventory_2_outlined,
            accentColor: received >= ordered
                ? colors.success
                : colors.primaryStrong,
          ),
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
        if (order.landedCostEntries.isNotEmpty) ...[
          for (final entry in order.landedCostEntries)
            if (entry.cost > 0) TotalRow(label: entry.name, value: entry.cost),
        ] else if (order.landedCostTotal > 0)
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

/// Document metadata that doesn't belong in the hero or metric tiles: supplier
/// invoice references, key dates, discount codes and allocation method.
class _PurchaseOrderDetails extends StatelessWidget {
  const _PurchaseOrderDetails({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final rows = <Widget>[
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
      if (order.discountCodes.isNotEmpty)
        _DetailRow(
          label: l10n.discountCouponCodeLabel,
          value: order.discountCodes.join('، '),
        ),
      if (order.landedCostTotal > 0)
        _DetailRow(
          label: l10n.landedCostAllocationMethodLabel,
          value: switch (order.landedCostAllocationMethod) {
            LandedCostAllocationMethod.byQuantity =>
              l10n.landedCostAllocationByQuantityLabel,
            LandedCostAllocationMethod.byLineValue =>
              l10n.landedCostAllocationByLineValueLabel,
            LandedCostAllocationMethod.byRetailValue =>
              l10n.landedCostAllocationByRetailValueLabel,
            LandedCostAllocationMethod.equallyByLine =>
              l10n.landedCostAllocationEquallyByLineLabel,
          },
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
      if (order.paymentStatus.isNotEmpty)
        _DetailRow(
          label: l10n.purchaseOrderPaymentStatusLabel,
          value: _paymentStatusLabel(l10n, order.paymentStatus),
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
    ];

    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }

    return _Section(
      title: l10n.purchaseOrderDetailsSummaryTitle,
      icon: Icons.description_outlined,
      child: Column(children: rows),
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
      icon: Icons.inventory_2_outlined,
      child: Column(
        children: [
          for (final (index, line) in order.lines.indexed) ...[
            if (index > 0) const SizedBox(height: 8),
            PointyDataRow(
              leading: const Icon(Icons.inventory_2_outlined),
              title: line.displayName.isEmpty
                  ? l10n.purchaseOrderUnknownProduct
                  : line.displayName,
              subtitle: [
                if (line.variantSku != null && line.variantSku!.isNotEmpty)
                  line.variantSku!,
                l10n.purchaseOrderLineQuantity(formatQuantity(line.quantity)),
                l10n.purchaseLineReceivedQuantity(
                  formatQuantity(line.receivedQuantity),
                ),
                l10n.purchaseLineOpenQuantity(
                  formatQuantity(line.receivableQuantity),
                ),
                if (line.damagedQuantity > 0)
                  l10n.purchaseLineDamagedQuantity(
                    formatQuantity(line.damagedQuantity),
                  ),
                l10n.purchaseLineVarianceValue(
                  _formatSignedQuantity(line.varianceQuantity),
                ),
                l10n.unitPriceEach(formatMoney(line.unitCost)),
                if (line.discountAmount > 0)
                  l10n.discountLineValue(formatMoney(line.discountAmount)),
                if (line.netUnitCost != null && line.discountAmount > 0)
                  l10n.purchaseLineNetCostValue(formatMoney(line.netUnitCost!)),
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
                    formatQuantity(line.adjustableQuantity),
                    formatQuantity(line.quantity),
                  ),
              ].join(' • '),
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

  String _formatSignedQuantity(double value) {
    final text = formatQuantity(value.abs());
    return value > 0 ? '+$text' : (value < 0 ? '-$text' : text);
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
      icon: Icons.move_to_inbox_outlined,
      child: order.receipts.isEmpty
          ? Text(l10n.purchaseReceiptHistoryEmpty)
          : Column(
              children: [
                for (final (index, receipt) in order.receipts.indexed) ...[
                  if (index > 0) const SizedBox(height: 8),
                  PointyDataRow(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: receipt.createdAt == null
                        ? l10n.purchaseReceiptHistoryItemFallback
                        : formatDateTime(receipt.createdAt!),
                    subtitle: [
                      l10n.lineItemCount(receipt.lines.length),
                      for (final line in receipt.lines)
                        [
                          line.displayName.isEmpty
                              ? l10n.purchaseOrderUnknownProduct
                              : line.displayName,
                          l10n.purchaseLineReceivedQuantity(
                            formatQuantity(line.quantityReceived),
                          ),
                          if (line.quantityDamaged > 0)
                            l10n.purchaseLineDamagedQuantity(
                              formatQuantity(line.quantityDamaged),
                            ),
                          if (line.quantityRejected > 0)
                            l10n.purchaseLineRejectedQuantity(
                              formatQuantity(line.quantityRejected),
                            ),
                        ].join('، '),
                      if (receipt.note.isNotEmpty) receipt.note,
                    ].join(' • '),
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
      icon: Icons.assignment_return_outlined,
      child: order.adjustments.isEmpty
          ? Text(l10n.purchaseAdjustmentHistoryEmpty)
          : Column(
              children: [
                for (final (index, adjustment)
                    in order.adjustments.indexed) ...[
                  if (index > 0) const SizedBox(height: 8),
                  PointyDataRow(
                    leading: Icon(_adjustmentIcon(adjustment.type)),
                    title: _adjustmentTypeLabel(l10n, adjustment.type),
                    subtitle: [
                      if (adjustment.createdAt != null)
                        formatDateTime(adjustment.createdAt!),
                      l10n.lineItemCount(adjustment.lines.length),
                      if (adjustment.replacementLines.isNotEmpty)
                        l10n.purchaseExchangeReplacementLineCount(
                          adjustment.replacementLines.length,
                        ),
                      for (final line in adjustment.replacementLines)
                        l10n.purchaseExchangeReplacementHistoryLine(
                          line.displayName.isEmpty
                              ? l10n.purchaseOrderUnknownProduct
                              : line.displayName,
                          formatQuantity(line.quantity),
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
  return supplierPaymentMethodLabel(
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
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PointyDetailSection(title: title, icon: icon, child: child);
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: colors.mutedInk)),
          ),
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

Color _purchaseOrderStatusColor(PointySemanticColors colors, String status) {
  return switch (status) {
    'draft' => colors.mutedInk,
    'submitted' => colors.primaryStrong,
    'partial' || 'partially_received' => colors.warning,
    'received' => colors.success,
    'cancelled' => colors.danger,
    _ => colors.mutedInk,
  };
}

IconData _purchaseOrderStatusIcon(String status) {
  return switch (status) {
    'draft' => Icons.edit_note_outlined,
    'submitted' => Icons.local_shipping_outlined,
    'partial' || 'partially_received' => Icons.inventory_outlined,
    'received' => Icons.check_circle_outline,
    'cancelled' => Icons.cancel_outlined,
    _ => Icons.info_outline,
  };
}

String _paymentStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'partial' => l10n.purchasePaymentStatusPartial,
    'paid' => l10n.purchasePaymentStatusPaid,
    'credit' => l10n.purchasePaymentStatusCredit,
    _ => l10n.purchasePaymentStatusUnpaid,
  };
}

String _formatSignedQuantityValue(double value) {
  final text = formatQuantity(value.abs());
  return value > 0 ? '+$text' : (value < 0 ? '-$text' : text);
}
