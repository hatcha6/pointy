import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../printing/print_qr_code.dart';

/// Dots per module for [code] drawn inside [available] points: the biggest of
/// 10 down to 4 printer dots at [dpi] that fits, quiet zone included, or 0
/// when even 4 do not. Big modules are what survive a worn thermal head: a
/// dead heating element leaves a one-dot white line down the slip, and a
/// module many dots wide still reads as black on either side of it.
int pdfQrModuleDots(PrintQrCode code, double available, {int dpi = 203}) {
  final dotsPerPoint = dpi / PdfPageFormat.inch;
  final dots =
      (available * dotsPerPoint).floor() ~/ code.moduleCountWithQuietZone;
  if (dots < 4) {
    return 0;
  }
  return dots > 10 ? 10 : dots;
}

/// A QR code drawn on whole printer dots, its quiet zone included.
///
/// A PDF receipt reaches a thermal head through its driver, which can only
/// round a module to the nearest dot: a 2.9 pt module at 203 dpi prints as a
/// mix of 8- and 9-dot modules with grey, dithered edges. Here every module is
/// [moduleDots] dots and the symbol's corner is pinned to the dot grid in page
/// coordinates, as [PointyPdfCode128] pins its bars, so there is nothing left
/// to round. On a page printed at 300 or 600 dpi it is simply a crisp square.
///
/// Dark modules are one filled path, runs merged, so no hairline seam can
/// open between two neighbours when the page is rasterised.
class PointyPdfQrCode extends pw.Widget {
  PointyPdfQrCode(
    this.code, {
    required this.moduleDots,
    this.dpi = 203,
    this.color = PdfColors.black,
  });

  final PrintQrCode code;
  final int moduleDots;
  final int dpi;
  final PdfColor color;

  double get _module => moduleDots * PdfPageFormat.inch / dpi;

  /// Width and height, quiet zone included.
  double get extent => code.moduleCountWithQuietZone * _module;

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    box = PdfRect.fromPoints(
      PdfPoint.zero,
      constraints.constrain(PdfPoint(extent, extent)),
    );
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final rect = box;
    if (rect == null) {
      return;
    }
    final module = _module;
    final quiet = PrintQrCode.quietZone * module;
    var left = rect.left + quiet;
    var bottom = rect.bottom + quiet;

    // Widgets paint in their parent's space, so the dot grid is found through
    // the canvas transform. Only an upright, unscaled placement maps onto it;
    // anything else keeps even modules that simply cannot be pinned.
    final matrix = context.canvas.getTransform();
    bool near(double value, double target) => (value - target).abs() < 1e-6;
    if (near(matrix.entry(0, 0), 1) &&
        near(matrix.entry(1, 1), 1) &&
        near(matrix.entry(0, 1), 0) &&
        near(matrix.entry(1, 0), 0)) {
      final dotsPerPoint = dpi / PdfPageFormat.inch;
      double snap(double local, double origin) =>
          ((origin + local) * dotsPerPoint).roundToDouble() / dotsPerPoint -
          origin;
      left = snap(left, matrix.entry(0, 3));
      bottom = snap(bottom, matrix.entry(1, 3));
    }

    final count = code.moduleCount;
    for (var row = 0; row < count; row++) {
      // PDF space runs upward: row 0 is the top of the symbol.
      final y = bottom + (count - 1 - row) * module;
      var column = 0;
      while (column < count) {
        if (!code.isDark(row, column)) {
          column++;
          continue;
        }
        final start = column;
        while (column < count && code.isDark(row, column)) {
          column++;
        }
        context.canvas.drawRect(
          left + start * module,
          y,
          (column - start) * module,
          module,
        );
      }
    }
    context.canvas
      ..setFillColor(color)
      ..fillPath();
  }
}
