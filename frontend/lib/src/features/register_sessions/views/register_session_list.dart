import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_session.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/register_session_history_view_model.dart';

class RegisterSessionList extends StatelessWidget {
  const RegisterSessionList({
    super.key,
    required this.viewModel,
    required this.capabilities,
    this.onSessionSelected,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final void Function(RegisterSession session)? onSessionSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: spacing.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointySectionHeader(title: l10n.registerSessionsListTitle),
            SizedBox(height: spacing.sm),
            Expanded(
              child: PointyDataList<RegisterSession>(
                items: viewModel.sessions,
                onLoadMore: viewModel.loadMoreSessions,
                hasMore: viewModel.hasMoreSessions,
                isLoadingInitial: viewModel.isLoadingSessions,
                isLoadingMore: viewModel.isLoadingMoreSessions,
                hasError: viewModel.hasSessionLoadError,
                errorBuilder: (context) => PointyErrorState(
                  title: l10n.registerSessionHistoryLoadError,
                  icon: Icons.manage_history_outlined,
                ),
                emptyBuilder: (context) => PointyEmptyState(
                  icon: Icons.manage_history_outlined,
                  title: l10n.emptyRegisterSessionHistory,
                ),
                itemBuilder: (context, session) {
                  return RegisterSessionOrdersCapabilityBuilder(
                    capabilities: capabilities,
                    builder: (context, canViewOrders) {
                      void handleTap() {
                        final handler = onSessionSelected;
                        if (handler != null) {
                          handler(session);
                          return;
                        }
                        unawaited(viewModel.selectSession(session));
                      }

                      return RegisterSessionTile(
                        session: session,
                        isSelected: viewModel.selectedSession?.id == session.id,
                        showCashVariance: capabilities.canManageShopSettings,
                        onTap: canViewOrders ? handleTap : null,
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
    final colorScheme = Theme.of(context).colorScheme;
    final statusLabel = session.status == 'closed'
        ? l10n.registerSessionStatusClosed
        : l10n.registerSessionStatusOpen;
    final statusIcon = session.status == 'closed'
        ? Icons.lock_outline
        : Icons.point_of_sale_outlined;

    return PointyDataRow(
      selected: isSelected,
      leading: Icon(statusIcon, color: colorScheme.primary),
      title: l10n.resumeRegisterSessionTitle(session.sessionNumber),
      subtitle: [
        if (session.openedAt != null) formatDateTime(session.openedAt!),
        l10n.registerSessionOpeningCash(formatMoney(session.openingCash)),
      ].join(' • '),
      badges: [PointyStatusPill(label: statusLabel, icon: statusIcon)],
      trailing: onTap == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showCashVariance && session.hasCashVariance) ...[
                  _VarianceChip(amount: session.cashVariance ?? 0),
                  const SizedBox(width: 8),
                ],
                const PointyDisclosureChevron(),
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
