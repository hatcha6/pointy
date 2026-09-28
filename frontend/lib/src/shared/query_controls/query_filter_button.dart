import 'package:flutter/material.dart';

import '../design/design.dart';

class QueryFilterButton extends StatelessWidget {
  const QueryFilterButton({
    super.key,
    required this.label,
    required this.activeCount,
    required this.onPressed,
    this.tooltip,
    this.showLabel = true,
  });

  final String label;
  final int activeCount;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final foreground = onPressed == null ? colors.mutedInk : colors.primaryDark;
    final button = Semantics(
      button: true,
      label: label,
      hint: tooltip,
      child: Material(
        color: onPressed == null
            ? colors.surfaceSunken
            : colors.primaryContainer,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 56,
              minHeight: 56,
              maxHeight: 56,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: showLabel ? 14 : 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune, color: foreground),
                  if (showLabel) ...[
                    const SizedBox(width: 8),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                  SizedBox(width: showLabel ? 8 : 6),
                  Visibility(
                    visible: activeCount > 0,
                    maintainAnimation: true,
                    maintainSize: true,
                    maintainState: true,
                    child: _ActiveCountBadge(count: activeCount),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (tooltip == null) {
      return button;
    }

    return Tooltip(message: tooltip!, child: button);
  }
}

class _ActiveCountBadge extends StatelessWidget {
  const _ActiveCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.pointyColors.primary,
        borderRadius: const BorderRadius.all(Radius.circular(PointyRadii.pill)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            // onPrimary, not the surface colour: the teal stays put in dark
            // mode while the surface goes dark, and dark-on-teal barely reads.
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
