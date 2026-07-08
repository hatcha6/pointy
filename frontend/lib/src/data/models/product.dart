import 'attachment_summary.dart';
import 'modifier_group.dart';
import 'product_category.dart';
import 'product_unit.dart';
import 'product_variant.dart';
import 'variant_option.dart';

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.quantityOnHand,
    this.popularity = 0,
    this.description = '',
    this.isActive = true,
    this.isArchived = false,
    this.archivedAt,
    this.tracksExpiry = false,
    this.isService = false,
    this.isPrepared = false,
    this.unit = 'piece',
    this.defaultSaleUnit = '',
    this.defaultPurchaseUnit = '',
    this.units = const [],
    this.categories = const [],
    this.variantOptions = const [],
    this.modifierGroups = const [],
    this.defaultVariant,
    this.variants = const [],
    this.primaryImage,
    this.imageAttachments = const [],
  });

  final int id;
  final String name;
  final double quantityOnHand;

  /// Denormalized "most bought" score from the server (recomputed nightly). Used
  /// to sort by demand; 0 when the payload predates the field.
  final int popularity;
  final String description;
  final bool isActive;
  final bool isArchived;
  final DateTime? archivedAt;
  final bool tracksExpiry;
  final bool isService;
  final bool isPrepared;

  /// Base (stock) unit code. Stock, recipes, and totals are kept in this unit.
  final String unit;

  /// Units pre-selected in POS / purchasing. Blank = the base [unit].
  final String defaultSaleUnit;
  final String defaultPurchaseUnit;

  /// Additional transactable units beyond the base unit.
  final List<ProductUnit> units;
  final List<ProductCategory> categories;
  final List<VariantOption> variantOptions;
  final List<ModifierGroup> modifierGroups;
  final ProductVariant? defaultVariant;
  final List<ProductVariant> variants;
  final AttachmentSummary? primaryImage;
  final List<AttachmentSummary> imageAttachments;

  int? get variantId => defaultVariant?.id;

  String get sellableName {
    final variantName = defaultVariant?.displayLabel;
    if (variantName != null && variantName.isNotEmpty) {
      return variantName;
    }
    return name;
  }

  String get effectiveSku => defaultVariant?.sku ?? '';

  String get effectiveBarcode => defaultVariant?.barcode ?? '';

  double get effectiveUnitPrice => defaultVariant?.unitPrice ?? 0;

  double get effectiveQuantityOnHand =>
      defaultVariant?.quantityOnHand ?? quantityOnHand;

  List<ProductVariant> get activeVariants {
    if (!isActive) {
      return const [];
    }
    final active = <ProductVariant>[];
    final seen = <int>{};
    for (final variant in variants) {
      if (variant.isActive && seen.add(variant.id)) {
        active.add(variant);
      }
    }
    final defaultVariant = this.defaultVariant;
    if (defaultVariant != null &&
        defaultVariant.isActive &&
        seen.add(defaultVariant.id)) {
      active.insert(0, defaultVariant);
    }
    active.sort((a, b) {
      if (a.isDefault != b.isDefault) {
        return a.isDefault ? -1 : 1;
      }
      return a.pickerLabel.compareTo(b.pickerLabel);
    });
    return active;
  }

  factory Product.fromJson(Map<String, Object?> json) {
    final defaultVariantJson = json['default_variant'];
    final defaultVariant = defaultVariantJson is Map<String, Object?>
        ? ProductVariant.fromJson(defaultVariantJson)
        : null;
    final variants = _variantsFromJson(json);
    final product = Product(
      id: _intFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      quantityOnHand: _stockQtyFromJson(
        json['quantity_on_hand'] ?? defaultVariant?.quantityOnHand,
      ),
      popularity: (json['popularity'] as num?)?.toInt() ?? 0,
      description: (json['description'] as String?) ?? '',
      isActive: (json['is_active'] as bool?) ?? true,
      isArchived: (json['is_archived'] as bool?) ?? false,
      archivedAt: _dateTimeFromJson(json['archived_at']),
      tracksExpiry: (json['tracks_expiry'] as bool?) ?? false,
      isService: (json['is_service'] as bool?) ?? false,
      isPrepared: (json['is_prepared'] as bool?) ?? false,
      unit: json['unit']?.toString() ?? 'piece',
      defaultSaleUnit: json['default_sale_unit']?.toString() ?? '',
      defaultPurchaseUnit: json['default_purchase_unit']?.toString() ?? '',
      units: _unitsFromJson(json),
      categories: _categoriesFromJson(json),
      variantOptions: _variantOptionsFromJson(json),
      modifierGroups: _modifierGroupsFromJson(json),
      defaultVariant: defaultVariant,
      variants: variants,
      primaryImage: _primaryImageFromJson(json),
      imageAttachments: _imageAttachmentsFromJson(json),
    );
    // The catalog list drops the redundant per-variant `product_detail` (the
    // parent product is this list item). Re-attach it so a catalog-tapped
    // variant still resolves its product context via [Product.fromVariant].
    return product._withParentAttachedToVariants();
  }

  /// Re-attaches this product as the `productDetail` of any variant that arrived
  /// without one (the backend omits it in the catalog list to avoid shipping the
  /// parent N+1× per row). No-op when the payload already carried it.
  Product _withParentAttachedToVariants() {
    final default_ = defaultVariant;
    final needsAttach =
        (default_ != null && default_.productDetail == null) ||
        variants.any((variant) => variant.productDetail == null);
    if (!needsAttach) {
      return this;
    }
    return Product(
      id: id,
      name: name,
      quantityOnHand: quantityOnHand,
      popularity: popularity,
      description: description,
      isActive: isActive,
      isArchived: isArchived,
      archivedAt: archivedAt,
      tracksExpiry: tracksExpiry,
      isService: isService,
      isPrepared: isPrepared,
      unit: unit,
      defaultSaleUnit: defaultSaleUnit,
      defaultPurchaseUnit: defaultPurchaseUnit,
      units: units,
      categories: categories,
      variantOptions: variantOptions,
      modifierGroups: modifierGroups,
      defaultVariant: default_ == null
          ? null
          : (default_.productDetail == null
                ? default_.copyWith(productDetail: this)
                : default_),
      variants: variants
          .map(
            (variant) => variant.productDetail == null
                ? variant.copyWith(productDetail: this)
                : variant,
          )
          .toList(growable: false),
      primaryImage: primaryImage,
      imageAttachments: imageAttachments,
    );
  }

  factory Product.fromVariant(ProductVariant variant) {
    final detail = variant.productDetail;
    return Product(
      id: variant.productId,
      name: variant.displayLabel.isNotEmpty
          ? variant.displayLabel
          : detail?.name ?? variant.productName,
      quantityOnHand: variant.quantityOnHand,
      description: detail?.description ?? '',
      isActive: variant.isSellable,
      tracksExpiry: detail?.tracksExpiry ?? variant.tracksExpiry,
      unit: variant.unit,
      defaultSaleUnit: detail?.defaultSaleUnit ?? '',
      defaultPurchaseUnit: detail?.defaultPurchaseUnit ?? '',
      units: detail?.units ?? const [],
      categories: detail?.categories ?? const [],
      variantOptions: detail?.variantOptions ?? const [],
      modifierGroups: detail?.modifierGroups ?? const [],
      defaultVariant: variant,
      primaryImage: variant.primaryImage ?? detail?.primaryImage,
      imageAttachments: variant.imageAttachments.isNotEmpty
          ? variant.imageAttachments
          : detail?.imageAttachments ?? const [],
    );
  }

  /// Slim serialization for local persistence — only the unit metadata a
  /// restored cart/draft line needs (no variants/categories, avoiding
  /// recursion). The omitted relations default to empty on [Product.fromJson].
  Map<String, Object?> toCartJson() {
    return {
      'id': id,
      'name': name,
      'quantity_on_hand': quantityOnHand,
      'tracks_expiry': tracksExpiry,
      'is_service': isService,
      'is_prepared': isPrepared,
      'unit': unit,
      'default_sale_unit': defaultSaleUnit,
      'default_purchase_unit': defaultPurchaseUnit,
      'units': units
          .map((productUnit) => productUnit.toJson())
          .toList(growable: false),
    };
  }

  Product copyWith({
    double? quantityOnHand,
    ProductVariant? defaultVariant,
    List<ProductVariant>? variants,
    bool? tracksExpiry,
    bool? isArchived,
    DateTime? archivedAt,
  }) {
    final nextDefaultVariant =
        defaultVariant ??
        (quantityOnHand == null
            ? this.defaultVariant
            : this.defaultVariant?.copyWith(quantityOnHand: quantityOnHand));
    return Product(
      id: id,
      name: name,
      quantityOnHand: quantityOnHand ?? this.quantityOnHand,
      description: description,
      isActive: isActive,
      isArchived: isArchived ?? this.isArchived,
      archivedAt: archivedAt ?? this.archivedAt,
      tracksExpiry: tracksExpiry ?? this.tracksExpiry,
      isService: isService,
      isPrepared: isPrepared,
      unit: unit,
      defaultSaleUnit: defaultSaleUnit,
      defaultPurchaseUnit: defaultPurchaseUnit,
      units: units,
      categories: categories,
      variantOptions: variantOptions,
      modifierGroups: modifierGroups,
      defaultVariant: nextDefaultVariant,
      variants: variants ?? this.variants,
      primaryImage: primaryImage,
      imageAttachments: imageAttachments,
    );
  }

  /// Units offered in POS (the base unit plus sellable additional units).
  List<ProductUnit> get sellableUnits => [
    for (final unit in units)
      if (unit.isSellable && unit.unit.isActive) unit,
  ];

  /// Units offered in purchasing (the base unit plus purchasable units).
  List<ProductUnit> get purchasableUnits => [
    for (final unit in units)
      if (unit.isPurchasable && unit.unit.isActive) unit,
  ];

  /// Whether the product can be transacted in more than just its base unit.
  bool get hasSellableUnits => sellableUnits.isNotEmpty;
  bool get hasPurchasableUnits => purchasableUnits.isNotEmpty;

  static List<ProductCategory> _categoriesFromJson(Map<String, Object?> json) {
    final details = json['category_details'];
    if (details is List<Object?>) {
      return details
          .cast<Map<String, Object?>>()
          .map(ProductCategory.fromJson)
          .toList(growable: false);
    }
    final categoryIds = json['categories'];
    if (categoryIds is List<Object?>) {
      return [
        for (final id in categoryIds)
          if (id is num) ProductCategory(id: id.toInt(), name: ''),
      ];
    }
    return const [];
  }

  static List<ProductUnit> _unitsFromJson(Map<String, Object?> json) {
    final units = json['units'];
    if (units is List<Object?>) {
      return units
          .whereType<Map<String, Object?>>()
          .map(ProductUnit.fromJson)
          .toList(growable: false);
    }
    return const [];
  }

  static List<ProductVariant> _variantsFromJson(Map<String, Object?> json) {
    final variants = json['variants'];
    if (variants is List<Object?>) {
      return variants
          .whereType<Map<String, Object?>>()
          .map(ProductVariant.fromJson)
          .toList(growable: false);
    }
    return const [];
  }

  static List<ModifierGroup> _modifierGroupsFromJson(
    Map<String, Object?> json,
  ) {
    final details = json['modifier_group_details'];
    if (details is List<Object?>) {
      return details
          .whereType<Map<String, Object?>>()
          .map(ModifierGroup.fromJson)
          .toList(growable: false);
    }
    return const [];
  }

  static List<VariantOption> _variantOptionsFromJson(
    Map<String, Object?> json,
  ) {
    final details = json['variant_option_details'];
    if (details is List<Object?>) {
      return details
          .whereType<Map<String, Object?>>()
          .map(VariantOption.fromJson)
          .toList(growable: false);
    }
    final optionIds = json['variant_options'];
    if (optionIds is List<Object?>) {
      return [
        for (final id in optionIds)
          if (id is num) VariantOption(id: id.toInt(), code: '', name: ''),
      ];
    }
    return const [];
  }

  static AttachmentSummary? _primaryImageFromJson(Map<String, Object?> json) {
    final primaryImage = json['primary_image'];
    if (primaryImage is Map<String, Object?>) {
      return AttachmentSummary.fromJson(primaryImage);
    }
    return null;
  }

  static List<AttachmentSummary> _imageAttachmentsFromJson(
    Map<String, Object?> json,
  ) {
    final attachments = json['image_attachments'];
    if (attachments is List<Object?>) {
      return attachments
          .whereType<Map<String, Object?>>()
          .map(AttachmentSummary.fromJson)
          .toList(growable: false);
    }
    return const [];
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

double _stockQtyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}
