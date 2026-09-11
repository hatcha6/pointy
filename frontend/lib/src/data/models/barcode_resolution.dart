import '../../shared/barcode/scale_barcode.dart';
import 'product_unit.dart';
import 'product_variant.dart';

/// A scanned code resolved against the catalog: the variant it rings up and,
/// when the code is a packaging (unit) barcode — the carton EAN — the product
/// unit it stands for. A null [unit] means a plain variant barcode: one base
/// unit at the variant price.
///
/// [scaleMatch] is set when the code was a weighing scale's own label. It is
/// read once, here, rather than parsed again by every caller: two parses of the
/// same sticker is two chances to disagree about what it says.
class BarcodeResolution {
  const BarcodeResolution({required this.variant, this.unit, this.scaleMatch});

  final ProductVariant variant;
  final ProductUnit? unit;
  final ScaleBarcodeMatch? scaleMatch;

  bool get isUnitBarcode => unit != null;

  bool get isScaleLabel => scaleMatch != null;

  BarcodeResolution copyWith({ScaleBarcodeMatch? scaleMatch}) {
    return BarcodeResolution(
      variant: variant,
      unit: unit,
      scaleMatch: scaleMatch ?? this.scaleMatch,
    );
  }
}
