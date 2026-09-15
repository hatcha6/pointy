import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/query_controls/query_control_bar.dart';
import '../../../shared/responsive/responsive.dart';
import '../models/learning_query.dart';
import 'learning_filter_sheet.dart';

/// Search box + filter button for the learning catalogue.
class LearningQueryControls extends StatelessWidget {
  const LearningQueryControls({
    super.key,
    required this.query,
    required this.onSearchChanged,
    required this.onQueryChanged,
  });

  final LearningQuery query;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<LearningQuery> onQueryChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: l10n.learningSearchHint,
      clearSearchTooltip: l10n.clearSearchTooltip,
      filterLabel: l10n.filtersButtonLabel,
      openFiltersTooltip: l10n.openFiltersTooltip,
      // The sort counts here but not in `activeFilterCount`: the badge tells
      // the reader "you have changed something", while the empty state must
      // only blame what can actually empty a list.
      activeFilterCount:
          query.activeFilterCount +
          (query.sort == LearningSort.recommended ? 0 : 1),
      onSearchChanged: onSearchChanged,
      onOpenFilters: () => _showFilters(context),
    );
  }

  Future<void> _showFilters(BuildContext context) async {
    final updated = await showAdaptiveModalBottomSheet<LearningQuery>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) => LearningFilterSheet(query: query),
    );
    if (updated != null) {
      onQueryChanged(updated);
    }
  }
}
