// compat/win8: camera text-barcode scanning (mobile_scanner) is dropped on this
// build — a Windows-8 till uses a USB/wedge reader. The entry point keeps its
// signature so callers compile, but returns null (no camera). The card-receipt
// dialog that uses it also accepts manual entry.
import 'package:flutter/material.dart';

/// compat/win8: no-op — camera scanning is disabled on this build.
Future<String?> showCameraTextBarcodeScannerSheet(
  BuildContext context, {
  required String title,
}) async => null;
