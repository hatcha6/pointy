import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/product.dart';
import 'units.dart';

/// A single selectable unit for a product line in POS or purchasing: the base
/// unit plus any additional sellable/purchasable units, each with its resolved
/// per-unit price and base-conversion factor.
class UnitOption {
  const UnitOption({
    required this.code,
    required this.label,
    required this.unitPrice,
    required this.factorToBase,
    required this.allowsFractional,
    required this.isBase,
  });

  final String code;
  final String label;
  final double unitPrice;
  final double factorToBase;
  final bool allowsFractional;
  final bool isBase;

  bool get isMultiple => factorToBase != 1;
}

/// Sellable unit choices for a product, priced against [baseUnitPrice] (the
/// variant's per-base price). The base unit is always first.
List<UnitOption> sellableUnitOptions(
  AppLocalizations l10n,
  Product product,
  double baseUnitPrice,
) {
  return [
    _baseOption(l10n, product, baseUnitPrice),
    for (final unit in product.sellableUnits)
      if (unit.code != product.unit)
        UnitOption(
          code: unit.code,
          label: unit.label,
          unitPrice: unit.resolvedPrice(baseUnitPrice),
          factorToBase: unit.factorToBase,
          allowsFractional: unit.allowsFractional,
          isBase: false,
        ),
  ];
}

/// Purchasable unit choices for a product. Cost is entered per line, so
/// [UnitOption.unitPrice] is unused here.
List<UnitOption> purchasableUnitOptions(
  AppLocalizations l10n,
  Product product,
) {
  return [
    _baseOption(l10n, product, 0),
    for (final unit in product.purchasableUnits)
      if (unit.code != product.unit)
        UnitOption(
          code: unit.code,
          label: unit.label,
          unitPrice: 0,
          factorToBase: unit.factorToBase,
          allowsFractional: unit.allowsFractional,
          isBase: false,
        ),
  ];
}

UnitOption _baseOption(
  AppLocalizations l10n,
  Product product,
  double baseUnitPrice,
) {
  return UnitOption(
    code: product.unit,
    label: unitLabel(l10n, product.unit),
    unitPrice: baseUnitPrice,
    factorToBase: 1,
    allowsFractional: baseUnitAllowsFractional(product.unit),
    isBase: true,
  );
}

/// The option matching [preferredCode] (e.g. the product's default unit), or the
/// base unit when no preference resolves.
UnitOption defaultUnitOption(List<UnitOption> options, String preferredCode) {
  for (final option in options) {
    if (option.code == preferredCode) return option;
  }
  return options.first;
}

/// The product's default sale unit as a [UnitOption], resolved without l10n (the
/// base unit's display label is filled in at render time). Falls back to the
/// base unit when no default is set or it isn't a sellable unit. Used to add a
/// product to the cart at its default unit, with no up-front dialog.
UnitOption defaultSaleUnitOption(Product product, double baseUnitPrice) {
  final code = product.defaultSaleUnit;
  if (code.isNotEmpty && code != product.unit) {
    for (final unit in product.sellableUnits) {
      if (unit.code == code) {
        return UnitOption(
          code: unit.code,
          label: unit.label,
          unitPrice: unit.resolvedPrice(baseUnitPrice),
          factorToBase: unit.factorToBase,
          allowsFractional: unit.allowsFractional,
          isBase: false,
        );
      }
    }
  }
  return UnitOption(
    code: product.unit,
    label: '',
    unitPrice: baseUnitPrice,
    factorToBase: 1,
    allowsFractional: baseUnitAllowsFractional(product.unit),
    isBase: true,
  );
}
