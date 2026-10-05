import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/unit_attribute.dart';
import '../date_formatters.dart';
import '../design/design.dart';
import '../responsive/responsive.dart';

/// An article's condition record, drawn from its kind's definitions (§4.5).
///
/// One widget for every place a person records it — the unit page's edit sheet
/// and the capture sheet at intake — so a battery health typed at the counter
/// and one corrected a month later are the same field with the same rules.
///
/// Each definition gets the control its type asks for: text and numbers as
/// fields (a number carries its unit), a short list of grades as chips, a long
/// one as a dropdown, a date as a picker. Yes/no facts — the charger, the box,
/// the papers — are grouped into one checklist of chips at the end, which is
/// how a shop actually reads them off a counter: *what came with it*.
///
/// The form owns no state the caller cannot see: every change is reported
/// through [onChanged] as the whole map, in the types the server stores.
class UnitAttributeForm extends StatefulWidget {
  const UnitAttributeForm({
    super.key,
    required this.definitions,
    required this.values,
    required this.onChanged,
    this.errors = const {},
    this.enabled = true,
  });

  final List<UnitAttributeDefinition> definitions;
  final Map<String, Object?> values;
  final ValueChanged<Map<String, Object?>> onChanged;

  /// Per-key messages: the client's own required/number checks, or the
  /// server's Arabic refusal for the same key.
  final Map<String, String> errors;
  final bool enabled;

  @override
  State<UnitAttributeForm> createState() => _UnitAttributeFormState();
}

class _UnitAttributeFormState extends State<UnitAttributeForm> {
  final Map<String, TextEditingController> _controllers = {};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(UnitAttributeDefinition definition) {
    return _controllers.putIfAbsent(definition.key, () {
      final value = widget.values[definition.key];
      return TextEditingController(text: _editableText(definition, value));
    });
  }

  /// The last map this form reported. Two edits can land before the parent
  /// rebuilds — a value typed, then a chip tapped in the same frame — and
  /// building the second from the stale [UnitAttributeForm.values] would
  /// silently undo the first.
  late Map<String, Object?> _latest = widget.values;

  @override
  void didUpdateWidget(UnitAttributeForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.values, widget.values)) {
      _latest = widget.values;
    }
  }

  void _set(String key, Object? value) {
    final next = Map<String, Object?>.from(_latest);
    if (value == null || (value is String && value.trim().isEmpty)) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    _latest = next;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final fields = [
      for (final definition in widget.definitions)
        if (definition.dataType != UnitAttributeType.boolean) definition,
    ];
    final checklist = [
      for (final definition in widget.definitions)
        if (definition.dataType == UnitAttributeType.boolean) definition,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fields.isNotEmpty)
          ResponsiveFormGrid(
            minChildWidth: 240,
            maxColumns: 2,
            children: [for (final definition in fields) _field(definition)],
          ),
        if (checklist.isNotEmpty) ...[
          if (fields.isNotEmpty) SizedBox(height: spacing.md),
          _Checklist(
            definitions: checklist,
            values: widget.values,
            errors: widget.errors,
            enabled: widget.enabled,
            onToggle: (key, value) => _set(key, value),
          ),
        ],
      ],
    );
  }

  Widget _field(UnitAttributeDefinition definition) {
    final error = widget.errors[definition.key];
    final label = definition.isRequired
        ? '${definition.label} *'
        : definition.label;
    switch (definition.dataType) {
      case UnitAttributeType.choice:
        return _ChoiceField(
          key: ValueKey('unit-attribute-${definition.key}'),
          definition: definition,
          label: label,
          value: widget.values[definition.key]?.toString(),
          error: error,
          enabled: widget.enabled,
          onChanged: (value) => _set(definition.key, value),
        );
      case UnitAttributeType.date:
        return UnitDateField(
          key: ValueKey('unit-attribute-${definition.key}'),
          label: label,
          value: DateTime.tryParse(
            widget.values[definition.key]?.toString() ?? '',
          ),
          error: error,
          enabled: widget.enabled,
          onChanged: (value) =>
              _set(definition.key, value == null ? null : isoDate(value)),
        );
      default:
        final numeric = definition.isNumeric;
        return TextFormField(
          key: ValueKey('unit-attribute-${definition.key}'),
          controller: _controllerFor(definition),
          enabled: widget.enabled,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          textDirection: numeric ? TextDirection.ltr : null,
          inputFormatters: numeric
              ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
              : null,
          decoration: InputDecoration(
            labelText: label,
            suffixText: numeric && definition.displaySuffix.isNotEmpty
                ? definition.displaySuffix
                : null,
            errorText: error,
          ),
          onChanged: (text) {
            final trimmed = text.trim();
            if (!numeric || trimmed.isEmpty) {
              _set(definition.key, trimmed);
              return;
            }
            // Kept as typed until it parses, so "8." on the way to "8.5"
            // is not thrown away; the check before saving names it.
            _set(definition.key, num.tryParse(trimmed) ?? trimmed);
          },
        );
    }
  }
}

/// A grade or a lock state: chips while the list is short enough to read at a
/// glance, a dropdown past that. Tapping the chosen chip again clears it.
class _ChoiceField extends StatelessWidget {
  const _ChoiceField({
    super.key,
    required this.definition,
    required this.label,
    required this.value,
    required this.error,
    required this.enabled,
    required this.onChanged,
  });

  static const _chipLimit = 6;

  final UnitAttributeDefinition definition;
  final String label;
  final String? value;
  final String? error;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    if (definition.choices.length > _chipLimit) {
      final known = definition.choices.any((choice) => choice.value == value);
      return DropdownButtonFormField<String?>(
        initialValue: known ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, errorText: error),
        items: [
          for (final choice in definition.choices)
            DropdownMenuItem(value: choice.value, child: Text(choice.label)),
        ],
        onChanged: enabled ? onChanged : null,
      );
    }
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        errorText: error,
        // The chips are the field; the decorator only frames and labels them.
        contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 14, 12, 8),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final choice in definition.choices)
            ChoiceChip(
              label: Text(choice.label),
              selected: choice.value == value,
              visualDensity: VisualDensity.compact,
              labelStyle: theme.textTheme.labelMedium?.copyWith(
                color: choice.value == value ? colors.primaryDark : null,
              ),
              onSelected: enabled
                  ? (selected) => onChanged(selected ? choice.value : null)
                  : null,
            ),
        ],
      ),
    );
  }
}

/// A date that may be left empty: tap to pick, the cross to clear.
class UnitDateField extends StatelessWidget {
  const UnitDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.error,
    this.enabled = true,
    this.helperText,
  });

  final String label;
  final DateTime? value;
  final String? error;
  final bool enabled;
  final String? helperText;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final current = value;
    return InkWell(
      borderRadius: BorderRadius.circular(PointyRadii.input),
      onTap: enabled
          ? () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: current ?? DateTime.now(),
                firstDate: DateTime(1950),
                lastDate: DateTime(2100),
              );
              if (picked != null) onChanged(picked);
            }
          : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: error,
          helperText: helperText,
          helperMaxLines: 2,
          prefixIcon: const Icon(Icons.event_outlined),
          suffixIcon: current == null || !enabled
              ? null
              : IconButton(
                  tooltip: l10n.clearButton,
                  icon: const Icon(Icons.close),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(
          current == null ? l10n.unitAttributeChooseDate : formatDate(current),
        ),
      ),
    );
  }
}

/// The yes/no facts as one list of what came with the article.
class _Checklist extends StatelessWidget {
  const _Checklist({
    required this.definitions,
    required this.values,
    required this.errors,
    required this.enabled,
    required this.onToggle,
  });

  final List<UnitAttributeDefinition> definitions;
  final Map<String, Object?> values;
  final Map<String, String> errors;
  final bool enabled;
  final void Function(String key, bool value) onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final messages = [
      for (final definition in definitions) ?errors[definition.key],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.unitAttributesChecklistTitle,
          style: theme.textTheme.labelLarge?.copyWith(color: colors.mutedInk),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final definition in definitions)
              FilterChip(
                key: ValueKey('unit-attribute-${definition.key}'),
                label: Text(
                  definition.isRequired
                      ? '${definition.label} *'
                      : definition.label,
                ),
                selected: values[definition.key] == true,
                visualDensity: VisualDensity.compact,
                onSelected: enabled
                    ? (selected) => onToggle(definition.key, selected)
                    : null,
              ),
          ],
        ),
        for (final message in messages)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 4, start: 4),
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
      ],
    );
  }
}

/// The checks the form can make before asking the server: a required field
/// left empty, and a number that does not parse. The server still decides —
/// its refusal arrives per key in the same shape and replaces these.
Map<String, String> validateUnitAttributes(
  List<UnitAttributeDefinition> definitions,
  Map<String, Object?> values,
  AppLocalizations l10n,
) {
  final errors = <String, String>{};
  for (final definition in definitions) {
    final value = values[definition.key];
    final empty = value == null || (value is String && value.trim().isEmpty);
    if (empty) {
      if (definition.isRequired &&
          definition.dataType != UnitAttributeType.boolean) {
        errors[definition.key] = l10n.unitAttributeRequired(definition.label);
      }
      continue;
    }
    if (definition.isNumeric && value is! num) {
      errors[definition.key] = l10n.unitAttributeNotANumber(definition.label);
    }
  }
  return errors;
}

/// `2026-10-05`, the date shape the server stores.
String isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _editableText(UnitAttributeDefinition definition, Object? value) {
  if (value == null) return '';
  if (value is num && definition.isNumeric) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
  return value.toString();
}
