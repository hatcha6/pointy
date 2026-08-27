import '../services/api_session.dart';

/// Why a purchase cost looked wrong.
enum PurchaseCostWarningKind {
  /// The cost is above what the item sells for, so every sale loses money.
  aboveSalePrice,

  /// The cost is a large multiple of what this item last cost.
  costSpike,

  unknown,
}

/// One suspicious purchase cost, as the backend described it.
///
/// The write endpoints answer an implausible cost with a `cost_warnings` list
/// beside the usual DRF field errors. Parsing it is what lets the app say *why*
/// — "you are recording 130.00 for something that sells for 1.00" reads as an
/// obvious mistake, where a red line under the form reads as the software being
/// difficult.
///
/// [blocking] says whether confirming is even on offer. A cash purchase from the
/// sell screen is entered by a cashier who cannot judge the number and has no
/// permission to override it, so that path refuses outright; offering a confirm
/// button there would promise something that does not happen.
class PurchaseCostWarning {
  const PurchaseCostWarning({
    required this.kind,
    required this.blocking,
    this.index,
    this.variantId,
    this.productName = '',
    this.baseUnitCost = '',
    this.reference = '',
    this.ratio = '',
    this.message = '',
  });

  factory PurchaseCostWarning.fromJson(Map<String, Object?> json) {
    return PurchaseCostWarning(
      kind: _kindFrom(json['kind']),
      blocking: _text(json['blocking']).toLowerCase() == 'true',
      index: _int(json['index']),
      variantId: _int(json['variant_id']),
      productName: _text(json['product_name']),
      baseUnitCost: _text(json['base_unit_cost']),
      reference: _text(json['reference']),
      ratio: _text(json['ratio']),
      message: _text(json['message']),
    );
  }

  final PurchaseCostWarningKind kind;
  final bool blocking;

  /// Row this landed on, so the form can mark the exact line.
  final int? index;
  final int? variantId;
  final String productName;

  /// The cost as recorded, per base unit — the only scale on which a cost and a
  /// price are comparable (a 162-per-carton egg line is 0.45 an egg).
  final String baseUnitCost;

  /// What it was measured against: the selling price, or the previous cost.
  final String reference;
  final String ratio;

  /// The backend's own sentence, already localized. Shown as-is: it carries the
  /// two numbers that make the mistake obvious.
  final String message;
}

/// The `cost_warnings` list carried by a rejected purchase write, or empty when
/// the failure was something else.
List<PurchaseCostWarning> purchaseCostWarningsFromException(Object error) {
  if (error is! PosApiException || error.statusCode != 400) {
    return const [];
  }
  final decoded = error.decodedBody;
  if (decoded is! Map<String, Object?>) {
    return const [];
  }
  final warnings = decoded['cost_warnings'];
  if (warnings is! List<Object?>) {
    return const [];
  }
  return warnings
      .whereType<Map<String, Object?>>()
      .map(PurchaseCostWarning.fromJson)
      .toList(growable: false);
}

/// Whether these warnings can be confirmed past, or only corrected.
bool purchaseCostWarningsAreBlocking(List<PurchaseCostWarning> warnings) {
  return warnings.any((warning) => warning.blocking);
}

PurchaseCostWarningKind _kindFrom(Object? value) {
  return switch (value?.toString()) {
    'above_sale_price' => PurchaseCostWarningKind.aboveSalePrice,
    'cost_spike' => PurchaseCostWarningKind.costSpike,
    _ => PurchaseCostWarningKind.unknown,
  };
}

String _text(Object? value) => value?.toString() ?? '';

int? _int(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '');
}
