import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/sale_order.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../view_models/register_session_history_view_model.dart';
import 'sale_order_details_sheet.dart';

class SessionOrders extends StatelessWidget {
  const SessionOrders({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = viewModel.selectedSession;
    final showReconciliation = capabilities.canManageShopSettings;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            session == null
                ? l10n.sessionSalesPlaceholderTitle
                : l10n.sessionSalesTitle(session.sessionNumber),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: RegisterSessionOrdersGuard(
              capabilities: capabilities,
              child: session == null
                  ? Center(child: Text(l10n.selectRegisterSessionPrompt))
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
                                  _SessionSummaryPanel(session: session),
                                _SessionSalesList(
                                  viewModel: viewModel,
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
  const _SessionSummaryPanel({required this.session});

  final RegisterSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final variance = session.cashVariance;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Text(
          l10n.sessionCashSummaryTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _CashMetric(
          icon: Icons.lock_open_outlined,
          label: l10n.sessionOpeningCashMetric,
          value: formatMoney(session.openingCash),
        ),
        _CashMetric(
          icon: Icons.payments_outlined,
          label: l10n.sessionCashSalesMetric,
          value: formatMoney(session.cashSalesTotal),
        ),
        _CashMetric(
          icon: Icons.input,
          label: l10n.sessionPayInMetric,
          value: formatMoney(session.payInTotal),
        ),
        _CashMetric(
          icon: Icons.output,
          label: l10n.sessionPayOutMetric,
          value: formatMoney(session.payOutTotal),
        ),
        _CashMetric(
          icon: Icons.keyboard_return_outlined,
          label: l10n.sessionCashRefundMetric,
          value: formatMoney(session.cashRefundTotal),
        ),
        const Divider(height: 24),
        _CashMetric(
          icon: Icons.calculate_outlined,
          label: l10n.sessionExpectedCashMetric,
          value: formatMoney(session.expectedCash),
          isEmphasized: true,
        ),
        _CashMetric(
          icon: Icons.fact_check_outlined,
          label: l10n.sessionClosingCashMetric,
          value: session.closingCash == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(session.closingCash!),
          isEmphasized: true,
        ),
        _CashMetric(
          icon: Icons.difference_outlined,
          label: l10n.sessionCashVarianceMetric,
          value: variance == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(variance),
          valueColor: session.hasCashVariance
              ? colorScheme.error
              : colorScheme.primary,
          isEmphasized: session.hasCashVariance,
        ),
        const SizedBox(height: 16),
        Text(
          l10n.sessionDenominationsTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _DenominationChip(label: '0.25', count: session.count025),
            _DenominationChip(label: '0.50', count: session.count050),
            _DenominationChip(label: '0.75', count: session.count075),
            _DenominationChip(label: '1.00', count: session.count100),
          ],
        ),
        const SizedBox(height: 8),
        _CashMetric(
          icon: Icons.inventory_2_outlined,
          label: l10n.sessionDenominationTotalMetric,
          value: formatMoney(session.denominationTotal),
        ),
      ],
    );
  }
}

class _CashMetric extends StatelessWidget {
  const _CashMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.isEmphasized = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool isEmphasized;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      trailing: Text(
        value,
        style: (isEmphasized ? textTheme.titleMedium : textTheme.bodyLarge)
            ?.copyWith(color: valueColor),
      ),
    );
  }
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
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch ((
      viewModel.isLoadingOrders,
      viewModel.hasOrderLoadError,
      viewModel.orders.isEmpty,
    )) {
      (true, _, _) => const Center(child: CircularProgressIndicator()),
      (_, true, _) => Center(child: Text(l10n.sessionSalesLoadError)),
      (_, _, true) => Center(child: Text(l10n.emptySessionSales)),
      _ => InfiniteScrollList(
        items: viewModel.orders,
        onLoadMore: viewModel.loadMoreOrders,
        hasMore: viewModel.hasMoreOrders,
        isLoadingInitial: viewModel.isLoadingOrders,
        isLoadingMore: viewModel.isLoadingMoreOrders,
        emptyBuilder: (context) => Center(child: Text(l10n.emptySessionSales)),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, order) {
          final hasReturnableItems = order.lines.any(
            (line) => line.returnableQuantity > 0,
          );
          final canManagerAdjust =
              capabilities.canManageShopSettings &&
              order.status == 'paid' &&
              hasReturnableItems;
          final canVoid = order.canVoid || canManagerAdjust;
          final canReturn = order.canReturn || canManagerAdjust;
          return SessionOrderTile(
            order: order,
            onReprint: viewModel.requestReprint,
            onVoid: canVoid ? viewModel.voidOrder : null,
            onReturn: canReturn ? viewModel.returnItems : null,
          );
        },
      ),
    };
  }
}

class _SessionCashMovementList extends StatelessWidget {
  const _SessionCashMovementList({required this.viewModel});

  final RegisterSessionHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch ((
      viewModel.isLoadingCashMovements,
      viewModel.hasCashMovementLoadError,
      viewModel.cashMovements.isEmpty,
    )) {
      (true, _, _) => const Center(child: CircularProgressIndicator()),
      (_, true, _) => Center(child: Text(l10n.sessionCashMovementsLoadError)),
      (_, _, true) => Center(child: Text(l10n.emptySessionCashMovements)),
      _ => InfiniteScrollList(
        items: viewModel.cashMovements,
        onLoadMore: viewModel.loadMoreCashMovements,
        hasMore: viewModel.hasMoreCashMovements,
        isLoadingInitial: viewModel.isLoadingCashMovements,
        isLoadingMore: viewModel.isLoadingMoreCashMovements,
        emptyBuilder: (context) =>
            Center(child: Text(l10n.emptySessionCashMovements)),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, movement) {
          return SessionCashMovementTile(movement: movement);
        },
      ),
    };
  }
}

class SessionOrderTile extends StatelessWidget {
  const SessionOrderTile({
    super.key,
    required this.order,
    this.onReprint,
    this.onVoid,
    this.onReturn,
  });

  final SaleOrder order;
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
    final receiptNumber = order.receiptNumber ?? l10n.saleReceiptFallback;

    return ListTile(
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(l10n.saleReceiptTitle(receiptNumber)),
      subtitle: Text(
        [
          if (order.createdAt != null) formatDateTime(order.createdAt!),
          l10n.saleLineCount(order.lines.length),
        ].join(' • '),
      ),
      trailing: Text(
        formatMoney(order.total),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      onTap: () => showSaleOrderDetailsSheet(
        context,
        order,
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
    final isPayIn = movement.movementType == RegisterCashMovementType.payIn;

    return ListTile(
      leading: Icon(isPayIn ? Icons.input : Icons.output),
      title: Text(
        isPayIn ? l10n.cashMovementPayInLabel : l10n.cashMovementPayOutLabel,
      ),
      subtitle: Text(
        [
          if (movement.createdAt != null) formatDateTime(movement.createdAt!),
          movement.reason,
        ].join(' • '),
      ),
      trailing: Text(
        formatMoney(movement.amount),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: isPayIn
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}
