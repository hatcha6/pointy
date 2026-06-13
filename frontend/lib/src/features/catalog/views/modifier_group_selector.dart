import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/modifier_group.dart';

/// Compact multi-select for assigning reusable modifier groups to a product.
/// Shared by the create form and the parent-edit sheet.
class ModifierGroupSelector extends StatelessWidget {
  const ModifierGroupSelector({
    super.key,
    required this.available,
    required this.selectedIds,
    required this.isLoading,
    required this.hasError,
    required this.onReload,
    required this.onToggle,
  });

  final List<ModifierGroup> available;
  final Set<int> selectedIds;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onReload;
  final ValueChanged<ModifierGroup> onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.productModifierGroupsLabel,
              style: theme.textTheme.labelLarge,
            ),
            const Spacer(),
            if (isLoading)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (hasError)
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.modifierGroupsLoadError,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
              TextButton(onPressed: onReload, child: Text(l10n.retryButton)),
            ],
          )
        else if (available.isEmpty && !isLoading)
          Text(
            l10n.modifierGroupsEmptyMessage,
            style: theme.textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final group in available)
                FilterChip(
                  label: Text(group.name),
                  selected: selectedIds.contains(group.id),
                  onSelected: (_) => onToggle(group),
                ),
            ],
          ),
      ],
    );
  }
}
