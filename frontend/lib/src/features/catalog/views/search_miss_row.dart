import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/search_miss.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';

/// One word the catalogue's search found nothing for, and what the owner can
/// do about it: say which product it meant, or set it aside — or, once
/// handled, put it back on the open list.
class SearchMissRow extends StatelessWidget {
  const SearchMissRow({
    super.key,
    required this.miss,
    required this.busy,
    required this.onResolve,
    required this.onDismiss,
    required this.onReopen,
    this.markDismissed = false,
    this.now,
  });

  final SearchMiss miss;

  /// An action on this row is in flight: its buttons give way to a spinner.
  final bool busy;
  final VoidCallback onResolve;
  final VoidCallback onDismiss;
  final VoidCallback onReopen;

  /// Badge a dismissed row as such. Only worth saying where it sits among
  /// rows of every status.
  final bool markDismissed;

  /// Injectable so a preview or a test renders a fixed "today".
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final productName = miss.productName;

    return PointyDataRow(
      title: miss.term,
      subtitle: searchMissSubtitle(miss, l10n, now: now),
      minHeight: 60,
      leading: Icon(switch (miss.status) {
        SearchMissStatus.open => Icons.search_off,
        SearchMissStatus.resolved => Icons.link,
        SearchMissStatus.dismissed => Icons.do_not_disturb_on_outlined,
      }, color: _statusColor(colors)),
      badges: [
        if (miss.status == SearchMissStatus.resolved)
          PointyStatusPill(
            label: productName == null
                ? l10n.searchMissStatusResolved
                : l10n.searchMissLinkedTo(productName),
            icon: Icons.inventory_2_outlined,
            color: colors.success,
          ),
        if (markDismissed && miss.status == SearchMissStatus.dismissed)
          PointyStatusPill(
            label: l10n.searchMissStatusDismissed,
            color: colors.mutedInk,
          ),
      ],
      actions: busy
          ? const [
              Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 20,
                  child: PointySpinner(strokeWidth: 2.5),
                ),
              ),
            ]
          : [
              if (miss.status == SearchMissStatus.open) ...[
                // Outlined, not filled: it sits on every row, and a column of
                // solid buttons would outshout the words it is about.
                Tooltip(
                  message: l10n.searchMissResolveTooltip,
                  child: OutlinedButton.icon(
                    onPressed: onResolve,
                    icon: const Icon(Icons.link),
                    label: Text(l10n.searchMissResolveButton),
                  ),
                ),
                TextButton(
                  onPressed: onDismiss,
                  child: Text(l10n.searchMissDismissButton),
                ),
              ] else
                TextButton.icon(
                  onPressed: onReopen,
                  icon: const Icon(Icons.undo),
                  label: Text(l10n.searchMissReopenButton),
                ),
            ],
    );
  }

  Color _statusColor(PointySemanticColors colors) {
    return switch (miss.status) {
      SearchMissStatus.open => colors.warning,
      SearchMissStatus.resolved => colors.success,
      SearchMissStatus.dismissed => colors.mutedInk,
    };
  }
}

/// How often, when last, and where the word was searched.
String searchMissSubtitle(
  SearchMiss miss,
  AppLocalizations l10n, {
  DateTime? now,
}) {
  final seen = miss.lastSeenAt;
  return [
    l10n.searchMissCount(miss.count),
    if (seen != null) searchMissLastSeen(seen, l10n, now: now),
    ?searchMissSurfaceLabel(miss.surface, l10n),
  ].join(' · ');
}

/// When the word was last searched, the way an owner would say it.
String searchMissLastSeen(DateTime at, AppLocalizations l10n, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final local = at.toLocal();
  if (DateUtils.isSameDay(local, today)) {
    return l10n.searchMissLastSeenToday(formatTime(local));
  }
  if (DateUtils.isSameDay(local, today.subtract(const Duration(days: 1)))) {
    return l10n.searchMissLastSeenYesterday(formatTime(local));
  }
  return l10n.searchMissLastSeenOn(formatDate(local));
}

/// Where the word was searched — nothing for a place the owner would not
/// recognise.
String? searchMissSurfaceLabel(
  SearchMissSurface surface,
  AppLocalizations l10n,
) {
  return switch (surface) {
    SearchMissSurface.pos => l10n.searchMissSurfacePos,
    SearchMissSurface.catalog => l10n.searchMissSurfaceCatalog,
    SearchMissSurface.purchasing => l10n.searchMissSurfacePurchasing,
    SearchMissSurface.other => null,
  };
}
