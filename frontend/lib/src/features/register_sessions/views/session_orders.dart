import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../view_models/register_session_history_view_model.dart';
import 'sale_order_details_sheet.dart';

class SessionOrders extends StatelessWidget {
  const SessionOrders({super.key, required this.viewModel});

  final RegisterSessionHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = viewModel.selectedSession;

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
            child: switch ((
              session,
              viewModel.isLoadingOrders,
              viewModel.hasOrderLoadError,
              viewModel.orders.isEmpty,
            )) {
              (null, _, _, _) => Center(
                child: Text(l10n.selectRegisterSessionPrompt),
              ),
              (_, true, _, _) => const Center(
                child: CircularProgressIndicator(),
              ),
              (_, _, true, _) => Center(
                child: Text(l10n.sessionSalesLoadError),
              ),
              (_, _, _, true) => Center(child: Text(l10n.emptySessionSales)),
              _ => ListView.separated(
                itemCount: viewModel.orders.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  return SessionOrderTile(order: viewModel.orders[index]);
                },
              ),
            },
          ),
        ],
      ),
    );
  }
}

class SessionOrderTile extends StatelessWidget {
  const SessionOrderTile({super.key, required this.order});

  final SaleOrder order;

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
      onTap: () => showSaleOrderDetailsSheet(context, order),
    );
  }
}
