import 'dart:io';
import 'dart:typed_data';

/// Spools a PDF straight to CUPS with an **exact** media size.
///
/// The printing plugin can't express label media on Linux or macOS: its Linux
/// job builder ignores the page size entirely (`gtk_page_setup_new()` → the
/// locale default, i.e. A4) and its macOS one flags any page wider than tall as
/// landscape. Either way the driver falls back to the queue's own page — for a
/// label/receipt printer that is typically an 80 × 297 mm roll page, so a single
/// 40 × 25 mm sticker is rotated to fit and followed by ~270 mm of blank feed:
/// the "one label printed, then a handful skipped" symptom.
///
/// `lp` takes the media size per job (`-o media=Custom.40x25mm`), which pins the
/// page to the die-cut sticker: no fitting, no rotation, no wasted labels.
Future<CupsSpoolResult> spoolPdfToCups({
  required Uint8List bytes,
  required String? queue,
  required String jobName,
  required double mediaWidthMm,
  required double mediaHeightMm,
  int copies = 1,
}) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return const CupsSpoolResult.unsupported();
  }
  if (bytes.isEmpty || mediaWidthMm <= 0 || mediaHeightMm <= 0) {
    return const CupsSpoolResult.unsupported();
  }

  Directory? workDir;
  try {
    workDir = await Directory.systemTemp.createTemp('pointy-label-');
    final file = File('${workDir.path}/$jobName.pdf');
    await file.writeAsBytes(bytes, flush: true);

    final result = await Process.run('lp', [
      if (queue != null && queue.trim().isNotEmpty) ...['-d', queue.trim()],
      '-t', jobName,
      '-n', '${copies < 1 ? 1 : copies}',
      // The whole point of this path: the sticker as loaded in the printer.
      '-o', 'media=${cupsCustomMediaName(mediaWidthMm, mediaHeightMm)}',
      // Portrait, unscaled: the page already *is* the media, so any auto-rotate
      // or fit-to-page the filter chain might apply would only distort it.
      '-o', 'orientation-requested=3',
      '-o', 'print-scaling=none',
      file.path,
    ]).timeout(const Duration(seconds: 20));

    if (result.exitCode != 0) {
      final message = '${result.stderr}'.trim().isEmpty
          ? '${result.stdout}'.trim()
          : '${result.stderr}'.trim();
      return CupsSpoolResult.failed(
        message.isEmpty ? 'lp exited with ${result.exitCode}' : message,
      );
    }
    return const CupsSpoolResult.spooled();
  } on ProcessException {
    // No `lp` on this box (CUPS client not installed) — let the caller fall
    // back to the printing plugin.
    return const CupsSpoolResult.unsupported();
  } on Object catch (error) {
    return CupsSpoolResult.failed('$error');
  } finally {
    try {
      await workDir?.delete(recursive: true);
    } on Object {
      // Best effort: a leftover temp file must never fail a print.
    }
  }
}

/// CUPS custom media name for a `width × height` mm page. Whole millimetres
/// print as integers (`Custom.40x25mm`) — the form every CUPS version parses.
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
