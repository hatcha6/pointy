import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/unit_attribute.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/unit_checklist_view_model.dart';
import 'unit_checklist_choices_editor.dart';
import 'unit_checklist_types.dart';

typedef UnitChecklistFieldSaver =
    Future<UnitChecklistSaveOutcome> Function(UnitAttributeDefinition draft);

/// Opens the editor for one checklist field — a new one when [initial] is
/// null — and answers what the server saved, or null when cancelled.
Future<UnitAttributeDefinition?> showUnitChecklistFieldEditor(
  BuildContext context, {
  required int assetTypeId,
  required String kindName,
  required UnitChecklistFieldSaver onSave,
  UnitAttributeDefinition? initial,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveFormSurface<UnitAttributeDefinition>(
    context: context,
    title: initial == null
        ? l10n.unitChecklistAddFieldTitle(kindName)
        : l10n.unitChecklistEditFieldTitle(initial.label),
    builder: (context) => UnitChecklistFieldForm(
      assetTypeId: assetTypeId,
      initial: initial,
      onSave: onSave,
    ),
  );
}

/// What the form refuses before asking the server: no name, or a list field
/// with no options (or the same option twice). Keyed like the server's own
/// refusals, so both land under the same control.
Map<String, String> unitChecklistDraftErrors(
  UnitAttributeDefinition draft,
  AppLocalizations l10n,
) {
  final errors = <String, String>{};
  if (draft.label.trim().isEmpty) {
    errors['label'] = l10n.unitChecklistLabelRequired;
  }
  if (draft.dataType == UnitAttributeType.choice) {
    final seen = <String>{};
    for (final choice in draft.choices) {
      if (!seen.add(choice.label.trim())) {
        errors['choices'] = l10n.unitChecklistChoiceDuplicate(choice.label);
        break;
      }
    }
    if (draft.choices.isEmpty) {
      errors['choices'] = l10n.unitChecklistChoicesRequired;
    }
  }
  return errors;
}

/// One field of a kind's intake checklist: its name, the kind of answer it
/// takes, and where the answer shows.
///
/// The kind of answer is chosen once. Every value recorded under a field was
/// checked against its type, so the server refuses a change and the form
/// does not offer one — it says why instead.
class UnitChecklistFieldForm extends StatefulWidget {
  const UnitChecklistFieldForm({
    super.key,
    required this.assetTypeId,
    required this.onSave,
    this.initial,
  });

  final int assetTypeId;
  final UnitAttributeDefinition? initial;
  final UnitChecklistFieldSaver onSave;

  @override
  State<UnitChecklistFieldForm> createState() => _UnitChecklistFieldFormState();
}

class _UnitChecklistFieldFormState extends State<UnitChecklistFieldForm> {
  late final _initial = widget.initial;
  late final _label = TextEditingController(text: _initial?.label ?? '');
  late final _suffix = TextEditingController(text: _initial?.suffix ?? '');
  late String _type = _initial?.dataType ?? UnitAttributeType.boolean;
  late List<UnitAttributeChoice> _choices = _initial?.choices ?? const [];
  late bool _required = _initial?.isRequired ?? false;
  late bool _inPicker = _initial?.showInPicker ?? true;
  // Carried through untouched, never offered: nothing prints a checklist on
  // a label or a receipt yet, and a switch that changes nothing is a promise
  // the shop would find broken at the printer.
  late final bool _onLabel = _initial?.showOnLabel ?? false;
  late final bool _onReceipt = _initial?.showOnReceipt ?? false;
  Map<String, String> _errors = const {};
  String _message = '';
  bool _saving = false;

  bool get _isNew => _initial == null;

  @override
  void dispose() {
    _label.dispose();
    _suffix.dispose();
    super.dispose();
  }

  UnitAttributeDefinition _draft() {
    final takesSuffix = unitChecklistTypeTakesSuffix(_type);
    return UnitAttributeDefinition(
      id: _initial?.id ?? 0,
      assetTypeId: widget.assetTypeId,
      key: _initial?.key ?? '',
      label: _label.text.trim(),
      dataType: _type,
      // A row left blank is not an option; an emptied existing one is a
      // removal, which the help line under the list explains.
      choices: _type == UnitAttributeType.choice
          ? [
              for (final choice in _choices)
                if (choice.label.trim().isNotEmpty)
                  UnitAttributeChoice(
                    value: choice.value,
                    label: choice.label.trim(),
                  ),
            ]
          : const [],
      suffix: takesSuffix ? _suffix.text.trim() : '',
      isRequired: _required,
      showInPicker: _inPicker,
      showOnLabel: _onLabel,
      showOnReceipt: _onReceipt,
      displayOrder: _initial?.displayOrder ?? 0,
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final draft = _draft();
    final errors = unitChecklistDraftErrors(draft, l10n);
    if (errors.isNotEmpty) {
      setState(() {
        _errors = errors;
        _message = '';
      });
      return;
    }
    setState(() {
      _saving = true;
      _errors = const {};
      _message = '';
    });
    final outcome = await widget.onSave(draft);
    if (!mounted) return;
    if (outcome.isSaved) {
      Navigator.of(context).pop(outcome.definition);
      return;
    }
    final error = outcome.error;
    setState(() {
      _saving = false;
      _errors = outcome.fieldErrors;
      _message = outcome.message.isNotEmpty || outcome.fieldErrors.isNotEmpty
          ? outcome.message
          : (error == null
                ? l10n.errorUnexpectedMessage
                : errorMessageFor(error, l10n));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final enabled = !_saving;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsetsDirectional.fromSTEB(
                spacing.md,
                spacing.sm,
                spacing.md,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_message.isNotEmpty) ...[
                    PointyInlineMessage.error(message: _message, compact: true),
                    SizedBox(height: spacing.sm),
                  ],
                  TextField(
                    key: const ValueKey('unit-checklist-label'),
                    controller: _label,
                    enabled: enabled,
                    autofocus: _isNew,
                    maxLength: 80,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l10n.unitChecklistLabelLabel,
                      hintText: l10n.unitChecklistLabelHint,
                      errorText: _errors['label'],
                      counterText: '',
                    ),
                  ),
                  SizedBox(height: spacing.md),
                  _TypeField(
                    value: _type,
                    locked: !_isNew,
                    enabled: enabled,
                    error: _errors['data_type'],
                    onChanged: (type) => setState(() => _type = type),
                  ),
                  if (unitChecklistTypeTakesSuffix(_type)) ...[
                    SizedBox(height: spacing.md),
                    TextField(
                      key: const ValueKey('unit-checklist-suffix'),
                      controller: _suffix,
                      enabled: enabled,
                      maxLength: 16,
                      decoration: InputDecoration(
                        labelText: l10n.unitChecklistSuffixLabel,
                        hintText: l10n.unitChecklistSuffixHint,
                        errorText: _errors['suffix'],
                        counterText: '',
                      ),
                    ),
                  ],
                  if (_type == UnitAttributeType.choice) ...[
                    SizedBox(height: spacing.md),
                    UnitChecklistChoicesEditor(
                      initial: _choices,
                      enabled: enabled,
                      error: _errors['choices'],
                      onChanged: (choices) => _choices = choices,
                    ),
                  ],
                  SizedBox(height: spacing.sm),
                  const Divider(height: 1),
                  _FlagSwitch(
                    switchKey: 'required',
                    icon: Icons.assignment_turned_in_outlined,
                    title: l10n.unitChecklistRequiredTitle,
                    subtitle: l10n.unitChecklistRequiredSubtitle,
                    value: _required,
                    onChanged: enabled
                        ? (value) => setState(() => _required = value)
                        : null,
                  ),
                  _FlagSwitch(
                    switchKey: 'picker',
                    icon: Icons.point_of_sale_outlined,
                    title: l10n.unitChecklistPickerTitle,
                    subtitle: l10n.unitChecklistPickerSubtitle,
                    value: _inPicker,
                    onChanged: enabled
                        ? (value) => setState(() => _inPicker = value)
                        : null,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
                SizedBox(width: spacing.sm),
                FilledButton.icon(
                  key: const ValueKey('unit-checklist-save'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(l10n.saveButton),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeField extends StatelessWidget {
  const _TypeField({
    required this.value,
    required this.locked,
    required this.enabled,
    required this.onChanged,
    this.error,
  });

  final String value;
  final bool locked;
  final bool enabled;
  final String? error;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // A type a newer server added still shows, as itself, when locked.
    final types = unitChecklistTypes.contains(value)
        ? unitChecklistTypes
        : [...unitChecklistTypes, value];
    return DropdownButtonFormField<String>(
      key: const ValueKey('unit-checklist-type'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.unitChecklistTypeLabel,
        helperText: locked ? l10n.unitChecklistTypeLocked : null,
        helperMaxLines: 2,
        errorText: error,
        prefixIcon: Icon(unitChecklistTypeIcon(value)),
      ),
      items: [
        for (final type in types)
          DropdownMenuItem(
            value: type,
            child: Text(unitChecklistTypeLabel(l10n, type)),
          ),
      ],
      onChanged: locked || !enabled
          ? null
          : (type) {
              if (type != null) onChanged(type);
            },
    );
  }
}

class _FlagSwitch extends StatelessWidget {
  const _FlagSwitch({
    required this.switchKey,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String switchKey;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final subtitle = this.subtitle;
    return SwitchListTile(
      key: ValueKey('unit-checklist-flag-$switchKey'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: colors.mutedInk),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
