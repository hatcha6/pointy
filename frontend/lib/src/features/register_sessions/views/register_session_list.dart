import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/register_session.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../view_models/register_session_history_view_model.dart';

class RegisterSessionList extends StatelessWidget {
  const RegisterSessionList({super.key, required this.viewModel});

  final RegisterSessionHistoryViewModel viewModel;

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
                        return RegisterSessionTile(
                          session: session,
                          isSelected:
                              viewModel.selectedSession?.id == session.id,
                          onTap: () => viewModel.selectSession(session),
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
    required this.onTap,
  });

  final RegisterSession session;
  final bool isSelected;
  final VoidCallback onTap;

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
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
