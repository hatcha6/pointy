import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyCategoryStripItem<T extends Object> {
  const PointyCategoryStripItem({
    required this.value,
    required this.label,
    this.featured = false,
    this.icon,
  });

  final T value;
  final String label;

  /// Drawn in the accent colour so the eye finds it first — the company's own
  /// cards and services, which a shop cannot unpin.
  final bool featured;

  /// Shown before the label, for a [featured] chip.
  final IconData? icon;
}

class PointyCategoryStrip<T extends Object> extends StatelessWidget {
  const PointyCategoryStrip({
    super.key,
    required this.allLabel,
    required this.items,
    required this.selectedValues,
    required this.onSelectAll,
    required this.onSelected,
  });

  final String allLabel;
  final List<PointyCategoryStripItem<T>> items;
  final Set<T> selectedValues;
  final VoidCallback onSelectAll;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => SizedBox(width: spacing.sm),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _StripChip(
              label: allLabel,
              selected: selectedValues.isEmpty,
              onSelected: onSelectAll,
            );
          }

          final item = items[index - 1];
          return _StripChip(
            label: item.label,
            selected: selectedValues.contains(item.value),
            onSelected: () => onSelected(item.value),
            featured: item.featured,
            icon: item.icon,
          );
        },
      ),
    );
  }
}

class _StripChip extends StatelessWidget {
  const _StripChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    this.featured = false,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final bool featured;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    if (featured) {
      return _buildFeatured(context, colors);
    }

    return ChoiceChip(
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      side: BorderSide(color: selected ? colors.primaryStrong : colors.line),
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: selected ? colors.primaryDark : colors.ink,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  Widget _buildFeatured(BuildContext context, PointySemanticColors colors) {
    // Amber in both themes (see PointyTheme: dark ink reads on it), filled
    // when picked and tinted when not, so it stands apart from every
    // teal-outlined shop category either way.
    final onAmber = Theme.of(context).colorScheme.onSecondary;
    final iconData = icon;
    return ChoiceChip(
      avatar: iconData == null
          ? null
          : Icon(
              iconData,
              size: 18,
              color: selected ? onAmber : colors.accentAmber,
            ),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      backgroundColor: colors.amberContainer,
      selectedColor: colors.accentAmber,
      side: BorderSide(color: colors.accentAmber, width: 1.5),
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: selected ? onAmber : colors.ink,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
