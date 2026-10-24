import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';

/// Rows in one rounded, softly lifted card with hairlines between them: the
/// grouped list premium settings and pay screens are built from.
class Grouped extends StatelessWidget {
  const Grouped({super.key, required this.children, this.title});

  final List<Widget> children;

  /// A small heading above the group.
  final String? title;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    // A Material surface, not a coloured box: the rows' ink ripples paint on
    // the nearest Material and would be hidden under a plain background.
    final group = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
      ),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CardsRadii.card),
          side: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
            width: 0.8,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const Divider(indent: CardsSpace.lg, endIndent: CardsSpace.lg),
              children[i],
            ],
          ],
        ),
      ),
    );
    if (title == null) {
      return group;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: CardsSpace.xs,
            bottom: CardsSpace.sm,
          ),
          child: Text(
            title!,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        group,
      ],
    );
  }
}

/// A sliding capsule control: the chosen segment's thumb glides under it.
class SegmentedPill<T> extends StatelessWidget {
  const SegmentedPill({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = segments.indexWhere((segment) => segment.$1 == selected);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(CardsRadii.pill),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / segments.length;
          final rtl = Directionality.of(context) == TextDirection.rtl;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: CardsMotion.standard,
                curve: CardsMotion.curve,
                top: 0,
                bottom: 0,
                width: width,
                left: rtl ? null : width * index,
                right: rtl ? width * index : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(CardsRadii.pill),
                    boxShadow: CardsShadows.raised,
                  ),
                ),
              ),
              Row(
                children: [
                  for (final (value, label) in segments)
                    Expanded(
                      child: Semantics(
                        selected: value == selected,
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(value),
                          child: Center(
                            child: Text(
                              label,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: value == selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: value == selected
                                    ? theme.colorScheme.onSurface
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
