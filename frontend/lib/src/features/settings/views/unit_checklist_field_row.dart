import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/unit_attribute.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'unit_checklist_types.dart';

enum _FieldAction { edit, moveUp, moveDown, delete }

/// One field of a kind's checklist, as the editor lists it: drag handle, what
/// it asks and how, and a menu for the rest.
///
/// The menu repeats the move as two items so the order can be changed without
/// a drag — on a touch till where a long list scrolls under the finger, and
/// from the keyboard.
class UnitChecklistFieldRow extends StatelessWidget {
  const UnitChecklistFieldRow({
    super.key,
    required this.index,
    required this.field,
    required this.isLast,
    required this.canReorder,
    required this.onEdit,
    required this.onDelete,
    required this.onMove,
  });

  final int index;
  final UnitAttributeDefinition field;
  final bool isLast;
  final bool canReorder;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// Moves this row to the slot given.
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: spacing.xs),
      child: Material(
        color: colors.surface,
        shape: PointyComponentStyles.outlinedShape(
          PointyRadii.card,
          colors.line,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.xs,
              spacing.sm,
              spacing.xs,
              spacing.sm,
            ),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  enabled: canReorder,
                  child: Tooltip(
                    message: l10n.unitChecklistReorderTooltip,
                    child: MouseRegion(
                      cursor: canReorder
                          ? SystemMouseCursors.grab
                          : SystemMouseCursors.basic,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.drag_indicator,
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                  ),
                ),
                Icon(
                  unitChecklistTypeIcon(field.dataType),
                  size: 20,
                  color: colors.primaryStrong,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              field.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (field.isRequired) ...[
                            SizedBox(width: spacing.xs),
                            PointyStatusPill(
                              label: l10n.unitChecklistRequiredBadge,
                              color: colors.warning,
                              compact: true,
                            ),
                          ],
                        ],
                      ),
                      Text(
                        _summary(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                _Flags(field: field),
                PopupMenuButton<_FieldAction>(
                  key: ValueKey('unit-checklist-field-menu-${field.id}'),
                  tooltip: l10n.unitChecklistFieldActionsTooltip,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) => switch (action) {
                    _FieldAction.edit => onEdit(),
                    _FieldAction.moveUp => onMove(index - 1),
                    _FieldAction.moveDown => onMove(index + 1),
                    _FieldAction.delete => onDelete(),
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _FieldAction.edit,
                      child: _MenuLabel(Icons.edit_outlined, l10n.editButton),
                    ),
                    PopupMenuItem(
                      value: _FieldAction.moveUp,
                      enabled: canReorder && index > 0,
                      child: _MenuLabel(
                        Icons.arrow_upward,
                        l10n.unitChecklistMoveUp,
                      ),
                    ),
                    PopupMenuItem(
                      value: _FieldAction.moveDown,
                      enabled: canReorder && !isLast,
                      child: _MenuLabel(
                        Icons.arrow_downward,
                        l10n.unitChecklistMoveDown,
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _FieldAction.delete,
                      child: _MenuLabel(
                        Icons.delete_outline,
                        l10n.deleteButton,
                        color: colors.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// «اختيار من قائمة · ممتاز، جيد، مقبول +2», «رقم · GB».
  String _summary(AppLocalizations l10n) {
    final parts = [unitChecklistTypeLabel(l10n, field.dataType)];
    if (field.dataType == UnitAttributeType.choice &&
        field.choices.isNotEmpty) {
      const shown = 3;
      final labels = field.choices.take(shown).map((choice) => choice.label);
      final more = field.choices.length - shown;
      parts.add(
        [
          labels.join('، '),
          if (more > 0) l10n.unitChecklistMoreChoices(more),
        ].join(' '),
      );
    } else if (field.isNumeric && field.displaySuffix.isNotEmpty) {
      parts.add(field.displaySuffix);
    }
    return parts.join(' · ');
  }
}

/// Where the answer shows besides the unit's own page, as a small mark. Only
/// the till's picker reads one today; label and receipt printing do not.
class _Flags extends StatelessWidget {
  const _Flags({required this.field});

  final UnitAttributeDefinition field;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final flags = [
      if (field.showInPicker)
        (Icons.point_of_sale_outlined, l10n.unitChecklistPickerTitle),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (icon, label) in flags)
          Tooltip(
            message: label,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Icon(icon, size: 16, color: colors.mutedInk),
            ),
          ),
      ],
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
