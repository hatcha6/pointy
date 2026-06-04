import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/analytics_event.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/query_controls/query_control_bar.dart';
import '../../../shared/responsive/responsive.dart';
import 'activity_log_filter_sheet.dart';

class ActivityLogQueryControls extends StatelessWidget {
  const ActivityLogQueryControls({
    super.key,
    required this.query,
    required this.users,
    required this.onSearchChanged,
    required this.onQueryChanged,
    this.enabled = true,
  });

  final AnalyticsEventQuery query;
  final List<PosUser> users;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<AnalyticsEventQuery> onQueryChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: l10n.activityLogSearchHint,
      clearSearchTooltip: l10n.clearSearchTooltip,
      filterLabel: l10n.filtersButtonLabel,
      openFiltersTooltip: l10n.openFiltersTooltip,
      activeFilterCount: _activeFilterCount,
      onSearchChanged: onSearchChanged,
      onOpenFilters: () => _showFilters(context),
      enabled: enabled,
    );
  }

  int get _activeFilterCount {
    return query.activeFilterCount +
        (query.ordering == AnalyticsEventOrdering.newest ? 0 : 1);
  }

  Future<void> _showFilters(BuildContext context) async {
    final updatedQuery =
        await showAdaptiveModalBottomSheet<AnalyticsEventQuery>(
          context: context,
          size: AdaptiveModalSize.expanded,
          maxHeightFactor: 0.94,
          builder: (context) =>
              ActivityLogFilterSheet(query: query, users: users),
        );

    if (updatedQuery != null) {
      onQueryChanged(updatedQuery);
    }
  }
}
