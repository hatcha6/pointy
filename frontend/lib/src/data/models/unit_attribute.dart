/// The typed facts a kind of article records — battery health, shutter count,
/// cosmetic grade, what came in the box.
///
/// Defined per asset type by the shop (§4.5) and read here to draw the right
/// control for each: a percentage gets a number field with `%`, a grade gets
/// its choices, a box-and-charger question gets a tick.
class UnitAttributeDefinition {
  const UnitAttributeDefinition({
    required this.key,
    required this.label,
    this.id = 0,
    this.assetTypeId,
    this.dataType = UnitAttributeType.text,
    this.choices = const [],
    this.suffix = '',
    this.isRequired = false,
    this.showInPicker = true,
    this.displayOrder = 0,
  });

  final int id;
  final int? assetTypeId;
  final String key;
  final String label;

  /// One of [UnitAttributeType]. A string rather than an enum so a kind a
  /// newer backend adds renders as text instead of throwing.
  final String dataType;
  final List<UnitAttributeChoice> choices;
  final String suffix;
  final bool isRequired;
  final bool showInPicker;
  final int displayOrder;

  bool get isNumeric =>
      dataType == UnitAttributeType.number ||
      dataType == UnitAttributeType.percent ||
      dataType == UnitAttributeType.money;

  /// What follows the number on screen: the definition's own unit, or `%`
  /// for a percentage that did not name one.
  String get displaySuffix => suffix.isNotEmpty
      ? suffix
      : dataType == UnitAttributeType.percent
      ? '%'
      : '';

  factory UnitAttributeDefinition.fromJson(Map<String, Object?> json) {
    final rawChoices = json['choices'];
    return UnitAttributeDefinition(
      id: _int(json['id']) ?? 0,
      assetTypeId: _int(json['asset_type']),
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      dataType: json['data_type']?.toString() ?? UnitAttributeType.text,
      choices: rawChoices is List<Object?>
          ? rawChoices
                .whereType<Map<String, Object?>>()
                .map(UnitAttributeChoice.fromJson)
                .toList(growable: false)
          : const [],
      suffix: json['suffix']?.toString() ?? '',
      isRequired: json['is_required'] == true,
      showInPicker: json['show_in_picker'] != false,
      displayOrder: _int(json['display_order']) ?? 0,
    );
  }
}

class UnitAttributeChoice {
  const UnitAttributeChoice({required this.value, required this.label});

  final String value;
  final String label;

  factory UnitAttributeChoice.fromJson(Map<String, Object?> json) {
    final value = json['value']?.toString() ?? '';
    final label = json['label']?.toString() ?? '';
    return UnitAttributeChoice(
      value: value,
      label: label.isEmpty ? value : label,
    );
  }
}

/// Mirrors `UnitAttributeDefinition.DataType` on the backend.
class UnitAttributeType {
  const UnitAttributeType._();

  static const text = 'text';
  static const number = 'number';
  static const percent = 'percent';
  static const money = 'money';
  static const date = 'date';
  static const choice = 'choice';
  static const boolean = 'bool';
}

/// One of an article's facts as the server formatted it: the definition's
/// label, and the value as a person reads it — a choice's label rather than
/// its code, a number with its unit.
class UnitAttributeValue {
  const UnitAttributeValue({
    required this.key,
    required this.label,
    required this.display,
    this.value,
    this.dataType = UnitAttributeType.text,
    this.showInPicker = true,
  });

  final String key;
  final String label;
  final String display;
  final Object? value;
  final String dataType;
  final bool showInPicker;

  bool get isBoolean => dataType == UnitAttributeType.boolean;

  factory UnitAttributeValue.fromJson(Map<String, Object?> json) {
    return UnitAttributeValue(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      display: json['display']?.toString() ?? '',
      value: json['value'],
      dataType: json['data_type']?.toString() ?? UnitAttributeType.text,
      showInPicker: json['show_in_picker'] != false,
    );
  }
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
