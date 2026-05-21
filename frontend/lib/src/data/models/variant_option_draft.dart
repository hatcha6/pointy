class VariantOptionDraft {
  const VariantOptionDraft({
    required this.code,
    required this.name,
    this.displayOrder = 0,
    this.isActive = true,
  });

  final String code;
  final String name;
  final int displayOrder;
  final bool isActive;

  Map<String, Object?> toJson() {
    return {
      'code': code,
      'name': name,
      'display_order': displayOrder,
      'is_active': isActive,
    };
  }
}
