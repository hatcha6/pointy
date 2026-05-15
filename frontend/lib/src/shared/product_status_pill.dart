import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

class ProductStatusPill extends StatelessWidget {
  const ProductStatusPill({
    super.key,
    required this.isActive,
    this.compact = false,
  });

  final bool isActive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isActive
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 2)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          isActive ? l10n.activeStatus : l10n.inactiveStatus,
          style: compact ? Theme.of(context).textTheme.labelSmall : null,
        ),
      ),
    );
  }
}
