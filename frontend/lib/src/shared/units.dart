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
