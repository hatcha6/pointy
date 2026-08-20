import 'dart:typed_data';

/// Web has no local spooler — the caller falls back to the browser print path.
Future<CupsSpoolResult> spoolPdfToCups({
  required Uint8List bytes,
  required String? queue,
  required String jobName,
  required double mediaWidthMm,
  required double mediaHeightMm,
  int copies = 1,
}) async {
  return const CupsSpoolResult.unsupported();
}

/// CUPS custom media name for a `width × height` mm page. Kept in the stub so
/// both sides of the conditional import expose the same API.
String cupsCustomMediaName(double widthMm, double heightMm) {
  String fmt(double mm) {
    final rounded = (mm * 100).round() / 100;
    return rounded == rounded.roundToDouble()
        ? '${rounded.round()}'
        : rounded.toString();
  }

  return 'Custom.${fmt(widthMm)}x${fmt(heightMm)}mm';
}

/// Outcome of a `lp` spool attempt. [unsupported] means "this platform has no
/// CUPS" — distinct from a real failure, because the caller then falls back to
/// the printing plugin instead of reporting an error.
class CupsSpoolResult {
  const CupsSpoolResult.spooled() : supported = true, error = null;
  const CupsSpoolResult.failed(String this.error) : supported = true;
  const CupsSpoolResult.unsupported() : supported = false, error = null;

  final bool supported;
  final String? error;

  bool get succeeded => supported && error == null;
}
