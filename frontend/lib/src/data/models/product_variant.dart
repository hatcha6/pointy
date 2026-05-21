import 'product.dart';
import 'variant_option_value.dart';

class ProductVariant {
  const ProductVariant({
    required this.id,
    required this.productId,
    required this.sku,
    required this.unitPrice,
    this.productName = '',
    this.productDetail,
    this.name = '',
    this.displayName = '',
    this.fullName = '',
    this.barcode = '',
    this.isActive = true,
    this.isDefault = false,
    this.quantityOnHand = 0,
    this.optionValueIds = const [],
    this.optionValues = const [],
  });

  final int id;
  final int productId;
  final String productName;
  final Product? productDetail;
  final String name;
  final String displayName;
  final String fullName;
  final String sku;
  final String barcode;
  final double unitPrice;
  final bool isActive;
  final bool isDefault;
  final int quantityOnHand;
  final List<int> optionValueIds;
  final List<VariantOptionValue> optionValues;

  String get displayLabel {
    if (fullName.isNotEmpty) {
      return fullName;
    }
    if (displayName.isNotEmpty) {
      return displayName;
    }
    if (name.isNotEmpty && productName.isNotEmpty) {
      return '$productName - $name';
    }
    if (name.isNotEmpty) {
      return name;
    }
    return productName;
  }

  bool get isSellable => isActive && (productDetail?.isActive ?? true);

  factory ProductVariant.fromJson(Map<String, Object?> json) {
    final productDetailJson = json['product_detail'];
    final productDetail = productDetailJson is Map<String, Object?>
        ? Product.fromJson(productDetailJson)
        : null;
    final optionValues = _optionValuesFromJson(json['option_value_details']);
    return ProductVariant(
      id: _intFromJson(json['id']),
      productId: _productIdFromJson(json['product']) ?? productDetail?.id ?? 0,
      productName:
          json['product_name']?.toString() ?? productDetail?.name ?? '',
      productDetail: productDetail,
      name: json['name']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      barcode: json['barcode']?.toString() ?? '',
      unitPrice: _moneyFromJson(json['unit_price']),
      isActive: _boolFromJson(json['is_active'], fallback: true),
      isDefault: _boolFromJson(json['is_default']),
      quantityOnHand: _intFromJson(json['quantity_on_hand']),
      optionValueIds: _optionValueIdsFromJson(
        json['option_values'],
        optionValues,
      ),
      optionValues: optionValues,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'product': productId,
      'name': name,
      'sku': sku,
      'barcode': barcode,
      'unit_price': unitPrice.toStringAsFixed(2),
      'is_active': isActive,
      'is_default': isDefault,
      'option_values': optionValueIds,
    };
  }

  ProductVariant copyWith({int? quantityOnHand}) {
    return ProductVariant(
      id: id,
      productId: productId,
      productName: productName,
      productDetail: productDetail,
      name: name,
      displayName: displayName,
      fullName: fullName,
      sku: sku,
      barcode: barcode,
      unitPrice: unitPrice,
      isActive: isActive,
      isDefault: isDefault,
      quantityOnHand: quantityOnHand ?? this.quantityOnHand,
      optionValueIds: optionValueIds,
      optionValues: optionValues,
    );
  }
}

int? _productIdFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is Map<String, Object?>) {
    return _intFromJson(value['id']);
  }
  if (value == null) {
    return null;
  }
  return int.tryParse(value.toString());
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

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

bool _boolFromJson(Object? value, {bool fallback = false}) {
  if (value is bool) {
    return value;
  }
  if (value == null) {
    return fallback;
  }
  return value.toString() == 'true';
}

List<int> _intListFromJson(Object? value) {
  if (value is List<Object?>) {
    final ids = <int>[];
    for (final item in value) {
      final id = _productIdFromJson(item);
      if (id != null) {
        ids.add(id);
      }
    }
    return ids;
  }
  return const [];
}

List<VariantOptionValue> _optionValuesFromJson(Object? value) {
  if (value is List<Object?>) {
    return value
        .whereType<Map<String, Object?>>()
        .map(VariantOptionValue.fromJson)
        .toList(growable: false);
  }
  return const [];
}

List<int> _optionValueIdsFromJson(
  Object? value,
  List<VariantOptionValue> details,
) {
  final ids = _intListFromJson(value);
  if (ids.isNotEmpty) {
    return ids;
  }
  if (details.isNotEmpty) {
    return details.map((optionValue) => optionValue.id).toList(growable: false);
  }
  return const [];
}
