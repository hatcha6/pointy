import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// One step in a [PointyStepRail].
class PointyStepRailItem {
  const PointyStepRailItem({required this.label, this.icon});

  final String label;
  final IconData? icon;
}

/// The numbered rail across the top of a multi-step flow.
///
/// Answers the two questions someone has when a screen asks them for one thing
/// at a time: how much of this is left, and can I still get back. Completed
/// steps carry a tick, the current one is filled, and the rest are quiet — so
/// the shape of the whole flow is visible from the first screen.
///
/// Labels collapse to numbers alone on a narrow window rather than wrapping into
/// an unreadable stack.
class PointyStepRail extends StatelessWidget {
  const PointyStepRail({
    super.key,
    required this.steps,
    required this.currentIndex,
    this.showLabels = true,
  });

  final List<PointyStepRailItem> steps;
  final int currentIndex;
  final bool showLabels;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below this the labels stop being labels and start being wrapped
        // fragments; numbers alone read better.
        final withLabels = showLabels && constraints.maxWidth > 520;
        return Row(
          children: [
            for (var index = 0; index < steps.length; index++) ...[
              if (index > 0)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: spacing.xs),
                    child: Divider(
                      thickness: 2,
                      height: 2,
                      color: index <= currentIndex
                          ? colors.primaryStrong
                          : colors.line,
                    ),
                  ),
                ),
              _StepDot(
                index: index,
                current: currentIndex,
                item: steps[index],
                showLabel: withLabels,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.index,
    required this.current,
    required this.item,
    required this.showLabel,
  });

  final int index;
  final int current;
  final PointyStepRailItem item;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final done = index < current;
    final active = index == current;
    final background = done || active ? colors.primaryStrong : colors.subtleFill;
    final foreground = done || active
        ? theme.colorScheme.onPrimary
        : colors.mutedInk;

    return Semantics(
      label: item.label,
      selected: active,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: background,
            child: done
                ? Icon(Icons.check, size: 17, color: foreground)
                : Text(
                    '${index + 1}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          if (showLabel) ...[
            const SizedBox(width: 8),
            Text(
              item.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: active ? colors.primaryStrong : colors.mutedInk,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
