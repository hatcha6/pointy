import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_session.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/register_session_history_view_model.dart';
import 'session_cash_variance.dart';

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

    // A sliver page, so the pane scrolls from anywhere on it, title included.
    return PointyDataList<RegisterSession>(
      items: viewModel.sessions,
      onLoadMore: viewModel.loadMoreSessions,
      hasMore: viewModel.hasMoreSessions,
      isLoadingInitial: viewModel.isLoadingSessions,
      isLoadingMore: viewModel.isLoadingMoreSessions,
      hasError: viewModel.hasSessionLoadError,
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.pageHorizontal,
        0,
        spacing.pageHorizontal,
        spacing.pageVertical,
      ),
      headerSlivers: [
        SliverPadding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.pageHorizontal,
            spacing.pageVertical,
            spacing.pageHorizontal,
            spacing.sm,
          ),
          sliver: SliverToBoxAdapter(
            child: PointySectionHeader(title: l10n.registerSessionsListTitle),
          ),
        ),
      ],
      errorBuilder: (context) => PointyErrorState(
        title: l10n.registerSessionHistoryLoadError,
        icon: Icons.manage_history_outlined,
        action: OutlinedButton.icon(
          onPressed: viewModel.loadSessions,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
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
              showCashVariance: capabilities.canViewRegisterReconciliation,
              onTap: canViewOrders ? handleTap : null,
            );
          },
        );
      },
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
    final colors = context.pointyColors;
    final isClosed = session.status == 'closed';
    final openedAt = session.openedAt;
    final closedAt = session.closedAt;
    final closingCash = session.closingCash;
    // The count against the drawer is the reconciliation viewer's figure; a
    // cashier who closed blind sees the float they started with.
    final showCount = showCashVariance && isClosed && closingCash != null;
    final variance = session.cashVariance ?? 0;
    final varianceColor = sessionCashVarianceColor(context, variance);

    return PointyDocumentRow(
      selected: isSelected,
      // Accountability first: whose drawer this was.
      party: session.ownerName.isEmpty
          ? l10n.resumeRegisterSessionTitle(session.sessionNumber)
          : session.ownerName,
      // Without an owner the session number is already the title.
      reference: session.ownerName.isEmpty
          ? ''
          : l10n.invoiceRegisterSessionValue(session.sessionNumber),
      date: openedAt == null ? null : formatDateTime(openedAt),
      amountLabel: showCount
          ? l10n.sessionClosingCashMetric
          : l10n.sessionOpeningCashMetric,
      amount: formatMoney(showCount ? closingCash : session.openingCash),
      // An open drawer has not been counted, so it has no variance yet —
      // a live one would always read as a shortage.
      secondaryAmount: !isClosed
          ? l10n.registerSessionInProgressValue
          : showCount && session.hasCashVariance
          ? sessionCashVarianceFlag(l10n, variance)
          : showCount
          ? l10n.sessionCashMatchedValue
          : null,
      secondaryAmountColor: !isClosed ? colors.success : varianceColor,
      accentColor: !isClosed
          ? colors.success
          : showCount && session.hasCashVariance
          ? varianceColor
          : colors.lineStrong,
      badges: [
        PointyStatusPill(
          label: isClosed
              ? l10n.registerSessionStatusClosed
              : l10n.registerSessionStatusOpen,
          icon: isClosed ? Icons.lock_outline : Icons.point_of_sale_outlined,
          color: isClosed ? colors.mutedInk : colors.success,
        ),
      ],
      meta: [
        if (closedAt != null)
          PointyDocumentMeta(
            icon: Icons.lock_clock_outlined,
            label: l10n.registerSessionClosedAtValue(
              openedAt != null && _sameDay(openedAt, closedAt)
                  ? formatTime(closedAt)
                  : formatDateTime(closedAt),
            ),
          ),
        if (openedAt != null && closedAt != null)
          PointyDocumentMeta(
            icon: Icons.timelapse_outlined,
            label: _duration(l10n, closedAt.difference(openedAt)),
          ),
      ],
      onTap: onTap,
    );
  }
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String _duration(AppLocalizations l10n, Duration duration) {
  final minutes = duration.inMinutes < 0 ? 0 : duration.inMinutes;
  return l10n.registerSessionDurationValue(minutes ~/ 60, minutes % 60);
}
