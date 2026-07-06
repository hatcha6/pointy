import 'product_unit.dart';
import 'product_variant.dart';

/// A scanned code resolved against the catalog: the variant it rings up and,
/// when the code is a packaging (unit) barcode — the carton EAN — the product
/// unit it stands for. A null [unit] means a plain variant barcode: one base
/// unit at the variant price.
class BarcodeResolution {
  const BarcodeResolution({required this.variant, this.unit});

  final ProductVariant variant;
  final ProductUnit? unit;

  bool get isUnitBarcode => unit != null;
}
