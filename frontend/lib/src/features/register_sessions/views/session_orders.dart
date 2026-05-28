import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/register_session_history_view_model.dart';
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
                : l10n.sessionSalesTitle(session.sessionNumber),
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
                                  _SessionSummaryPanel(session: session),
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
        PointySectionHeader(title: l10n.sessionCashSummaryTitle),
        const SizedBox(height: 8),
        PointyMetricTile(
          icon: Icons.lock_open_outlined,
          label: l10n.sessionOpeningCashMetric,
          value: formatMoney(session.openingCash),
        ),
        PointyMetricTile(
          icon: Icons.payments_outlined,
          label: l10n.sessionCashSalesMetric,
          value: formatMoney(session.cashSalesTotal),
        ),
        PointyMetricTile(
          icon: Icons.input,
          label: l10n.sessionPayInMetric,
          value: formatMoney(session.payInTotal),
        ),
        PointyMetricTile(
          icon: Icons.output,
          label: l10n.sessionPayOutMetric,
          value: formatMoney(session.payOutTotal),
        ),
        PointyMetricTile(
          icon: Icons.keyboard_return_outlined,
          label: l10n.sessionCashRefundMetric,
          value: formatMoney(session.cashRefundTotal),
        ),
        const Divider(height: 24),
        PointyMetricTile(
          icon: Icons.calculate_outlined,
          label: l10n.sessionExpectedCashMetric,
          value: formatMoney(session.expectedCash),
        ),
        PointyMetricTile(
          icon: Icons.fact_check_outlined,
          label: l10n.sessionClosingCashMetric,
          value: session.closingCash == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(session.closingCash!),
        ),
        PointyMetricTile(
          icon: Icons.difference_outlined,
          label: l10n.sessionCashVarianceMetric,
          value: variance == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(variance),
          accentColor: session.hasCashVariance
              ? colorScheme.error
              : colorScheme.primary,
        ),
        const SizedBox(height: 16),
        PointySectionHeader(title: l10n.sessionDenominationsTitle),
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
        PointyMetricTile(
          icon: Icons.inventory_2_outlined,
          label: l10n.sessionDenominationTotalMetric,
          value: formatMoney(session.denominationTotal),
        ),
      ],
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
            ),
            emptyBuilder: (context) => PointyEmptyState(
              icon: Icons.receipt_long_outlined,
              title: l10n.emptySessionSales,
            ),
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

    return PointyDataRow(
      leading: const Icon(Icons.receipt_long_outlined),
      title: l10n.saleReceiptTitle(receiptNumber),
      subtitle: [
        if (order.createdAt != null) formatDateTime(order.createdAt!),
        l10n.saleLineCount(order.lines.length),
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
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
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
          color: isPayIn
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}
