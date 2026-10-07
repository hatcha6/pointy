import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/unit_attribute.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// The most options one field may offer; the server refuses more.
const unitChecklistMaxChoices = 30;

/// The options of a «اختيار من قائمة» field, one row each.
///
/// A row remembers the stored `value` of the choice it was loaded from, so a
/// rename keeps every unit that recorded it readable; a new row has none and
/// the server mints one. Enter on the last row adds the next, which is how a
/// list of colours gets typed at a counter.
class UnitChecklistChoicesEditor extends StatefulWidget {
  const UnitChecklistChoicesEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.error,
    this.enabled = true,
  });

  final List<UnitAttributeChoice> initial;
  final ValueChanged<List<UnitAttributeChoice>> onChanged;
  final String? error;
  final bool enabled;

  @override
  State<UnitChecklistChoicesEditor> createState() =>
      _UnitChecklistChoicesEditorState();
}

class _ChoiceRow {
  _ChoiceRow(this.value, String label)
    : controller = TextEditingController(text: label),
      focusNode = FocusNode();

  final String value;
  final TextEditingController controller;
  final FocusNode focusNode;

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

class _UnitChecklistChoicesEditorState
    extends State<UnitChecklistChoicesEditor> {
  late final List<_ChoiceRow> _rows = [
    for (final choice in widget.initial) _ChoiceRow(choice.value, choice.label),
    if (widget.initial.isEmpty) _ChoiceRow('', ''),
  ];

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _emit() {
    widget.onChanged([
      for (final row in _rows)
        UnitAttributeChoice(value: row.value, label: row.controller.text),
    ]);
  }

  void _add() {
    if (_rows.length >= unitChecklistMaxChoices) return;
    final row = _ChoiceRow('', '');
    setState(() => _rows.add(row));
    _emit();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.focusNode.requestFocus();
    });
  }

  void _remove(int index) {
    final row = _rows.removeAt(index);
    setState(() {});
    _emit();
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final error = widget.error;
    final canAdd = widget.enabled && _rows.length < unitChecklistMaxChoices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.unitChecklistChoicesLabel, style: theme.textTheme.titleSmall),
        SizedBox(height: spacing.xs),
        for (var index = 0; index < _rows.length; index++)
          Padding(
            key: ObjectKey(_rows[index]),
            padding: EdgeInsets.only(bottom: spacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('unit-checklist-choice-$index'),
                    controller: _rows[index].controller,
                    focusNode: _rows[index].focusNode,
                    enabled: widget.enabled,
                    maxLength: 60,
                    textInputAction: index == _rows.length - 1
                        ? TextInputAction.done
                        : TextInputAction.next,
                    onChanged: (_) => _emit(),
                    onSubmitted: (_) {
                      if (index == _rows.length - 1 &&
                          _rows[index].controller.text.trim().isNotEmpty) {
                        _add();
                      }
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      hintText: l10n.unitChecklistChoiceHint(index + 1),
                      prefixIcon: const Icon(
                        Icons.radio_button_unchecked,
                        size: 18,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 36,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('unit-checklist-choice-remove-$index'),
                  tooltip: l10n.unitChecklistRemoveChoice,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.enabled && _rows.length > 1
                      ? () => _remove(index)
                      : null,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
        if (error != null && error.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: spacing.xs),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('unit-checklist-add-choice'),
            onPressed: canAdd ? _add : null,
            icon: const Icon(Icons.add, size: 18),
            label: Text(
              _rows.length < unitChecklistMaxChoices
                  ? l10n.unitChecklistAddChoice
                  : l10n.unitChecklistChoicesLimit(unitChecklistMaxChoices),
            ),
          ),
        ),
        Text(
          l10n.unitChecklistChoicesHelp,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ],
    );
  }
}
