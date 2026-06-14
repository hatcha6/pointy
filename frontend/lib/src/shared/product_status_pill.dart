import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

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
      background = colorScheme.primaryContainer;
      foreground = colorScheme.onPrimaryContainer;
      label = l10n.activeStatus;
    } else {
      background = colorScheme.surfaceContainerHighest;
      foreground = colorScheme.onSurfaceVariant;
      label = l10n.inactiveStatus;
    }

    final textTheme = Theme.of(context).textTheme;
    final baseStyle = compact ? textTheme.labelSmall : textTheme.bodyMedium;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
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
