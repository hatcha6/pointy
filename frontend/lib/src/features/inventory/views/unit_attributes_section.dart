import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/unit_attribute.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// An article's condition record, read as a ledger of facts plus the
/// checklist of what came with it — labels from the definitions, values as a
/// person reads them («ممتاز +», not `a_plus`).
class UnitAttributesSection extends StatelessWidget {
  const UnitAttributesSection({super.key, required this.values, this.onEdit});

  final List<UnitAttributeValue> values;

  /// Null hides the edit button — the reader may not change it.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final facts = [
      for (final value in values)
        if (!value.isBoolean) value,
    ];
    final checklist = [
      for (final value in values)
        if (value.isBoolean) value,
    ];

    return PointyDetailSection(
      title: l10n.stockUnitAttributesSection,
      icon: Icons.fact_check_outlined,
      trailing: onEdit == null
          ? null
          : IconButton(
              key: const ValueKey('unit-attributes-edit'),
              tooltip: l10n.unitAttributesEditAction,
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
      child: values.isEmpty
          ? Text(
              l10n.unitAttributesEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.mutedInk,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (facts.isNotEmpty)
                  PointySummaryList(
                    rows: [
                      for (final fact in facts)
                        PointySummaryRow(
                          label: fact.label,
                          value: fact.display,
                        ),
                    ],
                  ),
                if (checklist.isNotEmpty) ...[
                  if (facts.isNotEmpty) const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final item in checklist)
                        _ChecklistPill(
                          label: item.label,
                          included: item.value == true,
                        ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

/// Status by icon *and* colour, never colour alone.
class _ChecklistPill extends StatelessWidget {
  const _ChecklistPill({required this.label, required this.included});

  final String label;
  final bool included;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final foreground = included ? colors.success : colors.mutedInk;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: included
            ? colors.success.withValues(alpha: 0.10)
            : colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              included ? Icons.check_circle : Icons.remove_circle_outline,
              size: 15,
              color: foreground,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground,
                decoration: included ? null : TextDecoration.lineThrough,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
