import 'dart:typed_data';

import 'cups_page_sizes.dart';

export 'cups_page_sizes.dart'
    show
        CupsPageSizes,
        CupsSpoolResult,
        cupsCustomMediaName,
        cupsPageOptions,
        cupsPageSizeMm;

/// Web has no local spooler — the caller falls back to the browser print path.
Future<CupsSpoolResult> spoolPdfToCups({
  required Uint8List bytes,
  required String? queue,
  required String jobName,
  required double mediaWidthMm,
  required double mediaHeightMm,
  int copies = 1,
  bool registerLabelTop = false,
  Duration timeout = const Duration(seconds: 20),
}) async {
  return const CupsSpoolResult.unsupported();
}
