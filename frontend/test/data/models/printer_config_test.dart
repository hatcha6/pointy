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

    test('fromJson accepts the enum name, legacy key, and bare millimetres',
        () {
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
}
