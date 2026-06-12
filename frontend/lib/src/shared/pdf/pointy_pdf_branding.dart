import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../branding.dart';

/// Shared identity for everything Pointy prints — A4 documents, business
/// reports, and (textually) thermal receipts. Keep wording changes in
/// `shared/branding.dart` so every printed artifact stays in sync.
abstract final class PointyPrintBranding {
  /// Credit line shown in the footer of every printed document.
  static const String creditLine = pointyPrintCreditLine;
}

/// Shared palette so reports and invoices read as one family of documents.
abstract final class PointyPdfPalette {
  static const ink = PdfColor.fromInt(0xff172026);
  static const muted = PdfColor.fromInt(0xff64717a);
  static const border = PdfColor.fromInt(0xffd6dde2);
  static const fill = PdfColor.fromInt(0xfff7f8f6);
  static const accent = PdfColor.fromInt(0xff0b6b64);
  static const accentSoft = PdfColor.fromInt(0xffe8f4f1);
  static const white = PdfColor.fromInt(0xffffffff);
}

/// Unified page footer: page indicator on one side, the optional shop footer
/// message in the middle, and the Pointy credit line on the other side.
class PointyPdfFooter extends pw.StatelessWidget {
  PointyPdfFooter({required this.pageLabel, this.shopFooter});

  final String pageLabel;
  final String? shopFooter;

  @override
  pw.Widget build(pw.Context context) {
    final footerText = shopFooter?.replaceAll(RegExp(r'\s+'), ' ').trim();

    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: PointyPdfPalette.border),
        ),
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
          pw.Text(
            PointyPrintBranding.creditLine,
            style: pw.TextStyle(
              color: PointyPdfPalette.accent,
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
