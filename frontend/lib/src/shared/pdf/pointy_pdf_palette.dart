import 'package:pdf/pdf.dart';

/// The single source of truth for every printed-document colour, so invoices,
/// purchase orders, and business reports read as one family. Anything that
/// draws a Pointy PDF pulls its colours from here — no local `_PdfColors`.
abstract final class PointyPdfPalette {
  /// Primary body text.
  static const ink = PdfColor.fromInt(0xff172026);

  /// Secondary / label text.
  static const muted = PdfColor.fromInt(0xff64717a);

  /// Hairline borders and dividers.
  static const border = PdfColor.fromInt(0xffd6dde2);

  /// Subtle panel fill (metadata / header boxes).
  static const fill = PdfColor.fromInt(0xfff7f8f6);

  /// Brand teal — accents, table headers, the credit line.
  static const accent = PdfColor.fromInt(0xff0b6b64);

  /// Soft teal wash behind accent chips/badges.
  static const accentSoft = PdfColor.fromInt(0xffe8f4f1);

  /// Highlighted field background (e.g. balance due).
  static const highlight = PdfColor.fromInt(0xfff1f3f4);

  /// Zebra-stripe fill for alternating table rows.
  static const zebra = PdfColor.fromInt(0xfff4f7f6);

  static const white = PdfColor.fromInt(0xffffffff);
}
