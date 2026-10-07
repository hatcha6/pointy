import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/unit_attribute.dart';
import '../design/design.dart';

/// An article's facts on one line — «92% · ممتاز + · مفتوح · الشاحن مرفق» —
/// for rows where there is room for a phrase, not a table: the till's picker
/// and the capture sheet.
///
/// Values, not «label value» pairs: a grade, a lock state or a percentage
/// reads on its own, and spelling every label out («صحة البطارية … درجة الحالة
/// … قفل الشبكة / الحساب …») filled a phone-width row before the third fact.
/// A date is the exception — «2027/03/01» alone says nothing — and keeps its
/// label. A ticked yes/no fact reads as its own label (the charger *is*
/// included); an unticked one says nothing, because "no charger" is the
/// absence of a line, not a line.
class UnitAttributeSummary extends StatelessWidget {
  const UnitAttributeSummary({
    super.key,
    required this.values,
    this.maxLines = 1,
    this.style,
  });

  final List<UnitAttributeValue> values;
  final int maxLines;
  final TextStyle? style;

  static String describe(List<UnitAttributeValue> values) {
    return [
      for (final value in values)
        if (value.isBoolean)
          if (value.value == true) value.label else ''
        else if (value.dataType == UnitAttributeType.date)
          '${value.label} ${value.display}'
        else
          value.display,
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final text = describe(values);
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style:
          style ??
          theme.textTheme.bodySmall?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
    );
  }
}

/// [values] as the server would format them, for facts typed on this device
/// and not yet saved — the capture sheet's rows before the receipt posts.
List<UnitAttributeValue> displayUnitAttributes(
  List<UnitAttributeDefinition> definitions,
  Map<String, Object?> values,
  AppLocalizations l10n,
) {
  return [
    for (final definition in definitions)
      if (values[definition.key] case final value? when '$value'.isNotEmpty)
        UnitAttributeValue(
          key: definition.key,
          label: definition.label,
          value: value,
          display: _display(definition, value, l10n),
          dataType: definition.dataType,
          showInPicker: definition.showInPicker,
        ),
  ];
}

String _display(
  UnitAttributeDefinition definition,
  Object value,
  AppLocalizations l10n,
) {
  switch (definition.dataType) {
    case UnitAttributeType.choice:
      for (final choice in definition.choices) {
        if (choice.value == '$value') return choice.label;
      }
      return '$value';
    case UnitAttributeType.boolean:
      return value == true ? l10n.yesLabel : l10n.noLabel;
  }
  if (definition.isNumeric && value is num) {
    final text = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    final suffix = definition.displaySuffix;
    if (suffix.isEmpty) return text;
    return suffix == '%' || suffix == '"' ? '$text$suffix' : '$text $suffix';
  }
  return '$value';
}
