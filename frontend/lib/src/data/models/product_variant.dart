import 'attachment_summary.dart';
import 'product.dart';
import 'tracking_mode.dart';
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
    this.tracksExpiry = false,
    this.trackingMode = TrackingMode.quantity,
    this.isService = false,
    this.isPrepared = false,
    this.unit = 'piece',
    this.quantityOnHand = 0,
    this.optionValueIds = const [],
    this.optionValues = const [],
    this.primaryImage,
    this.imageAttachments = const [],
    this.priceAmount,
    this.pricingCurrency = '',
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
  final bool tracksExpiry;

  /// Denormalised from the product, because every stock path asks it and the
  /// till already holds the variant. Reading it from here is what makes §11's
  /// promise — a cart with no tracked line pays zero extra queries — true on
  /// the client too.
  final TrackingMode trackingMode;
  final bool isService;
  final bool isPrepared;
  final String unit;
  final double quantityOnHand;
  final List<int> optionValueIds;
  final List<VariantOptionValue> optionValues;
  final AttachmentSummary? primaryImage;
  final List<AttachmentSummary> imageAttachments;

  /// The price in the product's own pricing currency, when it has one. Null for
  /// every product priced in the shop's own currency, which is the default and
  /// what all existing products are.
  ///
  /// [unitPrice] above is ALWAYS the shop's base currency — this is an extra
  /// number beside it, never a reinterpretation of it. That invariant is what
  /// lets carts, totals, discounts and reports stay currency-free.
  final double? priceAmount;

  /// The ISO code [priceAmount] is denominated in; blank when base-priced.
  final String pricingCurrency;

  /// Whether this row is maintained in a foreign price sheet.
  bool get hasForeignPrice => priceAmount != null && pricingCurrency.isNotEmpty;

  String get displayLabel {
    final parent = productLabel;
    final variant = variantLabel;
    final full = fullName.trim();

    if (parent.isNotEmpty &&
        variant.isNotEmpty &&
        _labelWithoutParent(full, parent) == variant) {
      return full;
    }
    if (parent.isNotEmpty && variant.isNotEmpty && variant != parent) {
      return '$parent - $variant';
    }
    if (parent.isNotEmpty) {
      return parent;
    }
    if (variant.isNotEmpty) {
      return variant;
    }
    if (full.isNotEmpty) {
      return full;
    }
    return displayName.trim();
  }

  String get productLabel {
    final explicitProductName = productName.trim();
    if (explicitProductName.isNotEmpty) {
      return explicitProductName;
    }
    final detailName = productDetail?.name.trim() ?? '';
    if (detailName.isNotEmpty) {
      return detailName;
    }
    final full = fullName.trim();
    final parentFromFull = _stripTrailingVariant(full, _variantSuffixes);
    if (parentFromFull.isNotEmpty && parentFromFull != full) {
      return parentFromFull;
    }
    final display = displayName.trim();
    final parentFromDisplay = _stripTrailingVariant(display, _variantSuffixes);
    if (parentFromDisplay.isNotEmpty && parentFromDisplay != display) {
      return parentFromDisplay;
    }
    if (full.isNotEmpty) {
      return full;
    }
    return display;
  }

  String get variantLabel {
    final parent = productLabel;
    final explicitName = name.trim();
    if (explicitName.isNotEmpty) {
      return explicitName;
    }
    final options = _optionValuesLabel;
    if (options.isNotEmpty) {
      return options;
    }
    final display = _labelWithoutParent(displayName.trim(), parent);
    if (display.isNotEmpty) {
      return display;
    }
    final full = _labelWithoutParent(fullName.trim(), parent);
    if (full.isNotEmpty) {
      return full;
    }
    return '';
  }

  String get pickerLabel {
    final label = variantLabel;
    return label.isEmpty ? productLabel : label;
  }

  bool get isSellable => isActive && (productDetail?.isActive ?? true);

  String get _optionValuesLabel {
    final labels = [
      for (final value in optionValues)
        if (value.displayLabel.trim().isNotEmpty) value.displayLabel.trim(),
    ];
    return labels.join(' / ');
  }

  List<String> get _variantSuffixes {
    return [
      name.trim(),
      _optionValuesLabel,
      displayName.trim(),
    ].where((label) => label.isNotEmpty).toList(growable: false);
  }

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
      tracksExpiry: _boolFromJson(
        json['tracks_expiry'],
        fallback: productDetail?.tracksExpiry ?? false,
      ),
      trackingMode: json.containsKey('tracking_mode')
          ? TrackingMode.fromWire(json['tracking_mode'])
          : productDetail?.trackingMode ?? TrackingMode.quantity,
      isService: json['is_service'] == true,
      isPrepared: json['is_prepared'] == true,
      unit: json['unit']?.toString() ?? 'piece',
      quantityOnHand: _stockQuantityFromJson(json['quantity_on_hand']),
      optionValueIds: _optionValueIdsFromJson(
        json['option_values'],
        optionValues,
      ),
      optionValues: optionValues,
      primaryImage: _primaryImageFromJson(json),
      imageAttachments: _imageAttachmentsFromJson(json),
      priceAmount: _optionalMoneyFromJson(json['price_amount']),
      // The currency lives on the parent product (it describes the price sheet,
      // not the row), so it is read from the embedded detail when present.
      pricingCurrency:
          productDetail?.pricingCurrency ??
          json['pricing_currency']?.toString() ??
          '',
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

  /// Full-fidelity serialization for local persistence (the POS cart and the
  /// purchase draft), as opposed to [toJson] which is the lossy API write shape.
  /// Round-trips through [fromJson]. The heavy product/option/image graph is
  /// intentionally omitted — the denormalized name fields are enough to render
  /// and check out a restored line, and the backend re-validates at submit.
  Map<String, Object?> toCartJson() {
    return {
      'id': id,
      'product': productId,
      'product_name': productName,
      'name': name,
      'display_name': displayName,
      'full_name': fullName,
      'sku': sku,
      'barcode': barcode,
      'unit_price': unitPrice.toStringAsFixed(2),
      'is_active': isActive,
      'is_default': isDefault,
      'tracks_expiry': tracksExpiry,
      'tracking_mode': trackingMode.wire,
      'is_service': isService,
      'is_prepared': isPrepared,
      'unit': unit,
      'quantity_on_hand': quantityOnHand,
      'option_values': optionValueIds,
      'product_detail': productDetail?.toCartJson(),
    };
  }

  ProductVariant copyWith({
    double? quantityOnHand,
    Product? productDetail,
    double? unitPrice,
  }) {
    return ProductVariant(
      id: id,
      productId: productId,
      productName: productName,
      productDetail: productDetail ?? this.productDetail,
      name: name,
      displayName: displayName,
      fullName: fullName,
      sku: sku,
      barcode: barcode,
      unitPrice: unitPrice ?? this.unitPrice,
      isActive: isActive,
      isDefault: isDefault,
      tracksExpiry: tracksExpiry,
      trackingMode: trackingMode,
      isService: isService,
      isPrepared: isPrepared,
      unit: unit,
      quantityOnHand: quantityOnHand ?? this.quantityOnHand,
      optionValueIds: optionValueIds,
      optionValues: optionValues,
      primaryImage: primaryImage,
      imageAttachments: imageAttachments,
    );
  }
}

AttachmentSummary? _primaryImageFromJson(Map<String, Object?> json) {
  final primaryImage = json['primary_image'];
  if (primaryImage is Map<String, Object?>) {
    return AttachmentSummary.fromJson(primaryImage);
  }
  return null;
}

List<AttachmentSummary> _imageAttachmentsFromJson(Map<String, Object?> json) {
  final attachments = json['image_attachments'];
  if (attachments is List<Object?>) {
    return attachments
        .whereType<Map<String, Object?>>()
        .map(AttachmentSummary.fromJson)
        .toList(growable: false);
  }
  return const [];
}

String _labelWithoutParent(String label, String parent) {
  if (label.isEmpty) {
    return '';
  }
  if (parent.isEmpty) {
    return label;
  }
  if (label == parent) {
    return '';
  }
  final prefix = '$parent - ';
  if (label.startsWith(prefix)) {
    return label.substring(prefix.length).trim();
  }
  return label;
}

String _stripTrailingVariant(String label, List<String> variants) {
  for (final variant in variants) {
    final suffix = ' - $variant';
    if (label.endsWith(suffix)) {
      return label.substring(0, label.length - suffix.length).trim();
    }
  }
  return label;
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

double _stockQuantityFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

double? _optionalMoneyFromJson(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return double.tryParse(raw);
}
