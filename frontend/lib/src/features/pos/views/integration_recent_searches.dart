import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../data/models/integration_recent_search.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../settings/views/integration_presentation.dart';
import '../view_models/integration_recent_searches_view_model.dart';

/// The searches that found something before, newest first — what the till's
/// top-up screen opens on instead of an empty box.
///
/// It scrolls without end (the next page loads as the cashier nears the
/// bottom) and the search box above narrows it as they type. Tapping a row
/// asks the provider again: nothing on it is sold as it stands.
class RechargeRecentSearches extends StatelessWidget {
  const RechargeRecentSearches({
    super.key,
    required this.viewModel,
    required this.provider,
    required this.onRun,
    required this.onLookUp,
    this.now,
  });

  final IntegrationRecentSearchesViewModel viewModel;
  final IntegrationProviderKey provider;

  /// Run this search again.
  final ValueChanged<IntegrationRecentSearch> onRun;

  /// Ask the provider about something no past search matched. The list only
  /// holds what was found before, so an empty filter must not be a dead end.
  final ValueChanged<String> onLookUp;

  /// Injectable so a preview or a test renders a fixed "today".
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    Widget sized(Widget child) =>
        AdaptiveMaxWidth(width: AppContentWidth.detail, child: child);

    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: spacing.pageHorizontal,
      ),
      child: PointyDataList<IntegrationRecentSearch>(
        items: viewModel.searches,
        isLoadingInitial: viewModel.isLoading,
        isLoadingMore: viewModel.isLoadingMore,
        hasMore: viewModel.hasMore,
        onLoadMore: viewModel.loadMore,
        loadMoreFailed: viewModel.loadMoreFailed,
        loadMoreErrorMessage: l10n.rechargeRecentLoadError,
        hasError: viewModel.hasError,
        framed: false,
        padding: EdgeInsets.only(bottom: spacing.pageVertical),
        header: sized(_Heading(spacing: spacing)),
        separatorBuilder: (_, _) => SizedBox(height: spacing.xs),
        itemBuilder: (context, search) => sized(
          _RecentSearchRow(
            search: search,
            onTap: () => onRun(search),
            now: now,
          ),
        ),
        errorBuilder: (context) => PointyErrorState(
          icon: Icons.history_toggle_off_outlined,
          title: l10n.rechargeRecentLoadError,
          action: FilledButton.tonalIcon(
            onPressed: viewModel.load,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retryButton),
          ),
        ),
        emptyBuilder: (context) {
          final query = viewModel.query;
          if (query.isEmpty) {
            return PointyEmptyState(
              icon: Icons.sim_card_outlined,
              title: integrationSubscriberPrompt(provider, l10n).prompt,
              message: l10n.rechargeRecentEmptyMessage,
            );
          }
          return PointyEmptyState(
            icon: Icons.search_off,
            title: l10n.rechargeRecentNoMatch(ltrIsolated(query)),
            message: l10n.rechargeRecentNoMatchMessage,
            action: FilledButton.icon(
              onPressed: () => onLookUp(query),
              icon: const Icon(Icons.search),
              label: Text(l10n.rechargeRecentLookUp),
            ),
          );
        },
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.spacing});

  final AdaptiveSpacing spacing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return Padding(
      padding: EdgeInsetsDirectional.only(top: spacing.xs, bottom: spacing.sm),
      child: Row(
        children: [
          Icon(Icons.history, size: 18, color: colors.mutedInk),
          SizedBox(width: spacing.xs),
          Text(
            l10n.rechargeRecentTitle,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}

class _RecentSearchRow extends StatelessWidget {
  const _RecentSearchRow({required this.search, required this.onTap, this.now});

  final IntegrationRecentSearch search;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final title = recentSearchTitle(search);
    final when = search.lastSearchedAt;

    return PointyDataRow(
      title: title,
      subtitle: recentSearchSubtitle(search, l10n, title: title),
      minHeight: 60,
      onTap: onTap,
      leading: Icon(
        // A named regular reads differently from an anonymous card, and a
        // household search is a choice still to be made, not a line.
        search.subscriberLabel.isNotEmpty
            ? Icons.person_outline
            : (search.foundSeveralLines
                  ? Icons.call_split
                  : Icons.sim_card_outlined),
        color: colors.primaryStrong,
      ),
      trailing: when == null
          ? null
          : Text(
              recentSearchWhen(when, l10n, now: now),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
    );
  }
}

/// Who or what a past search found — the name the shop gave the card when
/// there is one, else the line it found, else (for a household still to
/// choose between) what was typed.
String recentSearchTitle(IntegrationRecentSearch search) {
  if (search.subscriberLabel.isNotEmpty) return search.subscriberLabel;
  if (!search.foundSeveralLines && search.cardNo.isNotEmpty) {
    return ltrIsolated(search.cardNo);
  }
  return ltrIsolated(search.term);
}

/// The rest of what a cashier needs to recognise a past search, minus
/// whatever [title] already says.
String recentSearchSubtitle(
  IntegrationRecentSearch search,
  AppLocalizations l10n, {
  required String title,
}) {
  final mode = search.searchMode;
  final modeLabel = mode == null
      ? null
      : integrationSearchModeLabel(mode, l10n).label;
  if (search.foundSeveralLines) {
    return [
      ?modeLabel,
      l10n.rechargeRecentLines(search.matchCount),
    ].join(' · ');
  }
  final typed = ltrIsolated(search.term);
  return [
    // The line itself, when a name took the title.
    if (search.subscriberLabel.isNotEmpty && search.cardNo.isNotEmpty)
      ltrIsolated(search.cardNo),
    // What was typed, when it is not the line it found — a phone number
    // that found a username is how the cashier will recognise it.
    if (search.cardNo.isNotEmpty && search.term != search.cardNo)
      modeLabel == null ? typed : '$modeLabel $typed',
    if (search.holderName.isNotEmpty && search.holderName != title)
      search.holderName,
    if (search.packageName.isNotEmpty) search.packageName,
  ].join(' · ');
}

/// When it was last searched, the way a cashier would say it.
String recentSearchWhen(DateTime at, AppLocalizations l10n, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final local = at.toLocal();
  if (DateUtils.isSameDay(local, today)) {
    return l10n.rechargeRecentToday(formatTime(local));
  }
  if (DateUtils.isSameDay(local, today.subtract(const Duration(days: 1)))) {
    return l10n.rechargeRecentYesterday(formatTime(local));
  }
  return formatDate(local);
}
