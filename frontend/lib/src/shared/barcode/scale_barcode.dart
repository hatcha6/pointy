/// Reading a label a weighing scale printed.
///
/// The mirror of `backend/apps/catalog/scale_barcodes.py`, digit for digit. A
/// price-computing scale prints an in-store prefix, the item's short code, and
/// a value — the weight it measured, or the money that weight costs — and
/// nothing in the thirteen digits says which of the two it is. So neither side
/// guesses: the shop declares its layouts, the till matches against them in
/// order, and a code no rule describes is not a scale label at all.
///
/// Any change here belongs in the Python module in the same commit; the shared
/// vectors in `test/shared/barcode/scale_barcode_test.dart` exist to catch the
/// commit where that did not happen.
library;

/// Pattern alphabet. One character per digit position.
const String kScaleItemChar = 'I';
const String kScaleValueChar = 'V';
const String kScaleCheckChar = 'C';
const String kScaleIgnoreChar = 'X';

/// What a rule's embedded digits mean. Never inferred — always configured.
enum ScaleValueKind {
  weight('weight'),
  price('price'),
  count('count');

  const ScaleValueKind(this.wireName);

  final String wireName;

  static ScaleValueKind fromWire(String? value) {
    return ScaleValueKind.values.firstWhere(
      (kind) => kind.wireName == value,
      orElse: () => ScaleValueKind.weight,
    );
  }
}

/// One label layout, as configured by the shop.
class ScaleBarcodeRule {
  const ScaleBarcodeRule({
    required this.pattern,
    this.valueKind = ScaleValueKind.weight,
    this.valueDecimals = 3,
    this.valueUnit = 'kg',
    this.requireCheckDigit = true,
    this.name = '',
    this.id,
    this.isActive = true,
    this.sequence = 0,
  });

  factory ScaleBarcodeRule.fromJson(Map<String, dynamic> json) {
    return ScaleBarcodeRule(
      id: json['id'] is int ? json['id'] as int : null,
      name: json['name']?.toString() ?? '',
      pattern: json['pattern']?.toString() ?? '',
      valueKind: ScaleValueKind.fromWire(json['value_kind']?.toString()),
      valueDecimals:
          int.tryParse(json['value_decimals']?.toString() ?? '') ?? 3,
      valueUnit: json['value_unit']?.toString() ?? 'kg',
      requireCheckDigit: json['require_check_digit'] != false,
      isActive: json['is_active'] != false,
      sequence: int.tryParse(json['sequence']?.toString() ?? '') ?? 0,
    );
  }

  final int? id;
  final String name;
  final String pattern;
  final ScaleValueKind valueKind;
  final int valueDecimals;
  final String valueUnit;
  final bool requireCheckDigit;
  final bool isActive;
  final int sequence;

  int get length => pattern.length;

  bool get hasCheckDigit => pattern.contains(kScaleCheckChar);

  /// How many digits the rule pins down — its prefix, effectively.
  int get literalCount =>
      pattern.split('').where((char) => _isDigit(char)).length;

  /// Whether the pattern could describe a real label at all.
  bool get isUsable {
    if (pattern.isEmpty || !_isDigit(pattern[0])) {
      return false;
    }
    if (!pattern.contains(kScaleItemChar) ||
        !pattern.contains(kScaleValueChar)) {
      return false;
    }
    final checks = kScaleCheckChar.allMatches(pattern).length;
    if (checks > 1 || (checks == 1 && !pattern.endsWith(kScaleCheckChar))) {
      return false;
    }
    for (final char in pattern.split('')) {
      if (!_isDigit(char) &&
          char != kScaleItemChar &&
          char != kScaleValueChar &&
          char != kScaleCheckChar &&
          char != kScaleIgnoreChar) {
        return false;
      }
    }
    return valueDecimals >= 0 &&
        valueDecimals <= kScaleValueChar.allMatches(pattern).length;
  }
}

/// A scanned code, understood.
class ScaleBarcodeMatch {
  const ScaleBarcodeMatch({
    required this.raw,
    required this.rule,
    required this.itemCode,
    required this.value,
    required this.baseCode,
  });

  final String raw;
  final ScaleBarcodeRule rule;
  final String itemCode;

  /// The embedded number, already scaled by the rule's decimals: kilograms,
  /// money, or a count depending on [ScaleBarcodeRule.valueKind].
  final double value;

  /// The code with its value digits zeroed and the check digit recomputed —
  /// what a shop that prints its own shelf labels stores on the product.
  final String baseCode;

  ScaleValueKind get valueKind => rule.valueKind;

  /// A label printed without weighing, or the shop's own shelf label. Either
  /// way there is no quantity in it, only an identity.
  bool get isZeroValue => value == 0;

  /// Codes to try against the catalog, most specific first.
  List<String> get candidateBarcodes {
    final trimmed = itemCode.replaceFirst(RegExp(r'^0+'), '');
    final lastItem = rule.pattern.lastIndexOf(kScaleItemChar);
    final candidates = <String>[
      baseCode,
      if (lastItem >= 0) raw.substring(0, lastItem + 1),
      itemCode,
      if (trimmed.isNotEmpty && trimmed != itemCode) trimmed,
    ];
    final seen = <String>[];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && !seen.contains(candidate)) {
        seen.add(candidate);
      }
    }
    return seen;
  }
}

/// First rule that describes [raw] wins; null when none does.
ScaleBarcodeMatch? parseScaleBarcode(
  String? raw,
  List<ScaleBarcodeRule> rules,
) {
  final code = (raw ?? '').trim();
  if (code.isEmpty || !_isAllDigits(code)) {
    return null;
  }
  for (final rule in rules) {
    final match = _matchRule(code, rule);
    if (match != null) {
      return match;
    }
  }
  return null;
}

/// Configured rules in the order the till must try them: most specific first.
///
/// Specificity beats [ScaleBarcodeRule.sequence] on purpose — a shop's first
/// rule is the broad one its old scale prints, and the day it adds a second
/// scale on its own prefix, the narrow rule has to win or it would never fire.
List<ScaleBarcodeRule> orderScaleRules(Iterable<ScaleBarcodeRule> rules) {
  final usable = rules.where((rule) => rule.isActive && rule.isUsable).toList();
  usable.sort((a, b) {
    final bySpecificity = b.literalCount.compareTo(a.literalCount);
    if (bySpecificity != 0) {
      return bySpecificity;
    }
    final bySequence = a.sequence.compareTo(b.sequence);
    if (bySequence != 0) {
      return bySequence;
    }
    return (a.id ?? 0).compareTo(b.id ?? 0);
  });
  return usable;
}

ScaleBarcodeMatch? _matchRule(String code, ScaleBarcodeRule rule) {
  if (!rule.isUsable || code.length != rule.length) {
    return null;
  }
  final itemDigits = StringBuffer();
  final valueDigits = StringBuffer();
  for (var index = 0; index < rule.pattern.length; index++) {
    final patternChar = rule.pattern[index];
    final digit = code[index];
    if (_isDigit(patternChar)) {
      if (patternChar != digit) {
        return null;
      }
    } else if (patternChar == kScaleItemChar) {
      itemDigits.write(digit);
    } else if (patternChar == kScaleValueChar) {
      valueDigits.write(digit);
    }
  }
  if (rule.hasCheckDigit &&
      rule.requireCheckDigit &&
      !hasValidCheckDigit(code)) {
    return null;
  }
  final raw = int.tryParse(valueDigits.toString());
  if (raw == null) {
    return null;
  }
  return ScaleBarcodeMatch(
    raw: code,
    rule: rule,
    itemCode: itemDigits.toString(),
    value: raw / _pow10(rule.valueDecimals),
    baseCode: _baseCode(code, rule),
  );
}

String _baseCode(String code, ScaleBarcodeRule rule) {
  final masked = StringBuffer();
  for (var index = 0; index < rule.pattern.length; index++) {
    masked.write(rule.pattern[index] == kScaleValueChar ? '0' : code[index]);
  }
  var result = masked.toString();
  if (rule.hasCheckDigit) {
    final body = result.substring(0, result.length - 1);
    result = '$body${gs1CheckDigit(body)}';
  }
  return result;
}

/// GS1 modulo-10 check digit over the data part of a code.
///
/// Weights alternate 3 and 1 from the rightmost data digit, which is what makes
/// one function correct for EAN-13 and EAN-8 without either being special-cased.
String gs1CheckDigit(String digits) {
  var total = 0;
  final length = digits.length;
  for (var index = 0; index < length; index++) {
    final digit = digits.codeUnitAt(index) - 0x30;
    if (digit < 0 || digit > 9) {
      return '';
    }
    total += digit * ((length - index) % 2 == 1 ? 3 : 1);
  }
  return (((10 - total % 10) % 10)).toString();
}

bool hasValidCheckDigit(String code) {
  if (code.isEmpty || !_isAllDigits(code)) {
    return false;
  }
  return gs1CheckDigit(code.substring(0, code.length - 1)) ==
      code[code.length - 1];
}

/// Kept for the EAN-13 callers that predate the rule engine.
bool isValidEan13(String code) => code.length == 13 && hasValidCheckDigit(code);

/// The code a scale following [rule] would print for this item and value.
/// The inverse of [parseScaleBarcode]; used for worked examples and by tests.
String buildScaleCode(ScaleBarcodeRule rule, String itemCode, double value) {
  final itemSlots = kScaleItemChar.allMatches(rule.pattern).length;
  final valueSlots = kScaleValueChar.allMatches(rule.pattern).length;
  final item = itemCode.trim().padLeft(itemSlots, '0');
  final scaled = (value * _pow10(rule.valueDecimals)).round();
  final digits = scaled.toString();
  if (item.length > itemSlots || digits.length > valueSlots || scaled < 0) {
    return '';
  }
  final valueText = digits.padLeft(valueSlots, '0');
  var itemIndex = 0;
  var valueIndex = 0;
  final out = StringBuffer();
  for (final char in rule.pattern.split('')) {
    if (_isDigit(char)) {
      out.write(char);
    } else if (char == kScaleItemChar) {
      out.write(item[itemIndex++]);
    } else if (char == kScaleValueChar) {
      out.write(valueText[valueIndex++]);
    } else if (char == kScaleIgnoreChar) {
      out.write('0');
    } else {
      out.write(gs1CheckDigit(out.toString()));
    }
  }
  return out.toString();
}

// --- What the value means for a line ----------------------------------------

/// The product is priced at zero, so a money label cannot be divided into a
/// quantity.
const String kScaleWarnNoUnitPrice = 'no_unit_price';

/// The product is counted, not measured, so an embedded weight is not a
/// quantity for it.
const String kScaleWarnNotFractional = 'not_fractional';

/// The label's unit and the product's unit are not the same kind of thing.
const String kScaleWarnUnitMismatch = 'unit_mismatch';

/// The derived quantity does not price back to exactly what the sticker says.
const String kScaleWarnRoundingDrift = 'rounding_drift';

/// The quantity a scale label rings, and what was odd about getting there.
class ScaleQuantity {
  const ScaleQuantity({
    required this.quantity,
    this.warning = '',
    this.labelTotal,
    this.rungTotal,
  });

  final double quantity;
  final String warning;

  /// What the sticker says the customer owes, when the label carries money.
  final double? labelTotal;

  /// What the till will charge for [quantity] — equal to [labelTotal] unless
  /// rounding got in the way.
  final double? rungTotal;

  bool get hasWarning => warning.isNotEmpty;

  double get drift {
    final label = labelTotal;
    final rung = rungTotal;
    if (label == null || rung == null) {
      return 0;
    }
    return rung - label;
  }
}

/// How many of the product's sale unit this label is worth.
///
/// [unitFactor] converts one of the rule's unit into one of the product's unit
/// (kg to g is 1000); null means the two cannot be converted between, which is
/// a configuration mistake and is reported rather than papered over.
ScaleQuantity resolveScaleQuantity(
  ScaleBarcodeMatch match, {
  required double unitPrice,
  required bool allowsFractional,
  double? unitFactor = 1,
}) {
  if (match.isZeroValue) {
    return const ScaleQuantity(quantity: 1);
  }
  switch (match.valueKind) {
    case ScaleValueKind.count:
      return ScaleQuantity(quantity: _quantizeQuantity(match.value));
    case ScaleValueKind.weight:
      if (!allowsFractional) {
        return const ScaleQuantity(
          quantity: 1,
          warning: kScaleWarnNotFractional,
        );
      }
      if (unitFactor == null || unitFactor <= 0) {
        return const ScaleQuantity(
          quantity: 1,
          warning: kScaleWarnUnitMismatch,
        );
      }
      return ScaleQuantity(
        quantity: _quantizeQuantity(match.value * unitFactor),
      );
    case ScaleValueKind.price:
      final labelTotal = _roundMoney(match.value);
      if (unitPrice <= 0) {
        return ScaleQuantity(
          quantity: 1,
          warning: kScaleWarnNoUnitPrice,
          labelTotal: labelTotal,
        );
      }
      // Nearest quantity, tie broken downwards: a sticker that cannot be hit
      // exactly at three decimals is out by a step either way, and going down
      // means the customer is never charged more than the label they were shown.
      var quantity = _quantizeQuantity(labelTotal / unitPrice, tieDown: true);
      if (quantity <= 0) {
        quantity = 0.001;
      }
      final rungTotal = _roundMoney(unitPrice * quantity);
      return ScaleQuantity(
        quantity: quantity,
        warning: rungTotal == labelTotal ? '' : kScaleWarnRoundingDrift,
        labelTotal: labelTotal,
        rungTotal: rungTotal,
      );
  }
}

// Quantities are stored to three decimals and money to two, on both sides of
// the wire. Rounding here is done in scaled-integer space with a tolerance,
// because a double that should be exactly .5 often is not, and a tie that
// resolved differently here than on the server would put a different number on
// the screen than on the receipt.
const double _tieEpsilon = 1e-9;

double _quantizeQuantity(double value, {bool tieDown = false}) {
  return _roundScaled(value, 1000, tieDown: tieDown);
}

double _roundMoney(double value) => _roundScaled(value, 100);

double _roundScaled(double value, int scale, {bool tieDown = false}) {
  final scaled = value * scale;
  final floor = scaled.floorToDouble();
  final fraction = scaled - floor;
  double units;
  if ((fraction - 0.5).abs() < _tieEpsilon) {
    // Exactly between two steps: down for a price-derived quantity, and
    // half-to-even for money, which is what Decimal.quantize does server-side.
    units = tieDown ? floor : (floor % 2 == 0 ? floor : floor + 1);
  } else if (fraction > 0.5) {
    units = floor + 1;
  } else {
    units = floor;
  }
  return units / scale;
}

double _pow10(int exponent) {
  var result = 1.0;
  for (var index = 0; index < exponent; index++) {
    result *= 10;
  }
  return result;
}

bool _isDigit(String char) {
  if (char.length != 1) {
    return false;
  }
  final code = char.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}

bool _isAllDigits(String value) {
  if (value.isEmpty) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    if (code < 0x30 || code > 0x39) {
      return false;
    }
  }
  return true;
}
