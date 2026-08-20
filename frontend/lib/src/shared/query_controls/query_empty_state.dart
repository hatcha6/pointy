import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../components/components.dart';

/// Empty state for a list driven by a `QueryControlBar`.
///
/// A bare "no records" line leaves the user guessing why the list went blank
/// when the cause is their own search term or one of the filters hidden behind
/// the funnel icon. When either is active this says so and offers one tap to
/// clear it, wording the escape after whichever is actually narrowing the
/// list; otherwise it falls back to [emptyTitle] (with [emptyAction], e.g.
/// "create one").
///
/// The catalog has its own `CatalogEmptyState`, which knows about pinned
/// categories and the app-set stock filter; this is the plain version for every
/// other query-driven list.
class QueryEmptyState extends StatelessWidget {
  const QueryEmptyState({
    super.key,
    required this.icon,
    required this.search,
    required this.hasFilters,
    required this.emptyTitle,
    required this.onClear,
    this.emptyMessage,
    this.emptyAction,
  });

  /// Icon for the genuinely-empty case. The filtered case always shows a
  /// "search off" icon, so the two states are told apart at a glance.
  final IconData icon;

  final String search;

  /// Whether a filter the user set is narrowing the list. Sort order must be
  /// excluded: reordering a list can never empty it, so counting it would
  /// blame the filters for a shop that simply has no records yet.
  final bool hasFilters;

  final String emptyTitle;

  /// Optional supporting line for the genuinely-empty case only. The filtered
  /// case words its own message after whatever is narrowing the list, so a
  /// "records will show up here" line would contradict it.
  final String? emptyMessage;

  /// Clears the search term and every user-set filter.
  final VoidCallback onClear;

  /// Shown only when the list is genuinely empty — never alongside the "clear
  /// filters" escape, where inviting the user to create a record that already
  /// exists behind the filter would be the wrong advice.
  final Widget? emptyAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final term = search.trim();

    if (term.isEmpty && !hasFilters) {
      return PointyEmptyState(
        icon: icon,
        title: emptyTitle,
        message: emptyMessage,
        action: emptyAction,
      );
    }

    // Name only what is actually narrowing the list. Three cases, not two:
    // the funnel alone, the search term alone, or both. Collapsing the first
    // into "both" tells someone who typed nothing to check their spelling and
    // offers to clear a search box that, on the payments hub and the contact
    // pickers, does not exist at all.
    final hasSearch = term.isNotEmpty;

    return PointyEmptyState(
      icon: Icons.search_off,
      title: hasSearch
          ? l10n.queryNoSearchResultsTitle(term)
          : l10n.queryNoFilteredResultsTitle,
      message: switch ((hasSearch, hasFilters)) {
        (true, true) => l10n.queryNoResultsMessage,
        (true, false) => l10n.queryNoSearchResultsMessage,
        (false, _) => l10n.queryNoFiltersResultsMessage,
      },
      action: FilledButton.tonalIcon(
        onPressed: onClear,
        icon: Icon(
          hasFilters ? Icons.filter_alt_off_outlined : Icons.search_off,
        ),
        label: Text(switch ((hasSearch, hasFilters)) {
          (true, true) => l10n.queryClearSearchAndFiltersButton,
          (true, false) => l10n.queryClearSearchButton,
          (false, _) => l10n.queryClearFiltersButton,
        }),
      ),
    );
  }
}
