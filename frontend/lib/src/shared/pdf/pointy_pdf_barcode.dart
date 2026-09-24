import 'dart:math' as math;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Number of Code 128 modules [data] encodes to, measured off a trial layout:
/// the narrowest bar in any 1D symbology is exactly one module wide, so the
/// probe width divided by that bar gives the module count. (The `Barcode1D`
/// class that would answer directly isn't exported by the barcode package.)
/// Zero for data the symbology cannot express.
int pdfCode128ModuleCount(String data) {
  const probeWidth = 1000.0;
  try {
    final bars = pw.Barcode.code128()
        .make(data, width: probeWidth, height: 10)
        .whereType<pw.BarcodeBar>()
        .where((bar) => bar.width > 0);
    if (bars.isEmpty) {
      return 0;
    }
    final module = bars.map((bar) => bar.width).reduce(math.min);
    return module <= 0 ? 0 : (probeWidth / module).round();
  } on Object {
    // Data this symbology can't express: let the widget report it as it will.
    return 0;
  }
}

/// The widest symbol, no wider than [available] points, whose modules are a
/// whole number of printer dots at [dpi].
double pdfSnappedBarcodeWidth(int modules, double available, {int dpi = 203}) {
  if (modules <= 0) {
    return available;
  }
  final dotsPerPoint = (dpi <= 0 ? 203 : dpi) / PdfPageFormat.inch;
  final dotsPerModule = available * dotsPerPoint / modules;
  if (dotsPerModule < 2) {
    // Dense data on a small label: there is no room to round down without
    // throwing away most of the symbol (rounding 1.8 dots down to 1 halves
    // it), and a sub-2-dot module is at the head's limit anyway. Use every
    // millimetre there is instead.
    return available;
  }
  return modules * dotsPerModule.floorToDouble() / dotsPerPoint;
}

/// Code 128 bars drawn on whole printer dots.
///
/// [pw.BarcodeWidget] places bars at whatever fractional point the layout lands
/// on, and a 203-dpi head can only round that to the nearest dot — so a nominal
/// 2-dot module prints as a mix of 1-, 2- and 3-dot bars, which is what a
/// scanner reads as a fuzzy, hard-to-decode symbol. Bars here are snapped to the
/// device grid in page coordinates: every module comes out the same whole number
/// of dots wide. (Under a rotation or a scale-down the canvas transform moves
/// the grid, and this degrades to the same fractional placement as before.)
class PointyPdfCode128 extends pw.Widget {
  PointyPdfCode128({
    required this.data,
    required this.modules,
    required this.dpi,
    required this.color,
  });

  final String data;
  final int modules;
  final int dpi;
  final PdfColor color;

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    box = PdfRect.fromPoints(PdfPoint.zero, constraints.biggest);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final rect = box;
    if (rect == null || modules <= 0) {
      return;
    }
    final dotsPerPoint = dpi / PdfPageFormat.inch;
    final dotsPerModule = rect.width * dotsPerPoint / modules;
    // Below two dots a module can't be rounded to the grid without losing most
    // of the symbol, so a dense code on a small label keeps its exact width and
    // lets the head round each bar (see pdfSnappedBarcodeWidth).
    final snapToDots = dotsPerModule >= 2;
    final moduleWidth = snapToDots
        ? dotsPerModule.floorToDouble() / dotsPerPoint
        : rect.width / modules;

    // Widgets paint in their parent's coordinate space, so the printer's dot
    // grid has to be found through the canvas transform. Follow the image of
    // our own x axis: upright or quarter-turned it still lands on a page axis
    // (only the sign and which axis change), and the bars can be pinned to whole
    // dots along it. Under a scale it no longer maps to whole dots at all — the
    // bars stay evenly sized, they just can't be pinned.
    final matrix = context.canvas.getTransform();
    final alongX = matrix.entry(0, 0);
    final alongY = matrix.entry(1, 0);
    bool isUnit(double value) => (value.abs() - 1).abs() < 1e-6;
    bool isZero(double value) => value.abs() < 1e-6;
    final double scale;
    final double origin;
    if (isZero(alongY) && isUnit(alongX)) {
      scale = alongX;
      origin = matrix.entry(0, 3);
    } else if (isZero(alongX) && isUnit(alongY)) {
      scale = alongY;
      origin = matrix.entry(1, 3);
    } else {
      scale = 0;
      origin = 0;
    }
    var left = rect.left;
    if (scale != 0 && snapToDots) {
      final absolute = origin + left * scale;
      final snapped = (absolute * dotsPerPoint).roundToDouble() / dotsPerPoint;
      left = (snapped - origin) / scale;
    }

    // Laying the symbol out `modules` points wide makes every element's left
    // and width an exact module count.
    for (final element in pw.Barcode.code128().make(
      data,
      width: modules.toDouble(),
      height: 1,
    )) {
      if (element is! pw.BarcodeBar || !element.black || element.width <= 0) {
        continue;
      }
      context.canvas.drawRect(
        left + element.left.roundToDouble() * moduleWidth,
        rect.bottom,
        element.width.roundToDouble() * moduleWidth,
        rect.height,
      );
    }
    context.canvas
      ..setFillColor(color)
      ..fillPath();
  }
}
