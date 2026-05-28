import 'package:flutter/material.dart';

class PointyFilterSummaryBar extends StatelessWidget {
  const PointyFilterSummaryBar({super.key, required this.items});

  final List<PointyFilterSummaryItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final item in items)
          InputChip(
            avatar: item.icon == null ? null : Icon(item.icon, size: 18),
            label: Text(item.label),
            selected: item.selected,
            onDeleted: item.onClear,
          ),
      ],
    );
  }
}

class PointyFilterSummaryItem {
  const PointyFilterSummaryItem({
    required this.label,
    this.icon,
    this.selected = false,
    this.onClear,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onClear;
}
