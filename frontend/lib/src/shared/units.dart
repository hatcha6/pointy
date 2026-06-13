import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// Arabic label for a product's metric base unit.
String unitLabel(AppLocalizations l10n, String unit) {
  return switch (unit) {
    'kg' => l10n.unitKilogram,
    'g' => l10n.unitGram,
    'l' => l10n.unitLiter,
    'ml' => l10n.unitMilliliter,
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
