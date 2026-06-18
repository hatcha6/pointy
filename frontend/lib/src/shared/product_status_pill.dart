import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'design/design.dart';

class ProductStatusPill extends StatelessWidget {
  const ProductStatusPill({
    super.key,
    required this.isActive,
    this.isArchived = false,
    this.compact = false,
  });

  final bool isActive;
  final bool isArchived;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.pointyColors;

    // Archived takes precedence over active/inactive: a retired product is no
    // longer sellable regardless of its `is_active` flag.
    final Color background;
    final Color foreground;
    final String label;
    if (isArchived) {
      background = colorScheme.tertiaryContainer;
      foreground = colorScheme.onTertiaryContainer;
      label = l10n.archivedStatus;
    } else if (isActive) {
      background = PointyColors.primaryContainer;
      foreground = colors.primaryDark;
      label = l10n.activeStatus;
    } else {
      background = colors.surfaceSunken;
      foreground = colors.mutedInk;
      label = l10n.inactiveStatus;
    }

    final textTheme = Theme.of(context).textTheme;
    final baseStyle = compact ? textTheme.labelSmall : textTheme.bodyMedium;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
      ),
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 2)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label, style: baseStyle?.copyWith(color: foreground)),
      ),
    );
  }
}
