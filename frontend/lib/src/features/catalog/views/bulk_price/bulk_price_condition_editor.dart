import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_price_rule.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../view_models/bulk_price_editor_view_model.dart';
import 'bulk_price_labels.dart';

/// Opens a picker for a category / supplier condition and returns the new
/// selection, or null when the picker was dismissed.
typedef BulkPriceRefPicker =
    Future<List<BulkPriceRef>?> Function(
      BuildContext context,
      BulkPriceField field,
      List<BulkPriceRef> current,
    );

/// Edits one condition group: its all/any switch, its conditions, and (at
/// the top level) nested groups — which is how "(A or B) and C" is built.
class BulkPriceGroupEditor extends StatelessWidget {
  const BulkPriceGroupEditor({
    super.key,
    required this.group,
    required this.viewModel,
    required this.pickRefs,
    required this.availableFields,
    this.depth = 0,
    this.allowNesting = true,
    this.onRemoveGroup,
  });

  final BulkPriceGroup group;
  final BulkPriceEditorViewModel viewModel;
  final BulkPriceRefPicker pickRefs;
  final List<BulkPriceField> availableFields;
  final int depth;

  /// False for a step's own condition: it is a filter on top of the filter,
  /// and reads best as one flat list.
  final bool allowNesting;

  /// Shown on a nested group's header.
  final VoidCallback? onRemoveGroup;

  /// One level of nesting in the editor. The server allows three, but a
  /// group inside a group inside a group is harder to read than to rewrite.
  bool get _canNest => depth == 0 && allowNesting;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final nested = depth > 0;
    final join = group.match == BulkPriceMatch.all
        ? l10n.bulkPriceJoinAnd
        : l10n.bulkPriceJoinOr;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (group.children.length > 1 || nested)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                if (nested)
                  Text(
                    l10n.bulkPriceNestedGroupTitle,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  l10n.bulkPriceGroupMatchLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
                SegmentedButton<BulkPriceMatch>(
                  key: ValueKey('bulk_price_match_${group.key}'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    ButtonSegment(
                      value: BulkPriceMatch.all,
                      label: Text(l10n.bulkPriceMatchAll),
                    ),
                    ButtonSegment(
                      value: BulkPriceMatch.any,
                      label: Text(l10n.bulkPriceMatchAny),
                    ),
                  ],
                  selected: {group.match},
                  onSelectionChanged: (selection) =>
                      viewModel.setGroupMatch(group.key, selection.first),
                ),
                if (onRemoveGroup != null)
                  IconButton(
                    tooltip: l10n.bulkPriceRemoveGroup,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemoveGroup,
                  ),
              ],
            ),
          ),
        for (var index = 0; index < group.children.length; index++) ...[
          if (index > 0) _JoinLabel(label: join),
          switch (group.children[index]) {
            final BulkPriceCondition condition => BulkPriceConditionRow(
              key: ValueKey(condition.key),
              condition: condition,
              viewModel: viewModel,
              pickRefs: pickRefs,
              availableFields: availableFields,
            ),
            final BulkPriceGroup child => BulkPriceGroupEditor(
              key: ValueKey(child.key),
              group: child,
              viewModel: viewModel,
              pickRefs: pickRefs,
              availableFields: availableFields,
              depth: depth + 1,
              onRemoveGroup: () => viewModel.removeNode(child.key),
            ),
          },
        ],
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              key: ValueKey('bulk_price_add_condition_${group.key}'),
              onPressed: () => viewModel.addCondition(group.key),
              icon: const Icon(Icons.add),
              label: Text(l10n.bulkPriceAddCondition),
            ),
            if (_canNest)
              TextButton.icon(
                key: ValueKey('bulk_price_add_group_${group.key}'),
                onPressed: () => viewModel.addGroup(group.key),
                icon: const Icon(Icons.account_tree_outlined),
                label: Text(l10n.bulkPriceAddGroup),
              ),
          ],
        ),
      ],
    );

    if (!nested) return body;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 4),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: BorderDirectional(
          start: BorderSide(color: colors.primary, width: 3),
        ),
      ),
      child: body,
    );
  }
}

class _JoinLabel extends StatelessWidget {
  const _JoinLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, top: 2, bottom: 2),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(PointyRadii.pill),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.primaryStrong,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

/// One condition: field, comparison, value. Wraps to two lines when narrow.
class BulkPriceConditionRow extends StatelessWidget {
  const BulkPriceConditionRow({
    super.key,
    required this.condition,
    required this.viewModel,
    required this.pickRefs,
    required this.availableFields,
  });

  final BulkPriceCondition condition;
  final BulkPriceEditorViewModel viewModel;
  final BulkPriceRefPicker pickRefs;
  final List<BulkPriceField> availableFields;

  void _update(BulkPriceCondition Function(BulkPriceCondition) change) =>
      viewModel.updateCondition(condition.key, change);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fields = [
      ...availableFields,
      if (!availableFields.contains(condition.field)) condition.field,
    ];

    final fieldMenu = DropdownButtonFormField<BulkPriceField>(
      key: ValueKey('bulk_price_field_${condition.key}'),
      initialValue: condition.field,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        for (final field in fields)
          DropdownMenuItem(
            value: field,
            enabled: field.isPickable,
            child: Row(
              children: [
                Icon(bulkPriceFieldIcon(field), size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.fieldLabel(field),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
      onChanged: (field) {
        if (field != null) _update((c) => c.copyWith(field: field));
      },
    );

    final operatorMenu = DropdownButtonFormField<BulkPriceOperator>(
      key: ValueKey('bulk_price_op_${condition.key}_${condition.field.name}'),
      initialValue: condition.operator,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        for (final operator in condition.field.supportedOperators)
          DropdownMenuItem(
            value: operator,
            child: Text(
              l10n.operatorLabel(operator),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (operator) {
        if (operator != null) _update((c) => c.copyWith(operator: operator));
      },
    );

    final value = _ValueEditor(
      condition: condition,
      onChanged: _update,
      onPick: () async {
        final picked = await pickRefs(context, condition.field, condition.refs);
        if (picked != null) _update((c) => c.copyWith(refs: picked));
      },
    );

    final remove = IconButton(
      key: ValueKey('bulk_price_remove_${condition.key}'),
      tooltip: l10n.bulkPriceRemoveCondition,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close),
      onPressed: () => viewModel.removeNode(condition.key),
    );

    final hasValue =
        condition.operator.needsValue &&
        condition.field.kind != BulkPriceFieldKind.flag;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 560) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 180, child: fieldMenu),
                const SizedBox(width: 8),
                SizedBox(width: 150, child: operatorMenu),
                const SizedBox(width: 8),
                Expanded(child: hasValue ? value : const SizedBox.shrink()),
                remove,
              ],
            );
          }
          // Narrow: the field gets a line of its own (its names are the
          // longest), the comparison and a short value share the next.
          final inlineValue =
              hasValue &&
              condition.operator != BulkPriceOperator.between &&
              (condition.field.kind == BulkPriceFieldKind.text ||
                  condition.field.kind == BulkPriceFieldKind.number);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: fieldMenu),
                  remove,
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 40),
                child: inlineValue
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: operatorMenu),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: value),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          operatorMenu,
                          if (hasValue) ...[const SizedBox(height: 6), value],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ValueEditor extends StatelessWidget {
  const _ValueEditor({
    required this.condition,
    required this.onChanged,
    required this.onPick,
  });

  final BulkPriceCondition condition;
  final void Function(BulkPriceCondition Function(BulkPriceCondition))
  onChanged;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final issues = condition.issues;
    switch (condition.field.kind) {
      case BulkPriceFieldKind.flag:
        return const SizedBox.shrink();
      case BulkPriceFieldKind.refs:
        return _RefsEditor(
          condition: condition,
          onChanged: onChanged,
          onPick: onPick,
        );
      case BulkPriceFieldKind.text:
        return BulkPriceTextField(
          fieldKey: 'bulk_price_value_${condition.key}_${condition.field.name}',
          initialValue: condition.value,
          issue: issues.value,
          onChanged: (text) => onChanged((c) => c.copyWith(value: text)),
        );
      case BulkPriceFieldKind.number:
        final suffix = switch (condition.field) {
          BulkPriceField.markup => '%',
          BulkPriceField.stock => null,
          _ => currencySymbol,
        };
        final first = BulkPriceTextField(
          fieldKey: 'bulk_price_value_${condition.key}_${condition.field.name}',
          initialValue: condition.value,
          issue: issues.value,
          numeric: true,
          signed: condition.field.allowsNegative,
          suffix: suffix,
          onChanged: (text) => onChanged((c) => c.copyWith(value: text)),
        );
        if (condition.operator != BulkPriceOperator.between) return first;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Text(l10n.bulkPriceBetweenAnd),
            ),
            Expanded(
              child: BulkPriceTextField(
                fieldKey:
                    'bulk_price_value_to_${condition.key}_${condition.field.name}',
                initialValue: condition.valueTo,
                issue: issues.valueTo,
                numeric: true,
                signed: condition.field.allowsNegative,
                suffix: suffix,
                onChanged: (text) =>
                    onChanged((c) => c.copyWith(valueTo: text)),
              ),
            ),
          ],
        );
    }
  }
}

class _RefsEditor extends StatelessWidget {
  const _RefsEditor({
    required this.condition,
    required this.onChanged,
    required this.onPick,
  });

  final BulkPriceCondition condition;
  final void Function(BulkPriceCondition Function(BulkPriceCondition))
  onChanged;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    if (condition.field == BulkPriceField.product) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: Chip(
          avatar: const Icon(Icons.checklist, size: 18),
          label: Text(l10n.bulkPriceSelectedProducts(condition.refs.length)),
        ),
      );
    }
    final missing = condition.refs.isEmpty;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final ref in condition.refs)
          InputChip(
            label: Text(ref.label),
            visualDensity: VisualDensity.compact,
            onDeleted: () => onChanged(
              (c) => c.copyWith(
                refs: [
                  for (final r in c.refs)
                    if (r.id != ref.id) r,
                ],
              ),
            ),
          ),
        ActionChip(
          key: ValueKey('bulk_price_pick_${condition.key}'),
          avatar: Icon(
            Icons.add,
            size: 18,
            color: missing ? colors.warning : null,
          ),
          side: missing ? BorderSide(color: colors.warning) : null,
          label: Text(
            condition.field == BulkPriceField.category
                ? l10n.bulkPricePickCategories
                : l10n.bulkPricePickSupplier,
          ),
          onPressed: onPick,
        ),
        if (condition.field == BulkPriceField.category &&
            condition.refs.isNotEmpty)
          Text(
            l10n.bulkPriceSubcategoriesHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    );
  }
}

/// A dense text field that marks a missing value quietly (amber outline and
/// a "required" hint) and a wrong one loudly (red, with the reason).
class BulkPriceTextField extends StatelessWidget {
  const BulkPriceTextField({
    super.key,
    required this.fieldKey,
    required this.initialValue,
    required this.issue,
    required this.onChanged,
    this.numeric = false,
    this.signed = false,
    this.suffix,
    this.hint,
  });

  final String fieldKey;
  final String initialValue;
  final BulkPriceIssue? issue;
  final ValueChanged<String> onChanged;
  final bool numeric;
  final bool signed;
  final String? suffix;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final missing = issue == BulkPriceIssue.required;
    final missingBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(PointyRadii.input),
      borderSide: BorderSide(color: colors.warning, width: 1.4),
    );
    return TextFormField(
      key: ValueKey(fieldKey),
      initialValue: initialValue,
      onChanged: onChanged,
      textDirection: numeric ? TextDirection.ltr : null,
      textAlign: numeric ? TextAlign.end : TextAlign.start,
      keyboardType: numeric
          ? TextInputType.numberWithOptions(decimal: true, signed: signed)
          : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩۰-۹.٫\-]'))]
          : null,
      decoration: InputDecoration(
        isDense: true,
        hintText: missing
            ? l10n.bulkPriceIssueRequired
            : (hint ?? l10n.bulkPriceValueHint),
        suffixText: suffix,
        errorText: issue == null || missing ? null : l10n.issueLabel(issue!),
        enabledBorder: missing ? missingBorder : null,
      ),
    );
  }
}
