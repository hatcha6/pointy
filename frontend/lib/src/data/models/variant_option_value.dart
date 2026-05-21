class VariantOptionValue {
  const VariantOptionValue({
    required this.id,
    required this.optionId,
    required this.name,
    this.optionName = '',
    this.code = '',
    this.displayOrder = 0,
    this.isActive = true,
  });

  final int id;
  final int optionId;
  final String optionName;
  final String code;
  final String name;
  final int displayOrder;
  final bool isActive;

  String get displayLabel {
    if (optionName.trim().isEmpty) {
      return name;
    }
    return '$optionName: $name';
  }

  factory VariantOptionValue.fromJson(Map<String, Object?> json) {
    return VariantOptionValue(
      id: _intFromJson(json['id']),
      optionId: _intFromJson(json['option']),
      optionName: json['option_name']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      displayOrder: _intFromJson(json['display_order']),
      isActive: (json['is_active'] as bool?) ?? true,
    );
  }
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
