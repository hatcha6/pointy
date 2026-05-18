import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_session.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../view_models/register_session_history_view_model.dart';

class RegisterSessionList extends StatelessWidget {
  const RegisterSessionList({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.registerSessionsListTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: viewModel.hasSessionLoadError && viewModel.sessions.isEmpty
                  ? Center(child: Text(l10n.registerSessionHistoryLoadError))
                  : InfiniteScrollList(
                      items: viewModel.sessions,
                      onLoadMore: viewModel.loadMoreSessions,
                      hasMore: viewModel.hasMoreSessions,
                      isLoadingInitial: viewModel.isLoadingSessions,
                      isLoadingMore: viewModel.isLoadingMoreSessions,
                      emptyBuilder: (context) {
                        return Center(
                          child: Text(l10n.emptyRegisterSessionHistory),
                        );
                      },
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, session) {
                        return RegisterSessionOrdersCapabilityBuilder(
                          capabilities: capabilities,
                          builder: (context, canViewOrders) {
                            return RegisterSessionTile(
                              session: session,
                              isSelected:
                                  viewModel.selectedSession?.id == session.id,
                              showCashVariance:
                                  capabilities.canManageShopSettings,
                              onTap: canViewOrders
                                  ? () => viewModel.selectSession(session)
                                  : null,
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class RegisterSessionTile extends StatelessWidget {
  const RegisterSessionTile({
    super.key,
    required this.session,
    required this.isSelected,
    required this.showCashVariance,
    this.onTap,
  });

  final RegisterSession session;
  final bool isSelected;
  final bool showCashVariance;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusLabel = session.status == 'closed'
        ? l10n.registerSessionStatusClosed
        : l10n.registerSessionStatusOpen;

    return ListTile(
      selected: isSelected,
      leading: Icon(
        session.status == 'closed'
            ? Icons.lock_outline
            : Icons.point_of_sale_outlined,
      ),
      title: Text(l10n.resumeRegisterSessionTitle(session.sessionNumber)),
      subtitle: Text(
        [
          statusLabel,
          if (session.openedAt != null) formatDateTime(session.openedAt!),
          l10n.registerSessionOpeningCash(formatMoney(session.openingCash)),
        ].join(' • '),
      ),
      trailing: onTap == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showCashVariance && session.hasCashVariance) ...[
                  _VarianceChip(amount: session.cashVariance ?? 0),
                  const SizedBox(width: 8),
                ],
                const Icon(Icons.chevron_right),
              ],
            ),
      onTap: onTap,
    );
  }
}

class _VarianceChip extends StatelessWidget {
  const _VarianceChip({required this.amount});

  final double amount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: l10n.sessionCashVarianceMetric,
      child: Chip(
        avatar: Icon(
          Icons.warning_amber_outlined,
          size: 18,
          color: colorScheme.error,
        ),
        label: Text(l10n.sessionVarianceFlag(formatMoney(amount))),
        side: BorderSide(color: colorScheme.error),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
