import 'variant_option_value.dart';

class VariantOption {
  const VariantOption({
    required this.id,
    required this.code,
    required this.name,
    this.displayOrder = 0,
    this.isActive = true,
    this.values = const [],
  });

  final int id;
  final String code;
  final String name;
  final int displayOrder;
  final bool isActive;
  final List<VariantOptionValue> values;

  String get displayLabel => name.trim().isEmpty ? code : name;

  VariantOption copyWith({
    int? id,
    String? code,
    String? name,
    int? displayOrder,
    bool? isActive,
    List<VariantOptionValue>? values,
  }) {
    return VariantOption(
      id: id ?? this.id,
      code: code ?? this.code,
      name: name ?? this.name,
      displayOrder: displayOrder ?? this.displayOrder,
      isActive: isActive ?? this.isActive,
      values: values ?? this.values,
    );
  }

  factory VariantOption.fromJson(Map<String, Object?> json) {
    return VariantOption(
      id: _intFromJson(json['id']),
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      displayOrder: _intFromJson(json['display_order']),
      isActive: (json['is_active'] as bool?) ?? true,
      values: _valuesFromJson(json['values']),
    );
  }
}

List<VariantOptionValue> _valuesFromJson(Object? value) {
  if (value is List<Object?>) {
    return value
        .whereType<Map<String, Object?>>()
        .map(VariantOptionValue.fromJson)
        .toList(growable: false);
  }
  return const [];
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}
