class ProductUpdateDraft {
  const ProductUpdateDraft({
    required this.name,
    required this.description,
    required this.isActive,
    required this.categoryIds,
  });

  final String name;
  final String description;
  final bool isActive;
  final List<int> categoryIds;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'categories': categoryIds,
    };
  }
}
