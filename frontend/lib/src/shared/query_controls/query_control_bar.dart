import 'dart:async';

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
    this.onSearchSubmitted,
    this.openCameraScannerTooltip,
    this.onOpenCameraScanner,
    this.enabled = true,
    this.autofocus = false,
    this.searchFieldKey,
  });

  final String searchValue;
  final String searchHint;
  final String clearSearchTooltip;
  final String filterLabel;
  final String openFiltersTooltip;
  final int activeFilterCount;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onOpenFilters;
  final FutureOr<bool> Function(String value)? onSearchSubmitted;
  final String? openCameraScannerTooltip;
  final VoidCallback? onOpenCameraScanner;
  final bool enabled;
  final bool autofocus;
  final Key? searchFieldKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasScanner = onOpenCameraScanner != null;
        final useCompactActions =
            constraints.maxWidth < (hasScanner ? 390 : 330);

        return Row(
          children: [
            Expanded(
              child: DebouncedSearchField(
                value: searchValue,
                hintText: searchHint,
                clearTooltip: clearSearchTooltip,
                onChanged: onSearchChanged,
                onSubmitted: onSearchSubmitted,
                enabled: enabled,
                autofocus: autofocus,
                fieldKey: searchFieldKey,
              ),
            ),
            const SizedBox(width: 8),
            if (hasScanner) ...[
              SizedBox.square(
                dimension: 56,
                child: IconButton.filledTonal(
                  tooltip: openCameraScannerTooltip,
                  onPressed: enabled ? onOpenCameraScanner : null,
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
              ),
              const SizedBox(width: 8),
            ],
            QueryFilterButton(
              label: filterLabel,
              tooltip: openFiltersTooltip,
              activeCount: activeFilterCount,
              onPressed: enabled ? onOpenFilters : null,
              showLabel: !useCompactActions,
            ),
          ],
        );
      },
    );
  }
}
