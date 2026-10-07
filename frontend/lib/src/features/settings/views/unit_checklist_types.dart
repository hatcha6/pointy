import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/unit_attribute.dart';

/// The kinds of answer a checklist field can take, in the order the editor
/// offers them — the everyday ones first.
const unitChecklistTypes = [
  UnitAttributeType.boolean,
  UnitAttributeType.choice,
  UnitAttributeType.text,
  UnitAttributeType.number,
  UnitAttributeType.percent,
  UnitAttributeType.money,
  UnitAttributeType.date,
];

String unitChecklistTypeLabel(AppLocalizations l10n, String type) {
  return switch (type) {
    UnitAttributeType.number => l10n.unitChecklistTypeNumber,
    UnitAttributeType.percent => l10n.unitChecklistTypePercent,
    UnitAttributeType.money => l10n.unitChecklistTypeMoney,
    UnitAttributeType.date => l10n.unitChecklistTypeDate,
    UnitAttributeType.choice => l10n.unitChecklistTypeChoice,
    UnitAttributeType.boolean => l10n.unitChecklistTypeBool,
    _ => l10n.unitChecklistTypeText,
  };
}

IconData unitChecklistTypeIcon(String type) {
  return switch (type) {
    UnitAttributeType.number => Icons.pin_outlined,
    UnitAttributeType.percent => Icons.percent,
    UnitAttributeType.money => Icons.payments_outlined,
    UnitAttributeType.date => Icons.event_outlined,
    UnitAttributeType.choice => Icons.list_alt_outlined,
    UnitAttributeType.boolean => Icons.toggle_on_outlined,
    _ => Icons.short_text,
  };
}

/// Only a number is ever shown with a unit (`GB`, `km`, `%`).
bool unitChecklistTypeTakesSuffix(String type) =>
    type == UnitAttributeType.number ||
    type == UnitAttributeType.percent ||
    type == UnitAttributeType.money;
