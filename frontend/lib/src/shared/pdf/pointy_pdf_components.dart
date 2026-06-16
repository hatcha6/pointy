import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pointy_pdf_fonts.dart';
import 'pointy_pdf_palette.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Decodes shop/business logo bytes into a PDF image, swallowing bad data.
pw.ImageProvider? pdfLogoProvider(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  try {
    return pw.MemoryImage(bytes);
  } on Object {
    return null;
  }
}

/// Collapses whitespace and trims a free-text field to [maxCharacters],
/// returning null when empty so callers can skip the slot entirely.
String? compactPdfText(String? value, {required int maxCharacters}) {
  final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }
  if (normalized.length <= maxCharacters) {
    return normalized;
  }
  return '${normalized.substring(0, maxCharacters - 3)}...';
}

String formatPdfDate(DateTime dateTime) =>
    DateFormat('yyyy/MM/dd').format(dateTime.toLocal());

String formatPdfDateTime(DateTime dateTime) =>
    DateFormat('yyyy/MM/dd HH:mm').format(dateTime.toLocal());

// ---------------------------------------------------------------------------
// Page scaffold
// ---------------------------------------------------------------------------

/// Standard Pointy document page: RTL, brand fonts, and margins with enough
/// bottom clearance that the footer always clears a printer's non-printable
/// edge. Every Pointy PDF page is built through here so margins/direction stay
/// in one place.
pw.MultiPage buildPointyPdfMultiPage({
  required PointyPdfFonts fonts,
  required pw.Widget Function(pw.Context context) footer,
  required List<pw.Widget> Function(pw.Context context) build,
  pw.Widget Function(pw.Context context)? header,
  PdfPageFormat pageFormat = PdfPageFormat.a4,
  int maxPages = 50,
}) {
  return pw.MultiPage(
    maxPages: maxPages,
    pageTheme: pw.PageTheme(
      pageFormat: pageFormat.applyMargin(
        left: 16 * PdfPageFormat.mm,
        top: 16 * PdfPageFormat.mm,
        right: 16 * PdfPageFormat.mm,
        bottom: 18 * PdfPageFormat.mm,
      ),
      theme: fonts.toThemeData(),
      textDirection: pw.TextDirection.rtl,
    ),
    header: header,
    footer: footer,
    build: build,
  );
}

// ---------------------------------------------------------------------------
// Branded atoms
// ---------------------------------------------------------------------------

/// A logo in a bordered white tile. Renders nothing when there are no bytes.
class PointyPdfLogo extends pw.StatelessWidget {
  PointyPdfLogo({required this.logoBytes, this.size = 48});

  final Uint8List? logoBytes;
  final double size;

  @override
  pw.Widget build(pw.Context context) {
    final provider = pdfLogoProvider(logoBytes);
    if (provider == null) {
      return pw.SizedBox();
    }
    return pw.Container(
      width: size,
      height: size,
      padding: const pw.EdgeInsets.all(5),
      decoration: pw.BoxDecoration(
        color: PointyPdfPalette.white,
        border: pw.Border.all(color: PointyPdfPalette.border),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
      ),
      child: pw.Image(provider, fit: pw.BoxFit.contain),
    );
  }
}

/// Small teal chip used for labels like the report type.
class PointyPdfBadge extends pw.StatelessWidget {
  PointyPdfBadge(this.text);

  final String text;

  @override
  pw.Widget build(pw.Context context) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: pw.BoxDecoration(
        color: PointyPdfPalette.accentSoft,
        border: pw.Border.all(color: PointyPdfPalette.border),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          color: PointyPdfPalette.accent,
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }
}

/// Document masthead: a leading title/identity block and an optional trailing
/// block (logo, QR, badge). [boxed] wraps it in the soft panel that reports
/// use; invoices leave it open. The caller controls text direction so the
/// trailing block can sit on either side.
class PointyPdfMasthead extends pw.StatelessWidget {
  PointyPdfMasthead({required this.leading, this.trailing, this.boxed = false});

  final pw.Widget leading;
  final pw.Widget? trailing;
  final bool boxed;

  @override
  pw.Widget build(pw.Context context) {
    final trailingWidget = trailing;
    final row = pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: leading),
        if (trailingWidget != null) ...[pw.SizedBox(width: 14), trailingWidget],
      ],
    );

    if (!boxed) {
      return row;
    }
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PointyPdfPalette.fill,
        border: pw.Border.all(color: PointyPdfPalette.border, width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: row,
    );
  }
}

/// Bold section heading used above tables and field groups.
class PointyPdfSectionTitle extends pw.StatelessWidget {
  PointyPdfSectionTitle(this.title, {this.fontSize = 12});

  final String title;
  final double fontSize;

  @override
  pw.Widget build(pw.Context context) {
    return pw.Text(
      title,
      style: pw.TextStyle(
        color: PointyPdfPalette.ink,
        fontSize: fontSize,
        fontWeight: pw.FontWeight.bold,
      ),
      textAlign: pw.TextAlign.right,
    );
  }
}

/// A `label: value` line for document details and totals. Always RTL so a money
/// value like "7.00 د.ل" keeps its Arabic currency (forcing LTR mangles it).
/// [strong] enlarges/bolds it (grand total); [highlighted] wraps it in the
/// soft fill panel (balance due).
class PointyPdfFieldRow extends pw.StatelessWidget {
  PointyPdfFieldRow({
    required this.label,
    required this.value,
    this.strong = false,
    this.highlighted = false,
  });

  final String label;
  final String value;
  final bool strong;
  final bool highlighted;

  @override
  pw.Widget build(pw.Context context) {
    final emphasised = strong || highlighted;
    final style = pw.TextStyle(
      fontSize: emphasised ? 12 : 11,
      color: PointyPdfPalette.ink,
      fontWeight: emphasised ? pw.FontWeight.bold : pw.FontWeight.normal,
    );

    final row = pw.Directionality(
      textDirection: pw.TextDirection.rtl,
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('$label:', style: style),
          pw.Text(value, style: style),
        ],
      ),
    );

    if (!highlighted) {
      return row;
    }
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const pw.BoxDecoration(
        color: PointyPdfPalette.highlight,
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: row,
    );
  }
}
