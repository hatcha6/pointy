// compat/win8: camera barcode scanning (mobile_scanner, needs Flutter 3.29) is
// dropped on this build — a Windows-8 cashier till scans with a USB/wedge
// reader (handled by BarcodeScanListener, no package needed). These entry
// points keep their signatures so every caller still compiles, but return null
// (no camera); callers already fall back to the wedge scanner + manual entry.
import 'package:flutter/material.dart';

import '../../data/models/product_variant.dart';

enum CameraBarcodeScannerMode { single, multiple }

class CameraVariantScanEntry {
  const CameraVariantScanEntry({required this.variant, required this.quantity});

  final ProductVariant variant;
  final int quantity;

  CameraVariantScanEntry copyWith({int? quantity}) {
    return CameraVariantScanEntry(
      variant: variant,
      quantity: quantity ?? this.quantity,
    );
  }
}

typedef CameraVariantLookup = Future<ProductVariant?> Function(String barcode);
typedef CameraMissingVariantCreator =
    Future<ProductVariant?> Function(String barcode);

/// compat/win8: no-op — camera scanning is disabled on this build. Returns null
/// (the caller treats it as "nothing scanned" and its USB/wedge path stands).
Future<List<CameraVariantScanEntry>?> showCameraBarcodeScannerSheet(
  BuildContext context, {
  required CameraBarcodeScannerMode mode,
  required CameraVariantLookup lookupVariant,
  CameraMissingVariantCreator? createMissingVariant,
  bool enableQuantity = false,
  int initialQuantity = 1,
}) async => null;
