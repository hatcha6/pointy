import 'dart:async';

import 'package:flutter/material.dart';

import '../responsive/responsive.dart';
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
        final spacing = AdaptiveSpacing.of(context);
        final hasScanner = onOpenCameraScanner != null;
        final useCompactActions =
            constraints.maxWidth < (hasScanner ? 390 : 330);
        final searchField = DebouncedSearchField(
          value: searchValue,
          hintText: searchHint,
          clearTooltip: clearSearchTooltip,
          onChanged: onSearchChanged,
          onSubmitted: onSearchSubmitted,
          enabled: enabled,
          autofocus: autofocus,
          fieldKey: searchFieldKey,
        );
        final actions = _QueryActions(
          hasScanner: hasScanner,
          onOpenCameraScanner: onOpenCameraScanner,
          openCameraScannerTooltip: openCameraScannerTooltip,
          filterLabel: filterLabel,
          openFiltersTooltip: openFiltersTooltip,
          activeFilterCount: activeFilterCount,
          onOpenFilters: onOpenFilters,
          enabled: enabled,
          showFilterLabel: !useCompactActions,
        );

        if (constraints.maxWidth < 360) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchField,
              SizedBox(height: spacing.sm),
              Align(alignment: AlignmentDirectional.centerEnd, child: actions),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: searchField),
            SizedBox(width: spacing.sm),
            actions,
          ],
        );
      },
    );
  }
}

class _QueryActions extends StatelessWidget {
  const _QueryActions({
    required this.hasScanner,
    required this.onOpenCameraScanner,
    required this.openCameraScannerTooltip,
    required this.filterLabel,
    required this.openFiltersTooltip,
    required this.activeFilterCount,
    required this.onOpenFilters,
    required this.enabled,
    required this.showFilterLabel,
  });

  final bool hasScanner;
  final VoidCallback? onOpenCameraScanner;
  final String? openCameraScannerTooltip;
  final String filterLabel;
  final String openFiltersTooltip;
  final int activeFilterCount;
  final VoidCallback onOpenFilters;
  final bool enabled;
  final bool showFilterLabel;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasScanner) ...[
          SizedBox.square(
            dimension: 56,
            child: IconButton.filledTonal(
              tooltip: openCameraScannerTooltip,
              onPressed: enabled ? onOpenCameraScanner : null,
              icon: const Icon(Icons.photo_camera_outlined),
            ),
          ),
          SizedBox(width: spacing.sm),
        ],
        QueryFilterButton(
          label: filterLabel,
          tooltip: openFiltersTooltip,
          activeCount: activeFilterCount,
          onPressed: enabled ? onOpenFilters : null,
          showLabel: showFilterLabel,
        ),
      ],
    );
  }
}
