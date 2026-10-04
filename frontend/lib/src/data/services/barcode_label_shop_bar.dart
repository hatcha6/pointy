import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../shared/branding.dart';
import '../../shared/pdf/pdf.dart';

/// The black bar along the top of a barcode sticker: the shop's name in
/// white, as if cut out of the bar, and دفتر's mark and name at its far end.
///
/// Everything in it is sized from the bar's own height, so one bar reads the
/// same on a 25 mm sticker as on a 50 mm one. The shop's name is set as large
/// as the bar allows and only ever shrinks — whole, never clipped — when it is
/// too long for the width. The brand sits at the far end of the line in its
/// own lockup proportions: a signature, never more than half the bar, while
/// the shop's name starts the line. On a bar too narrow to spare it the room,
/// the brand's name gives way and the mark stays.
class BarcodeLabelShopBar extends pw.StatelessWidget {
  BarcodeLabelShopBar({
    required this.shopName,
    required this.width,
    required this.height,
    required this.fonts,
  });

  final String shopName;
  final double width;
  final double height;
  final PointyPdfFonts fonts;

  static const _ink = PdfColor.fromInt(0xff000000);
  static const _paper = PdfColor.fromInt(0xffffffff);

  @override
  pw.Widget build(pw.Context context) {
    final padding = height * 0.3;
    final innerWidth = width - 2 * padding;
    final markHeight = height * 0.74;
    final markWidth = markHeight * pointyPdfBrandMarkOnBlackAspect;

    // The lockup's own proportions (marketing/promo/src/posters/kit.tsx):
    // the name at 0.72 of the mark, 0.34 of the mark between the two.
    final brandFontSize = markHeight * 0.72;
    final brandGap = markHeight * 0.34;
    final brandNameWidth =
        fonts.bold
            .getFont(context)
            .stringMetrics(pointyPrintBrandName)
            .advanceWidth *
        brandFontSize;
    final lockupWidth = markWidth + brandGap + brandNameWidth;
    // The shop's name keeps at least half the bar, or the brand's name goes.
    final showBrandName = innerWidth - lockupWidth >= innerWidth / 2;

    return pw.Container(
      width: width,
      height: height,
      padding: pw.EdgeInsets.symmetric(horizontal: padding),
      decoration: pw.BoxDecoration(
        color: _ink,
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(height * 0.18)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Expanded(child: _shopName(context)),
          pw.SizedBox(width: padding),
          pw.SvgImage(
            svg: pointyPdfBrandMarkOnBlackSvg,
            width: markWidth,
            height: markHeight,
          ),
          if (showBrandName) ...[
            pw.SizedBox(width: brandGap),
            pw.Text(
              pointyPrintBrandName,
              tightBounds: true,
              maxLines: 1,
              style: pw.TextStyle(
                font: fonts.bold,
                fontSize: brandFontSize,
                color: _paper,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The shop's name at the size whose glyphs fill [_nameFill] of the bar,
  /// solved from the face's own metrics — what the ink spans, not a line box
  /// with air above and below it. Too long for the width, it scales down whole:
  /// a [pw.FittedBox] lays its child out unbounded, so it sees the name's true,
  /// joined width and shrinks exactly that.
  pw.Widget _shopName(pw.Context context) {
    final metrics = fonts.bold.getFont(context).stringMetrics(shopName);
    final fontSize = metrics.height > 0
        ? (height * _nameFill / metrics.height).clamp(0.0, height * 0.62)
        : height * 0.5;
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        shopName,
        tightBounds: true,
        maxLines: 1,
        style: pw.TextStyle(
          font: fonts.bold,
          fontSize: fontSize,
          color: _paper,
        ),
      ),
    );
  }

  static const _nameFill = 0.64;
}
