import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';

void main() {
  group('PdfPageSize', () {
    test('maps roll sizes to their millimetre width and A4 to null', () {
      expect(pdfPageSizeReceiptWidthMm(PdfPageSize.a4), isNull);
      expect(pdfPageSizeReceiptWidthMm(PdfPageSize.roll58), 58);
      expect(pdfPageSizeReceiptWidthMm(PdfPageSize.roll70), 70);
      expect(pdfPageSizeReceiptWidthMm(PdfPageSize.roll80), 80);
    });

    test('fromJson accepts the enum name, legacy key, and bare millimetres', () {
      expect(pdfPageSizeFromJson('roll80'), PdfPageSize.roll80);
      expect(pdfPageSizeFromJson('mm58'), PdfPageSize.roll58);
      expect(pdfPageSizeFromJson('70'), PdfPageSize.roll70);
      // Unknown / missing values fall back to the full A4 document.
      expect(pdfPageSizeFromJson(null), PdfPageSize.a4);
      expect(pdfPageSizeFromJson('letter'), PdfPageSize.a4);
      expect(pdfPageSizeFromJson('a4'), PdfPageSize.a4);
    });
  });

  group('PrinterEndpoint.pdfPageSize', () {
    test('defaults to A4', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
      );
      expect(endpoint.pdfPageSize, PdfPageSize.a4);
      expect(endpoint.usesReceiptStylePdf, isFalse);
    });

    test('usesReceiptStylePdf only for a document printer on a roll width', () {
      const a4Document = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
        pdfPageSize: PdfPageSize.a4,
      );
      const rollDocument = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
        pdfPageSize: PdfPageSize.roll80,
      );
      // A roll width on a thermal (ESC/POS) printer never triggers the PDF
      // receipt path — that printer already speaks ESC/POS.
      const thermalWithRoll = PrinterEndpoint(
        kind: PrintTransportKind.usb,
        name: '',
        outputMode: PrinterOutputMode.escPos,
        pdfPageSize: PdfPageSize.roll80,
      );

      expect(a4Document.usesReceiptStylePdf, isFalse);
      expect(rollDocument.usesReceiptStylePdf, isTrue);
      expect(thermalWithRoll.usesReceiptStylePdf, isFalse);
    });

    test('survives a JSON round-trip', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: 'Xprinter N160II',
        address: 'Xprinter N160II',
        outputMode: PrinterOutputMode.pdfA4,
        pdfPageSize: PdfPageSize.roll80,
      );

      final json = endpoint.toJson();
      expect(json['pdf_page_size'], 'roll80');

      final restored = PrinterEndpoint.fromJson(json);
      expect(restored.pdfPageSize, PdfPageSize.roll80);
    });

    test('reads the legacy pdf_page_format JSON key', () {
      final endpoint = PrinterEndpoint.fromJson(const {
        'kind': 'system',
        'name': '',
        'output_mode': 'pdfA4',
        'pdf_page_format': 'roll58',
      });
      expect(endpoint.pdfPageSize, PdfPageSize.roll58);
    });

    test('copyWith updates the page size independently', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
      );
      final updated = endpoint.copyWith(pdfPageSize: PdfPageSize.roll70);
      expect(updated.pdfPageSize, PdfPageSize.roll70);
      expect(endpoint.pdfPageSize, PdfPageSize.a4);
    });
  });

  group('PrinterEndpoint.compactReceipt', () {
    test('defaults to false', () {
      const endpoint = PrinterEndpoint(kind: PrintTransportKind.serial, name: '');
      expect(endpoint.compactReceipt, isFalse);
    });

    test('survives a JSON round-trip', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.serial,
        name: 'till',
        compactReceipt: true,
      );
      final json = endpoint.toJson();
      expect(json['compact_receipt'], isTrue);
      expect(PrinterEndpoint.fromJson(json).compactReceipt, isTrue);
    });

    test('fromJson accepts legacy/alias keys', () {
      expect(
        PrinterEndpoint.fromJson(const {
          'kind': 'serial',
          'name': '',
          'compact': true,
        }).compactReceipt,
        isTrue,
      );
      expect(
        PrinterEndpoint.fromJson(const {
          'kind': 'serial',
          'name': '',
          'dense_receipt': true,
        }).compactReceipt,
        isTrue,
      );
      // Missing → false.
      expect(
        PrinterEndpoint.fromJson(const {
          'kind': 'serial',
          'name': '',
        }).compactReceipt,
        isFalse,
      );
    });

    test('copyWith updates it independently', () {
      const endpoint = PrinterEndpoint(kind: PrintTransportKind.serial, name: '');
      expect(endpoint.copyWith(compactReceipt: true).compactReceipt, isTrue);
      expect(endpoint.compactReceipt, isFalse);
    });
  });

  group('BarcodeLabelPdfSize', () {
    test('maps sticker/roll sizes to their width and A4 to null', () {
      expect(barcodeLabelPdfWidthMm(BarcodeLabelPdfSize.label40x22), 40);
      expect(barcodeLabelPdfWidthMm(BarcodeLabelPdfSize.roll50), 50);
      expect(barcodeLabelPdfWidthMm(BarcodeLabelPdfSize.roll70), 70);
      expect(barcodeLabelPdfWidthMm(BarcodeLabelPdfSize.roll80), 80);
      expect(barcodeLabelPdfWidthMm(BarcodeLabelPdfSize.a4), isNull);
    });

    test('fromJson accepts the enum name, legacy keys, and defaults', () {
      expect(
        barcodeLabelPdfSizeFromJson('roll50'),
        BarcodeLabelPdfSize.roll50,
      );
      expect(barcodeLabelPdfSizeFromJson('70'), BarcodeLabelPdfSize.roll70);
      expect(barcodeLabelPdfSizeFromJson('a4'), BarcodeLabelPdfSize.a4);
      // Unknown / missing falls back to the default 40×22 sticker.
      expect(
        barcodeLabelPdfSizeFromJson(null),
        BarcodeLabelPdfSize.label40x22,
      );
      expect(
        barcodeLabelPdfSizeFromJson('unknown'),
        BarcodeLabelPdfSize.label40x22,
      );
    });
  });

  group('PrinterEndpoint barcode label PDF fields', () {
    test('default to a 40×22 sticker with no rotation', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
      );
      expect(endpoint.labelPdfSize, BarcodeLabelPdfSize.label40x22);
      expect(endpoint.labelRotationQuarterTurns, 0);
    });

    test('rotation fromJson tolerates quarter-turns and degrees', () {
      expect(barcodeLabelRotationFromJson(1), 1);
      expect(barcodeLabelRotationFromJson(3), 3);
      expect(barcodeLabelRotationFromJson(90), 1);
      expect(barcodeLabelRotationFromJson(270), 3);
      expect(barcodeLabelRotationFromJson('180'), 2);
      // Out-of-range / missing wraps back into 0–3.
      expect(barcodeLabelRotationFromJson(null), 0);
      expect(barcodeLabelRotationFromJson(5), 1);
    });

    test('survive a JSON round-trip', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: 'Xprinter N160II',
        outputMode: PrinterOutputMode.pdfA4,
        labelPdfSize: BarcodeLabelPdfSize.roll70,
        labelRotationQuarterTurns: 1,
      );
      final json = endpoint.toJson();
      expect(json['label_pdf_size'], 'roll70');
      expect(json['label_rotation_quarter_turns'], 1);

      final restored = PrinterEndpoint.fromJson(json);
      expect(restored.labelPdfSize, BarcodeLabelPdfSize.roll70);
      expect(restored.labelRotationQuarterTurns, 1);
    });

    test('copyWith updates label fields independently', () {
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
      );
      final updated = endpoint.copyWith(
        labelPdfSize: BarcodeLabelPdfSize.a4,
        labelRotationQuarterTurns: 2,
      );
      expect(updated.labelPdfSize, BarcodeLabelPdfSize.a4);
      expect(updated.labelRotationQuarterTurns, 2);
      expect(endpoint.labelPdfSize, BarcodeLabelPdfSize.label40x22);
      expect(endpoint.labelRotationQuarterTurns, 0);
    });
  });
}
