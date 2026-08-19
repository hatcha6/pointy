import '../services/api_session.dart';

/// Which catalog field a duplicate landed on.
enum CatalogIdentityField { sku, barcode }

/// What the duplicate collided with.
enum CatalogIdentityConflictKind {
  /// Another product's variant already carries the code.
  variant,

  /// A packaging (carton/box) barcode already carries it.
  unit,

  /// Two rows of the same request carry it.
  payload,

  /// The unique index rejected the write after the check said the code was
  /// free — someone else claimed it mid-save.
  race,

  unknown,
}

/// Where in the submitted payload the offending value sat, so the form can walk
/// back from the response to the input the user typed it into.
enum CatalogIdentityTarget { variant, defaultVariant, variants, unknown }

/// One duplicate SKU/barcode as the backend described it.
///
/// The catalog write endpoints answer a clash with a `conflicts` list beside
/// the usual DRF field errors; parsing that list is what lets both product
/// dialogs mark the exact input and name the product that already owns the
/// code, instead of showing one red line under the whole form.
class CatalogIdentityConflict {
  const CatalogIdentityConflict({
    required this.field,
    required this.kind,
    required this.target,
    this.value = '',
    this.index,
    this.productId,
    this.productName = '',
    this.variantId,
    this.variantSku = '',
    this.variantName = '',
    this.unitCode = '',
    this.isArchived = false,
    this.message = '',
  });

  factory CatalogIdentityConflict.fromJson(Map<String, Object?> json) {
    return CatalogIdentityConflict(
      field: _fieldFrom(json['field']),
      kind: _kindFrom(json['kind']),
      target: _targetFrom(json['target']),
      value: _text(json['value']),
      index: _int(json['index']),
      productId: _int(json['product_id']),
      productName: _text(json['product_name']),
      variantId: _int(json['variant_id']),
      variantSku: _text(json['variant_sku']),
      variantName: _text(json['variant_name']),
      unitCode: _text(json['unit_code']),
      isArchived: _bool(json['is_archived']),
      message: _text(json['message']),
    );
  }

  final CatalogIdentityField field;
  final CatalogIdentityConflictKind kind;
  final CatalogIdentityTarget target;
  final String value;

  /// Row this landed on when [target] is [CatalogIdentityTarget.variants].
  final int? index;
  final int? productId;
  final String productName;
  final int? variantId;
  final String variantSku;
  final String variantName;
  final String unitCode;
  final bool isArchived;

  /// The backend's own (English) sentence. Kept as a last-resort fallback: the
  /// app renders its own localized text from the structured fields instead.
  final String message;

  /// The owning product as it should read in a message — its name, falling back
  /// to the variant's SKU when the product has no name to show.
  String get ownerLabel {
    final name = productName.trim();
    final variant = variantName.trim();
    if (name.isNotEmpty && variant.isNotEmpty) {
      return '$name - $variant';
    }
    if (name.isNotEmpty) {
      return name;
    }
    if (variantSku.trim().isNotEmpty) {
      return variantSku.trim();
    }
    return '';
  }
}

/// The `conflicts` list carried by a failed catalog write, or empty when the
/// failure was something else (network, permissions, a plain validation error).
List<CatalogIdentityConflict> catalogConflictsFromException(Object error) {
  if (error is! PosApiException || error.statusCode != 400) {
    return const [];
  }
  final decoded = error.decodedBody;
  if (decoded is! Map<String, Object?>) {
    return const [];
  }
  final conflicts = decoded['conflicts'];
  if (conflicts is! List<Object?>) {
    return const [];
  }
  return conflicts
      .whereType<Map<String, Object?>>()
      .map(CatalogIdentityConflict.fromJson)
      .toList(growable: false);
}

/// The answer from `GET /product-variants/identity-check/`: whichever of the
/// two codes is already taken, checked while the user is still typing.
class CatalogIdentityCheck {
  const CatalogIdentityCheck({this.sku, this.barcode});

  factory CatalogIdentityCheck.fromJson(Map<String, Object?> json) {
    return CatalogIdentityCheck(
      sku: _conflictOrNull(json['sku']),
      barcode: _conflictOrNull(json['barcode']),
    );
  }

  final CatalogIdentityConflict? sku;
  final CatalogIdentityConflict? barcode;

  CatalogIdentityConflict? forField(CatalogIdentityField field) {
    return field == CatalogIdentityField.sku ? sku : barcode;
  }
}

CatalogIdentityConflict? _conflictOrNull(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }
  return CatalogIdentityConflict.fromJson(value);
}

CatalogIdentityField _fieldFrom(Object? value) {
  return _text(value) == 'sku'
      ? CatalogIdentityField.sku
      : CatalogIdentityField.barcode;
}

CatalogIdentityConflictKind _kindFrom(Object? value) {
  return switch (_text(value)) {
    'variant' => CatalogIdentityConflictKind.variant,
    'unit' => CatalogIdentityConflictKind.unit,
    'payload' => CatalogIdentityConflictKind.payload,
    'race' => CatalogIdentityConflictKind.race,
    _ => CatalogIdentityConflictKind.unknown,
  };
}

CatalogIdentityTarget _targetFrom(Object? value) {
  return switch (_text(value)) {
    'variant' => CatalogIdentityTarget.variant,
    'default_variant' => CatalogIdentityTarget.defaultVariant,
    'variants' => CatalogIdentityTarget.variants,
    _ => CatalogIdentityTarget.unknown,
  };
}

String _text(Object? value) => value == null ? '' : value.toString();

/// The error path stringifies its payload (DRF coerces validation-detail leaves
/// through `force_str`), while the identity-check probe returns real JSON — so
/// every scalar is parsed from either shape.
int? _int(Object? value) {
  if (value is int) {
    return value;
  }
  final text = _text(value).trim();
  return text.isEmpty ? null : int.tryParse(text);
}

bool _bool(Object? value) {
  if (value is bool) {
    return value;
  }
  return _text(value).toLowerCase() == 'true';
}
