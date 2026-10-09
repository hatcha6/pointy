class ProductCategory {
  const ProductCategory({
    required this.id,
    required this.name,
    this.description = '',
    this.parentId,
    this.parentName = '',
    this.childrenCount = 0,
    this.productCount = 0,
    this.isActive = true,
    this.isQuickAccess = false,
    this.displayOrder = 0,
    this.isSystem = false,
    this.systemKey = '',
  });

  final int id;
  final String name;
  final String description;
  final int? parentId;
  final String parentName;
  final int childrenCount;
  final int productCount;
  final bool isActive;

  /// Pinned to the one-tap quick-access filter strip above the POS and
  /// purchasing catalog search.
  final bool isQuickAccess;

  /// Manual sort order, primarily used to arrange the quick-access strip.
  final int displayOrder;

  /// Kept by a feature rather than made by the shop: a provider's cards are
  /// filed here, and the category was pinned to quick access when it was made.
  /// The shop may rename, move, switch off, unpin or reorder it, but not
  /// delete it — the next sync would only make it again.
  final bool isSystem;

  /// Which feature keeps a system category — see [ProductCategorySystemKey].
  /// Blank for every category a shop made, and from a server that predates it.
  final String systemKey;

  /// The «كروت دفتر» shelf: the till shows its own voucher menu for it
  /// instead of the product grid.
  bool get isPointyVouchers =>
      systemKey == ProductCategorySystemKey.pointyVouchers;

  bool get isRoot => parentId == null;

  String get displayPath {
    if (parentName.trim().isEmpty) {
      return name;
    }
    return '$parentName / $name';
  }

  ProductCategory copyWith({
    String? name,
    String? description,
    int? childrenCount,
    int? productCount,
    bool? isActive,
    bool? isQuickAccess,
    int? displayOrder,
  }) {
    return ProductCategory(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      parentId: parentId,
      parentName: parentName,
      childrenCount: childrenCount ?? this.childrenCount,
      productCount: productCount ?? this.productCount,
      isActive: isActive ?? this.isActive,
      isQuickAccess: isQuickAccess ?? this.isQuickAccess,
      displayOrder: displayOrder ?? this.displayOrder,
      isSystem: isSystem,
      systemKey: systemKey,
    );
  }

  factory ProductCategory.fromJson(Map<String, Object?> json) {
    return ProductCategory(
      id: json['id'] as int,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      parentId: (json['parent'] as num?)?.toInt(),
      parentName: (json['parent_name'] as String?) ?? '',
      childrenCount: (json['children_count'] as num?)?.toInt() ?? 0,
      productCount: (json['product_count'] as num?)?.toInt() ?? 0,
      isActive: (json['is_active'] as bool?) ?? true,
      isQuickAccess: (json['is_quick_access'] as bool?) ?? false,
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
      isSystem: (json['is_system'] as bool?) ?? false,
      systemKey: json['system_key']?.toString() ?? '',
    );
  }
}

/// The stable codes the server uses for [ProductCategory.systemKey].
abstract final class ProductCategorySystemKey {
  /// The company's own prepaid cards («كروت دفتر»).
  static const pointyVouchers = 'vouchers:pointy';
}

class ProductCategoryDraft {
  const ProductCategoryDraft({
    required this.name,
    this.description = '',
    this.parentId,
    this.isActive = true,
    this.isQuickAccess = false,
  });

  final String name;
  final String description;
  final int? parentId;
  final bool isActive;
  final bool isQuickAccess;

  // display_order is intentionally omitted: ordering is managed separately
  // (reordering the quick-access strip) so editing a category never disturbs
  // its position.
  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'parent': parentId,
      'is_active': isActive,
      'is_quick_access': isQuickAccess,
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
