import 'package:flutter/material.dart';

import 'debounced_search_field.dart';
import 'query_filter_button.dart';

class QueryControlBar extends StatelessWidget {
  const QueryControlBar({
    super.key,
    required this.searchValue,
    required this.searchHint,
    required this.clearSearchTooltip,
    required this.filterLabel,
    required this.openFiltersTooltip,
    required this.activeFilterCount,
    required this.onSearchChanged,
    required this.onOpenFilters,
  });

  final String searchValue;
  final String searchHint;
  final String clearSearchTooltip;
  final String filterLabel;
  final String openFiltersTooltip;
  final int activeFilterCount;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DebouncedSearchField(
            value: searchValue,
            hintText: searchHint,
            clearTooltip: clearSearchTooltip,
            onChanged: onSearchChanged,
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: openFiltersTooltip,
          child: QueryFilterButton(
            label: filterLabel,
            activeCount: activeFilterCount,
            onPressed: onOpenFilters,
          ),
        ),
      ],
    );
  }
}
