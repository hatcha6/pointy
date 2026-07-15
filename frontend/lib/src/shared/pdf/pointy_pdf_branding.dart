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
