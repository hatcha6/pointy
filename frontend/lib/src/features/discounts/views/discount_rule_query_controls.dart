import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/discount_rule.dart';
import '../../../shared/query_controls/query_control_bar.dart';
import '../../../shared/responsive/responsive.dart';
import 'discount_rule_filter_sheet.dart';

class DiscountRuleQueryControls extends StatelessWidget {
  const DiscountRuleQueryControls({
    super.key,
    required this.query,
    required this.onSearchChanged,
    required this.onQueryChanged,
    this.enabled = true,
  });

  final DiscountRuleQuery query;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<DiscountRuleQuery> onQueryChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: l10n.discountSearchHint,
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
        (query.ordering == DiscountRuleOrdering.priority ? 0 : 1);
  }

  Future<void> _showFilters(BuildContext context) async {
    final updatedQuery = await showAdaptiveModalBottomSheet<DiscountRuleQuery>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) => DiscountRuleFilterSheet(query: query),
    );

    if (updatedQuery != null) {
      onQueryChanged(updatedQuery);
    }
  }
}
