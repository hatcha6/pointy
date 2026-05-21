class VariantOptionValueDraft {
  const VariantOptionValueDraft({
    required this.optionId,
    required this.code,
    required this.name,
    this.displayOrder = 0,
    this.isActive = true,
  });

  final int optionId;
  final String code;
  final String name;
  final int displayOrder;
  final bool isActive;

  Map<String, Object?> toJson() {
    return {
      'option': optionId,
      'code': code,
      'name': name,
      'display_order': displayOrder,
      'is_active': isActive,
    };
  }
}
