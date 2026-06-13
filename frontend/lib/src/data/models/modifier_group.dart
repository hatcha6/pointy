/// A single option within a [ModifierGroup] (e.g. "Oat milk", "Extra shot").
class ModifierOption {
  const ModifierOption({
    required this.id,
    required this.name,
    this.priceDelta = 0,
    this.maxQuantity = 1,
    this.isDefault = false,
  });

  final int id;
  final String name;
  final double priceDelta;

  /// 1 = a simple on/off toggle; >1 = quantifiable up to this many (a stepper
  /// appears in the picker).
  final int maxQuantity;
  final bool isDefault;

  bool get isQuantifiable => maxQuantity > 1;

  factory ModifierOption.fromJson(Map<String, Object?> json) {
    return ModifierOption(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      priceDelta: double.tryParse(json['price_delta']?.toString() ?? '') ?? 0,
      maxQuantity: (json['max_quantity'] as num?)?.toInt() ?? 1,
      isDefault: json['is_default'] == true,
    );
  }
}

/// A reusable set of per-line choices applied to a product (e.g. "Milk",
/// "Extras"). `minSelect`/`maxSelect` encode required/optional and single/
/// multi-select.
class ModifierGroup {
  const ModifierGroup({
    required this.id,
    required this.name,
    this.minSelect = 0,
    this.maxSelect,
    this.options = const [],
  });

  final int id;
  final String name;
  final int minSelect;
  final int? maxSelect;
  final List<ModifierOption> options;

  bool get isRequired => minSelect >= 1;
  bool get isSingleSelect => maxSelect == 1;

  factory ModifierGroup.fromJson(Map<String, Object?> json) {
    final optionsJson = (json['options'] as List<Object?>?) ?? const [];
    return ModifierGroup(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      minSelect: (json['min_select'] as num?)?.toInt() ?? 0,
      maxSelect: (json['max_select'] as num?)?.toInt(),
      options: optionsJson
          .whereType<Map<String, Object?>>()
          .map(ModifierOption.fromJson)
          .toList(growable: false),
    );
  }
}

class ModifierGroupPage {
  const ModifierGroupPage({required this.groups, required this.hasMore});

  final List<ModifierGroup> groups;
  final bool hasMore;

  factory ModifierGroupPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(ModifierGroup.fromJson)
        .toList(growable: false);
    return ModifierGroupPage(groups: results, hasMore: json['next'] != null);
  }
}

class ModifierOptionDraft {
  const ModifierOptionDraft({
    this.id,
    required this.name,
    this.priceDelta = 0,
    this.maxQuantity = 1,
    this.isDefault = false,
    this.displayOrder = 0,
    this.isActive = true,
  });

  final int? id;
  final String name;
  final double priceDelta;
  final int maxQuantity;
  final bool isDefault;
  final int displayOrder;
  final bool isActive;

  factory ModifierOptionDraft.fromOption(ModifierOption option) {
    return ModifierOptionDraft(
      id: option.id,
      name: option.name,
      priceDelta: option.priceDelta,
      maxQuantity: option.maxQuantity,
      isDefault: option.isDefault,
    );
  }

  Map<String, Object?> toJson() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'price_delta': priceDelta.toStringAsFixed(2),
      'max_quantity': maxQuantity,
      'is_default': isDefault,
      'display_order': displayOrder,
      'is_active': isActive,
    };
  }
}

class ModifierGroupDraft {
  const ModifierGroupDraft({
    required this.name,
    this.minSelect = 0,
    this.maxSelect = 1,
    this.displayOrder = 0,
    this.isActive = true,
    this.options = const [],
  });

  final String name;
  final int minSelect;
  final int? maxSelect;
  final int displayOrder;
  final bool isActive;
  final List<ModifierOptionDraft> options;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'min_select': minSelect,
      'max_select': maxSelect,
      'display_order': displayOrder,
      'is_active': isActive,
      'options': options
          .map((option) => option.toJson())
          .toList(growable: false),
    };
  }
}

/// A modifier selection attached to a cart line. Carries snapshot display data
/// plus the per-unit price delta and the chosen quantity.
class CartLineModifier {
  const CartLineModifier({
    required this.groupId,
    required this.optionId,
    required this.groupName,
    required this.optionName,
    required this.priceDelta,
    required this.quantity,
  });

  final int groupId;
  final int optionId;
  final String groupName;
  final String optionName;
  final double priceDelta;
  final int quantity;

  /// Per-unit contribution of this modifier to the line's unit price.
  double get unitDelta => priceDelta * quantity;

  CartLineModifier copyWith({int? quantity}) {
    return CartLineModifier(
      groupId: groupId,
      optionId: optionId,
      groupName: groupName,
      optionName: optionName,
      priceDelta: priceDelta,
      quantity: quantity ?? this.quantity,
    );
  }

  Map<String, Object?> toCheckoutJson() {
    return {'option': optionId, 'quantity': quantity};
  }
}
