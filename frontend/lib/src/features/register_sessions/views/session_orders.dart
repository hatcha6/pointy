import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_session_summary.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/register_session_history_view_model.dart';
import 'card_receipt_verification_section.dart';
import 'sale_order_details_sheet.dart';

class SessionOrders extends StatelessWidget {
  const SessionOrders({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = viewModel.selectedSession;
    final showReconciliation = capabilities.canManageShopSettings;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySectionHeader(
            title: session == null
                ? l10n.sessionSalesPlaceholderTitle
                : session.ownerName.isEmpty
                ? l10n.sessionSalesTitle(session.sessionNumber)
                : '${l10n.sessionSalesTitle(session.sessionNumber)} — '
                      '${session.ownerName}',
          ),
          SizedBox(height: spacing.sm),
          Expanded(
            child: RegisterSessionOrdersGuard(
              capabilities: capabilities,
              child: session == null
                  ? PointyEmptyState(
                      icon: Icons.point_of_sale_outlined,
                      title: l10n.selectRegisterSessionPrompt,
                    )
                  : DefaultTabController(
                      length: showReconciliation ? 3 : 2,
                      child: Column(
                        children: [
                          TabBar(
                            tabs: [
                              if (showReconciliation)
                                Tab(text: l10n.sessionSummaryTab),
                              Tab(text: l10n.sessionSalesTab),
                              Tab(text: l10n.sessionCashMovementsTab),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                if (showReconciliation)
                                  _SessionSummaryPanel(viewModel: viewModel),
                                _SessionSalesList(
                                  viewModel: viewModel,
                                  contactRepository: contactRepository,
                                  capabilities: capabilities,
                                ),
                                _SessionCashMovementList(viewModel: viewModel),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionSummaryPanel extends StatelessWidget {
  const _SessionSummaryPanel({required this.viewModel});

  final RegisterSessionHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = viewModel.selectedSummary;

    if (summary == null && viewModel.isLoadingSummary) {
      return const Center(child: PointySpinner());
    }
    if (summary == null && viewModel.hasSummaryLoadError) {
      return PointyErrorState(
        title: l10n.sessionSummaryLoadError,
        icon: Icons.summarize_outlined,
        action: OutlinedButton.icon(
          onPressed: viewModel.refreshSelectedSummary,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (summary == null) {
      return PointyEmptyState(
        icon: Icons.summarize_outlined,
        title: l10n.selectRegisterSessionPrompt,
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        _ZReportActions(viewModel: viewModel),
        const SizedBox(height: 12),
        _SalesSummarySection(summary: summary),
        const SizedBox(height: 12),
        _PaymentMethodsSection(summary: summary),
        const SizedBox(height: 12),
        // Sits directly under the payment methods: it qualifies the card
        // row above it, and reads as a footnote to it rather than a
        // separate subject.
        CardReceiptVerificationSection(totals: summary.cardReceipts),
        const SizedBox(height: 12),
        _CategoriesSection(summary: summary),
        const SizedBox(height: 12),
        _CashReconciliationSection(summary: summary),
      ],
    );
  }
}

/// Print/share actions for the end-of-shift Z-Report: thermal drawer copy plus
/// the A4 PDF for archiving/sharing.
class _ZReportActions extends StatelessWidget {
  const _ZReportActions({required this.viewModel});

  final RegisterSessionHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final busy = viewModel.isPrintingZReport;
    return PointyDetailSection(
      title: l10n.sessionZReportTitle,
      icon: Icons.receipt_long_outlined,
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: PointySpinner(strokeWidth: 2),
            )
          : null,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => _run(
                    context,
                    viewModel.printZReportThermal,
                    l10n.sessionZReportPrintedMessage,
                  ),
            icon: const Icon(Icons.print_outlined),
            label: Text(l10n.sessionPrintZReportThermal),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => _run(
                    context,
                    viewModel.printZReportPdf,
                    l10n.sessionZReportPrintedMessage,
                    silentOnFalse: true,
                  ),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(l10n.sessionPrintZReportPdf),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => _run(
                    context,
                    viewModel.shareZReportPdf,
                    l10n.sessionZReportSharedMessage,
                    silentOnFalse: true,
                  ),
            icon: const Icon(Icons.share_outlined),
            label: Text(l10n.sessionShareZReportPdf),
          ),
        ],
      ),
    );
  }

  Future<void> _run(
    BuildContext context,
    Future<bool> Function() action,
    String successMessage, {
    bool silentOnFalse = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final delivered = await action();
    if (delivered) {
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } else if (!silentOnFalse) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.sessionZReportFailedMessage)),
      );
    }
  }
}

class _SalesSummarySection extends StatelessWidget {
  const _SalesSummarySection({required this.summary});

  final RegisterSessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final sales = summary.sales;
    final refunds = summary.refunds;

    return PointyDetailSection(
      title: l10n.sessionSalesSummaryTitle,
      icon: Icons.summarize_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySummaryList(
            rows: [
              PointySummaryRow(
                label: l10n.sessionGrossSalesMetric,
                value: formatMoney(sales.grossSales),
              ),
              if (sales.discountTotal > 0)
                PointySummaryRow(
                  label: l10n.sessionDiscountsMetric,
                  value: '- ${formatMoney(sales.discountTotal)}',
                  valueColor: colors.danger,
                ),
              if (refunds.refundTotal > 0)
                PointySummaryRow(
                  label: l10n.sessionRefundsMetric,
                  value: '- ${formatMoney(refunds.refundTotal)}',
                  valueColor: colors.danger,
                ),
              PointySummaryRow(
                label: l10n.sessionNetSalesMetric,
                value: formatMoney(sales.netSales),
                emphasized: true,
                dividerAbove: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          PointyMetricGrid(
            minTileWidth: 150,
            maxColumns: 4,
            metrics: [
              PointyMetricGridItem(
                icon: Icons.receipt_long_outlined,
                label: l10n.sessionOrderCountMetric,
                value: '${sales.orderCount}',
              ),
              PointyMetricGridItem(
                icon: Icons.inventory_2_outlined,
                label: l10n.sessionItemsSoldMetric,
                value: sales.itemsSold,
              ),
              if (sales.voidCount > 0)
                PointyMetricGridItem(
                  icon: Icons.block_outlined,
                  label: l10n.sessionVoidCountMetric,
                  value: '${sales.voidCount}',
                  accentColor: colors.danger,
                ),
              if (summary.expenses.count > 0)
                PointyMetricGridItem(
                  icon: Icons.receipt_outlined,
                  label: l10n.sessionExpensesMetric,
                  value: formatMoney(summary.expenses.total),
                ),
              if (summary.drawerPurchases.count > 0)
                PointyMetricGridItem(
                  icon: Icons.shopping_basket_outlined,
                  label: l10n.sessionDrawerPurchasesMetric,
                  value: formatMoney(summary.drawerPurchases.total),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaymentMethodsSection extends StatelessWidget {
  const _PaymentMethodsSection({required this.summary});

  final RegisterSessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.sessionPaymentMethodsTitle,
      icon: Icons.account_balance_wallet_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final method in summary.paymentMethods)
            _PaymentMethodRow(method: method),
          const Divider(height: 24),
          PointySummaryList(
            rows: [
              PointySummaryRow(
                label: l10n.sessionPaymentsTotalLabel,
                value: formatMoney(summary.paymentTotals.net),
                emphasized: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaymentMethodRow extends StatelessWidget {
  const _PaymentMethodRow({required this.method});

  final PaymentMethodBreakdown method;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final details = <String>[
      '${l10n.sessionPaymentCollectedLabel} ${formatMoney(method.gross)}',
      if (method.commission > 0)
        '${l10n.sessionPaymentCommissionLabel} ${formatMoney(method.commission)}',
      if (method.refund > 0)
        '${l10n.sessionPaymentRefundLabel} ${formatMoney(method.refund)}',
    ].join(' • ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _paymentMethodLabel(l10n, method.method),
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        l10n.sessionPaymentOperationsCount(method.count),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(formatMoney(method.net), style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _CategoriesSection extends StatelessWidget {
  const _CategoriesSection({required this.summary});

  final RegisterSessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final categories = summary.categories;
    return PointyDetailSection(
      title: l10n.sessionCategoriesTitle,
      icon: Icons.category_outlined,
      child: categories.isEmpty
          ? Text(l10n.sessionNoCategorySales)
          : PointySummaryList(
              rows: [
                for (final category in categories)
                  PointySummaryRow(
                    label: l10n.sessionCategoryLineLabel(
                      category.category ?? l10n.sessionUncategorizedLabel,
                      category.quantity,
                    ),
                    value: formatMoney(category.net),
                  ),
              ],
            ),
    );
  }
}

class _CashReconciliationSection extends StatelessWidget {
  const _CashReconciliationSection({required this.summary});

  final RegisterSessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final cash = summary.cash;
    final variance = cash.cashVariance;

    return PointyDetailSection(
      title: l10n.sessionCashSummaryTitle,
      icon: Icons.point_of_sale_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySummaryList(
            rows: [
              PointySummaryRow(
                label: l10n.sessionOpeningCashMetric,
                value: formatMoney(cash.openingCash),
              ),
              PointySummaryRow(
                label: l10n.sessionCashSalesMetric,
                value: formatMoney(cash.cashSalesTotal),
              ),
              if (cash.payInTotal > 0)
                PointySummaryRow(
                  label: l10n.sessionPayInMetric,
                  value: formatMoney(cash.payInTotal),
                ),
              if (cash.payOutTotal > 0)
                PointySummaryRow(
                  label: l10n.sessionPayOutMetric,
                  value: '- ${formatMoney(cash.payOutTotal)}',
                  valueColor: colors.danger,
                ),
              if (cash.cashRefundTotal > 0)
                PointySummaryRow(
                  label: l10n.sessionCashRefundMetric,
                  value: '- ${formatMoney(cash.cashRefundTotal)}',
                  valueColor: colors.danger,
                ),
              PointySummaryRow(
                label: l10n.sessionExpectedCashMetric,
                value: formatMoney(cash.expectedCash),
                emphasized: true,
                dividerAbove: true,
              ),
              if (cash.closingCash != null)
                PointySummaryRow(
                  label: l10n.sessionClosingCashMetric,
                  value: formatMoney(cash.closingCash!),
                ),
              if (variance != null)
                PointySummaryRow(
                  label: l10n.sessionCashVarianceMetric,
                  value: formatMoney(variance),
                  emphasized: true,
                  valueColor: cash.hasCashVariance
                      ? colors.danger
                      : colors.primaryStrong,
                ),
            ],
          ),
          const SizedBox(height: 16),
          PointySectionHeader(title: l10n.sessionDenominationsTitle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final denomination in cash.denominations)
                _DenominationChip(
                  label: denomination.value,
                  count: denomination.count,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _paymentMethodLabel(AppLocalizations l10n, String method) {
  return switch (method) {
    'cash' => l10n.paymentMethodCash,
    'card' => l10n.paymentMethodCard,
    'transfer' => l10n.paymentMethodTransfer,
    _ => method,
  };
}

class _DenominationChip extends StatelessWidget {
  const _DenominationChip({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label x $count'));
  }
}

class _SessionSalesList extends StatelessWidget {
  const _SessionSalesList({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SessionOrderFilters(
          viewModel: viewModel,
          contactRepository: contactRepository,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: PointyDataList<SaleOrder>(
            items: viewModel.orders,
            onLoadMore: viewModel.loadMoreOrders,
            hasMore: viewModel.hasMoreOrders,
            isLoadingInitial: viewModel.isLoadingOrders,
            isLoadingMore: viewModel.isLoadingMoreOrders,
            hasError: viewModel.hasOrderLoadError,
            errorBuilder: (context) => PointyErrorState(
              title: l10n.sessionSalesLoadError,
              icon: Icons.receipt_long_outlined,
              action: OutlinedButton.icon(
                onPressed: viewModel.retrySelectedSessionOrders,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retryButton),
              ),
            ),
            emptyBuilder: (context) => PointyEmptyState(
              icon: Icons.receipt_long_outlined,
              title: l10n.emptySessionSales,
            ),
            itemBuilder: (context, order) {
              final hasReturnableItems = order.hasReturnableItems;
              final canManagerAdjust =
                  capabilities.canManageShopSettings &&
                  order.status == 'paid' &&
                  hasReturnableItems;
              final canVoid = order.canVoid || canManagerAdjust;
              final canReturn = order.canReturn || canManagerAdjust;
              return SessionOrderTile(
                order: order,
                loadDetail: viewModel.loadOrderDetail,
                onReprint: viewModel.requestReprint,
                onVoid: canVoid ? viewModel.voidOrder : null,
                onReturn: canReturn ? viewModel.returnItems : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SessionOrderFilters extends StatelessWidget {
  const _SessionOrderFilters({
    required this.viewModel,
    required this.contactRepository,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = viewModel.orderQuery;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilterChip(
          avatar: const Icon(Icons.person_outline, size: 18),
          label: Text(query.customerName ?? l10n.allCustomersFilterLabel),
          selected: query.hasCustomerFilter,
          onSelected: viewModel.isLoadingOrders
              ? null
              : (_) => _chooseCustomer(context),
        ),
        if (query.hasCustomerFilter)
          IconButton.outlined(
            tooltip: l10n.clearCustomerFilterTooltip,
            onPressed: viewModel.isLoadingOrders
                ? null
                : () => viewModel.filterOrdersByCustomer(null),
            icon: const Icon(Icons.close),
          ),
      ],
    );
  }

  Future<void> _chooseCustomer(BuildContext context) async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: contactRepository,
    );
    if (customer != null) {
      await viewModel.filterOrdersByCustomer(customer);
    }
  }
}

class _SessionCashMovementList extends StatelessWidget {
  const _SessionCashMovementList({required this.viewModel});

  final RegisterSessionHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDataList<RegisterCashMovement>(
      items: viewModel.cashMovements,
      onLoadMore: viewModel.loadMoreCashMovements,
      hasMore: viewModel.hasMoreCashMovements,
      isLoadingInitial: viewModel.isLoadingCashMovements,
      isLoadingMore: viewModel.isLoadingMoreCashMovements,
      hasError: viewModel.hasCashMovementLoadError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.sessionCashMovementsLoadError,
        icon: Icons.payments_outlined,
        action: OutlinedButton.icon(
          onPressed: viewModel.retrySelectedSessionCashMovements,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.payments_outlined,
        title: l10n.emptySessionCashMovements,
      ),
      itemBuilder: (context, movement) {
        return SessionCashMovementTile(movement: movement);
      },
    );
  }
}

class SessionOrderTile extends StatelessWidget {
  const SessionOrderTile({
    super.key,
    required this.order,
    this.loadDetail,
    this.onReprint,
    this.onVoid,
    this.onReturn,
  });

  final SaleOrder order;
  final SaleOrderDetailLoader? loadDetail;
  final Future<bool> Function(SaleOrder order)? onReprint;
  final Future<bool> Function(SaleOrder order, {String reason})? onVoid;
  final Future<bool> Function(
    SaleOrder order, {
    required List<SaleReturnLineDraft> lines,
    String reason,
  })?
  onReturn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final receiptNumber = order.receiptNumber ?? l10n.saleReceiptFallback;

    return PointyDataRow(
      leading: const Icon(Icons.receipt_long_outlined),
      title: l10n.saleReceiptTitle(receiptNumber),
      subtitle: [
        if (order.createdAt != null) formatDateTime(order.createdAt!),
        l10n.lineItemCount(order.lineCount),
        if (order.customerName != null && order.customerName!.isNotEmpty)
          order.customerName!,
      ].join(' • '),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatMoney(order.total),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (order.profit != null)
            Text(
              l10n.invoiceProfitValue(formatMoney(order.profit!)),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.primaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
      onTap: () => showSaleOrderDetailsSheet(
        context,
        order,
        loadDetail: loadDetail,
        onReprint: onReprint,
        onVoid: onVoid == null
            ? null
            : (order, reason) => onVoid!(order, reason: reason),
        onReturn: onReturn == null
            ? null
            : (order, lines, reason) =>
                  onReturn!(order, lines: lines, reason: reason),
      ),
    );
  }
}

class SessionCashMovementTile extends StatelessWidget {
  const SessionCashMovementTile({super.key, required this.movement});

  final RegisterCashMovement movement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final isPayIn = movement.movementType == RegisterCashMovementType.payIn;

    return PointyDataRow(
      leading: Icon(isPayIn ? Icons.input : Icons.output),
      title: isPayIn
          ? l10n.cashMovementPayInLabel
          : l10n.cashMovementPayOutLabel,
      subtitle: [
        if (movement.createdAt != null) formatDateTime(movement.createdAt!),
        movement.reason,
      ].join(' • '),
      trailing: Text(
        formatMoney(movement.amount),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: isPayIn ? colors.primaryStrong : colors.danger,
        ),
      ),
    );
  }
}
