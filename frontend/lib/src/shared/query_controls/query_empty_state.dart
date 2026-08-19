import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../components/components.dart';

/// Empty state for a list driven by a `QueryControlBar`.
///
/// A bare "no records" line leaves the user guessing why the list went blank
/// when the cause is their own search term or one of the filters hidden behind
/// the funnel icon. When either is active this says so and offers one tap to
/// clear both; otherwise it falls back to [emptyTitle] (with [emptyAction],
/// e.g. "create one").
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
        action: emptyAction,
      );
    }

    return PointyEmptyState(
      icon: Icons.search_off,
      title: term.isEmpty
          ? l10n.queryNoFilteredResultsTitle
          : l10n.queryNoSearchResultsTitle(term),
      message: l10n.queryNoResultsMessage,
      action: FilledButton.tonalIcon(
        onPressed: onClear,
        icon: const Icon(Icons.filter_alt_off_outlined),
        label: Text(l10n.queryClearSearchAndFiltersButton),
      ),
    );
  }
}
