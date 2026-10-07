/// One kind of device as the checklist editor lists it: the shop's asset type,
/// with how many facts its intake checklist records.
///
/// Read from `unit-attribute-definitions/summary/`, which answers every active
/// kind with its counts in one call rather than a list call per kind.
class UnitChecklistKind {
  const UnitChecklistKind({
    required this.assetTypeId,
    required this.name,
    this.slug = '',
    this.iconKey = 'device',
    this.fieldCount = 0,
    this.requiredCount = 0,
  });

  final int assetTypeId;
  final String name;
  final String slug;
  final String iconKey;
  final int fieldCount;
  final int requiredCount;

  factory UnitChecklistKind.fromJson(Map<String, Object?> json) {
    return UnitChecklistKind(
      assetTypeId: _int(json['asset_type']),
      name: json['name']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      iconKey: json['icon_key']?.toString() ?? 'device',
      fieldCount: _int(json['field_count']),
      requiredCount: _int(json['required_count']),
    );
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
