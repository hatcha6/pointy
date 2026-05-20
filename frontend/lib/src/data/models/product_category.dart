class ProductCategory {
  const ProductCategory({
    required this.id,
    required this.name,
    this.description = '',
    this.parentId,
    this.parentName = '',
    this.childrenCount = 0,
    this.isActive = true,
  });

  final int id;
  final String name;
  final String description;
  final int? parentId;
  final String parentName;
  final int childrenCount;
  final bool isActive;

  String get displayPath {
    if (parentName.trim().isEmpty) {
      return name;
    }
    return '$parentName / $name';
  }

  factory ProductCategory.fromJson(Map<String, Object?> json) {
    return ProductCategory(
      id: json['id'] as int,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      parentId: (json['parent'] as num?)?.toInt(),
      parentName: (json['parent_name'] as String?) ?? '',
      childrenCount: (json['children_count'] as num?)?.toInt() ?? 0,
      isActive: (json['is_active'] as bool?) ?? true,
    );
  }
}

class ProductCategoryDraft {
  const ProductCategoryDraft({
    required this.name,
    this.description = '',
    this.parentId,
    this.isActive = true,
  });

  final String name;
  final String description;
  final int? parentId;
  final bool isActive;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'parent': parentId,
      'is_active': isActive,
    };
  }
}

class ProductCategoryPage {
  const ProductCategoryPage({required this.categories, required this.hasMore});

  final List<ProductCategory> categories;
  final bool hasMore;

  factory ProductCategoryPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(ProductCategory.fromJson)
        .toList(growable: false);

    return ProductCategoryPage(
      categories: results,
      hasMore: json['next'] != null,
    );
  }
}
