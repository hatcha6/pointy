import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// Unit codes whose quantities may be fractional (weights, volumes, lengths).
/// Used as a client-side approximation for the base unit, which the backend
/// re-validates against the authoritative `UnitOfMeasure.allows_fractional`.
const Set<String> kFractionalUnitCodes = {
  'kg',
  'g',
  'l',
  'ml',
  'ton',
  'm',
  'cm',
};

bool baseUnitAllowsFractional(String unit) =>
    kFractionalUnitCodes.contains(unit);

/// Dimension of a built-in unit code, mirroring the seeded `UnitOfMeasure`
/// table (`backend/apps/catalog/unit_defaults.py`). Packaging units have no
/// universal conversion — their factor is per product — so they are `count`
/// with no reference factor, exactly as the backend seeds them.
const Map<String, String> kBuiltInUnitDimensions = {
  'piece': 'count',
  'pair': 'count',
  'dozen': 'count',
  'pack': 'count',
  'box': 'count',
  'carton': 'count',
  'bag': 'count',
  'kg': 'weight',
  'g': 'weight',
  'ton': 'weight',
  'l': 'volume',
  'ml': 'volume',
  'm': 'length',
  'cm': 'length',
};

/// How many of the dimension's reference unit fit in one of this one (kg for
/// weight, litre for volume, metre for length, piece for count). Null where the
/// backend stores null: a packaging unit whose real factor is per product.
const Map<String, double> kUnitReferenceFactors = {
  'piece': 1,
  'pair': 2,
  'dozen': 12,
  'kg': 1,
  'g': 0.001,
  'ton': 1000,
  'l': 1,
  'ml': 0.001,
  'm': 1,
  'cm': 0.01,
};

/// How many of [productUnit] are in one [valueUnit] — the factor that carries a
/// scale label's measurement into the product's own unit (kg to g is 1000).
///
/// Null when the two cannot be converted between: different dimensions, or a
/// unit whose factor only exists per product. Reported rather than guessed,
/// because silently treating 1.5 kg as 1.5 boxes is the class of wrongness the
/// scale feature exists to remove. Mirrors `conversion_factor` in
/// `backend/apps/catalog/scale_quantity.py`.
double? unitConversionFactor(String valueUnit, String productUnit) {
  final source = valueUnit.trim().toLowerCase();
  final target = productUnit.trim().toLowerCase();
  if (source.isEmpty || target.isEmpty) {
    // One of them is unnamed, so there is no conversion to reason about.
    // Answering 1 here would quietly ring a weight as a count.
    return null;
  }
  if (source == target) {
    return 1;
  }
  final sourceDimension = kBuiltInUnitDimensions[source];
  final targetDimension = kBuiltInUnitDimensions[target];
  if (sourceDimension == null ||
      targetDimension == null ||
      sourceDimension != targetDimension) {
    return null;
  }
  final sourceFactor = kUnitReferenceFactors[source];
  final targetFactor = kUnitReferenceFactors[target];
  if (sourceFactor == null ||
      targetFactor == null ||
      sourceFactor <= 0 ||
      targetFactor <= 0) {
    return null;
  }
  return sourceFactor / targetFactor;
}

/// Arabic label for a built-in unit code. Additional product units carry their
/// own label from the backend; this covers the base unit and legacy callers. An
/// unrecognised (custom) code returns itself.
String unitLabel(AppLocalizations l10n, String unit) {
  return switch (unit) {
    'piece' => l10n.unitPiece,
    'kg' => l10n.unitKilogram,
    'g' => l10n.unitGram,
    'l' => l10n.unitLiter,
    'ml' => l10n.unitMilliliter,
    'ton' => l10n.unitTon,
    'm' => l10n.unitMeter,
    'cm' => l10n.unitCentimeter,
    'dozen' => l10n.unitDozen,
    'pair' => l10n.unitPair,
    'pack' => l10n.unitPack,
    'box' => l10n.unitBox,
    'carton' => l10n.unitCarton,
    'bag' => l10n.unitBag,
    '' => l10n.unitPiece,
    _ => unit,
  };
}

/// Arabic label for a measurement dimension (count/weight/volume/length).
String unitDimensionLabel(AppLocalizations l10n, String dimension) {
  return switch (dimension) {
    'weight' => l10n.unitDimensionWeight,
    'volume' => l10n.unitDimensionVolume,
    'length' => l10n.unitDimensionLength,
    'count' => l10n.unitDimensionCount,
    _ => dimension,
  };
}

/// The label of a dimension's reference unit (count→piece, weight→kg,
/// volume→liter, length→meter), used to explain a unit's reference factor.
String unitDimensionReferenceLabel(AppLocalizations l10n, String dimension) {
  return switch (dimension) {
    'weight' => l10n.unitKilogram,
    'volume' => l10n.unitLiter,
    'length' => l10n.unitMeter,
    _ => l10n.unitPiece,
  };
}

/// "2"، "0.300" — whole numbers stay clean, weights keep three places.
String formatQuantity(double quantity) {
  if (quantity == quantity.roundToDouble()) {
    return quantity.toStringAsFixed(0);
  }
  return quantity.toStringAsFixed(3);
}
