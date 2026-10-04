import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../branding.dart';
import 'pointy_pdf_palette.dart';

/// Shared identity for everything Pointy prints — A4 documents, business
/// reports, and (textually) thermal receipts. Keep wording changes in
/// `shared/branding.dart` so every printed artifact stays in sync.
abstract final class PointyPrintBranding {
  /// Credit line shown in the footer of every printed document.
  static const String creditLine = pointyPrintCreditLine;
}

/// دفتر's mark for a black ground, in outline: the page and the pencil in
/// white, the tile left out so it dissolves into the black it is drawn on.
///
/// The one-colour mark is a black tile on white paper, and set on black as it
/// is it shows a white square with notched corners. At the sizes print gives
/// it the tile carries nothing anyway — "below 24 px only the page-and-pencil
/// survives" (`marketing/BRAND.md`, the avatar's rule) — so this is exactly
/// the white the tile encloses. It is drawn as outlines, not as a picture: a
/// 1-bit label head dithers a downscaled picture into a grey speckle, while
/// outlines print as sharp as the type beside them.
///
/// Traced from `assets/branding/logo_black.png` (1254 px): the white not
/// connected to the edge, marching squares at 50 % grey, Douglas–Peucker at
/// 0.6 px. Re-trace it if the mark ever changes.
const String pointyPdfBrandMarkOnBlackSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 643.0 715.5">'
    '<path fill="#fff" fill-rule="evenodd" d="'
    'M563.1 0.0 122.1 80.4 114.1 83.7 104.9 91.0 99.6 99.0 96.8 107.0 '
    '55.2 350.0 0.0 662.0 0.0 670.0 1.2 675.0 4.9 682.0 9.1 686.5 18.2 '
    '691.0 28.1 691.7 86.1 679.5 182.1 661.4 493.1 606.3 500.1 604.4 '
    '510.1 599.4 518.1 593.6 527.3 584.0 532.3 577.0 536.4 569.0 539.5 '
    '561.0 541.5 552.0 598.0 37.0 597.7 29.0 595.5 21.0 592.4 15.0 '
    '588.5 10.0 582.1 4.8 576.7 2.0ZM601.1 117.8 552.5 566.0 549.6 '
    '577.0 546.7 584.0 536.6 599.0 531.1 604.4 523.1 610.2 514.1 614.4 '
    '507.1 616.5 244.1 663.0 121.1 685.6 79.3 694.0 541.1 715.5 551.1 '
    '714.3 560.1 711.1 565.1 708.2 573.2 701.0 581.6 689.0 584.5 682.0 '
    '586.2 673.0 643.0 152.0 642.2 144.0 639.9 137.0 635.1 129.3 629.1 '
    '123.7 618.1 118.6ZM473.9 138.0 483.1 137.4 490.1 138.5 497.1 141.6 '
    '503.1 145.9 507.2 150.0 511.5 157.0 513.3 162.0 514.6 170.0 513.5 '
    '181.0 509.6 191.0 477.1 237.5 462.1 222.8 448.1 211.9 433.1 202.8 '
    '419.4 197.0 451.5 151.0 463.1 141.7ZM407.4 213.0 409.1 212.2 421.0 '
    '217.0 440.1 228.0 456.9 242.0 466.1 251.8 466.2 253.0 273.1 527.0 '
    '264.1 535.0 203.1 575.5 200.1 576.8 196.1 576.6 193.6 573.0 194.3 '
    '567.0 213.4 491.0 217.0 482.0Z'
    '"/></svg>';

/// Width over height of [pointyPdfBrandMarkOnBlackSvg].
const double pointyPdfBrandMarkOnBlackAspect = 643.0 / 715.5;

/// The closing brand stamp — "دُوِّنَ في دفتر" — with the brand mark rendered
/// inline (RTL) between the two words: "دُوِّنَ في [logo] دفتر". When no logo
/// image is supplied it degrades to the voweled text alone, so it is safe to use
/// on any surface. [fontSize]/[logoHeight]/colours let each caller size it to its
/// scale (the A4 footer keeps it muted and small; a receipt roll runs it bigger).
class PointyPdfTagline extends pw.StatelessWidget {
  PointyPdfTagline({
    this.brandLogo,
    this.fontSize = 8,
    this.logoHeight,
    this.color = PointyPdfPalette.muted,
    this.brandColor = PointyPdfPalette.accent,
  });

  final pw.ImageProvider? brandLogo;
  final double fontSize;
  final double? logoHeight;
  final PdfColor color;
  final PdfColor brandColor;

  @override
  pw.Widget build(pw.Context context) {
    final logo = brandLogo;
    final leadStyle = pw.TextStyle(color: color, fontSize: fontSize);
    final brandStyle = pw.TextStyle(
      color: brandColor,
      fontSize: fontSize,
      fontWeight: pw.FontWeight.bold,
    );
    if (logo == null) {
      return pw.Text(
        pointyPrintTagline,
        style: brandStyle,
        textDirection: pw.TextDirection.rtl,
        textAlign: pw.TextAlign.center,
      );
    }
    final markHeight = logoHeight ?? fontSize + 3;
    return pw.Directionality(
      textDirection: pw.TextDirection.rtl,
      child: pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(pointyPrintTaglineLead, style: leadStyle),
          pw.SizedBox(width: 3),
          pw.Image(logo, height: markHeight, width: markHeight),
          pw.SizedBox(width: 3),
          pw.Text(pointyPrintBrandName, style: brandStyle),
        ],
      ),
    );
  }
}

/// Unified page footer: page indicator on one side, the optional shop footer
/// message in the middle, and the Pointy credit line on the other side. Used by
/// every Pointy PDF via the shared page scaffold.
class PointyPdfFooter extends pw.StatelessWidget {
  PointyPdfFooter({required this.pageLabel, this.shopFooter, this.brandLogo});

  final String pageLabel;
  final String? shopFooter;

  /// Optional brand mark for the closing tagline. When null the footer shows the
  /// tagline as text only (still on-brand), so report/other callers need not
  /// thread the asset through.
  final pw.ImageProvider? brandLogo;

  @override
  pw.Widget build(pw.Context context) {
    final footerText = shopFooter?.replaceAll(RegExp(r'\s+'), ' ').trim();

    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: PointyPdfPalette.border)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            pageLabel,
            style: const pw.TextStyle(
              color: PointyPdfPalette.muted,
              fontSize: 8,
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(
            child: footerText == null || footerText.isEmpty
                ? pw.SizedBox()
                : pw.Text(
                    footerText,
                    maxLines: 1,
                    style: const pw.TextStyle(
                      color: PointyPdfPalette.muted,
                      fontSize: 8,
                    ),
                    textAlign: pw.TextAlign.center,
                  ),
          ),
          pw.SizedBox(width: 10),
          PointyPdfTagline(brandLogo: brandLogo),
        ],
      ),
    );
  }
}
