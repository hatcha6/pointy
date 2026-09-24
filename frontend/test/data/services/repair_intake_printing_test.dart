import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/customer_asset.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/repair_ticket.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_command_encoder.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_document_service.dart';
import 'package:pointy_frontend/src/data/services/device_printers_storage.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/fake_print_transport.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/data/services/repair_intake_printables.dart';
import 'package:pointy_frontend/src/data/services/repair_ticket_document_service.dart';
import 'package:pointy_frontend/src/shared/pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scan code', () {
    test('drops the type prefix and keeps the unique date and id', () {
      expect(repairScanCode('REP-20260924-000123'), '20260924-000123');
      expect(repairScanCode('WRK-20260101-1234567'), '20260101-1234567');
    });

    test('leaves a number it does not recognise alone', () {
      expect(repairScanCode('REP-104'), 'REP-104');
      expect(repairScanCode('  custom '), 'custom');
    });
  });

  group('intake receipt content', () {
    test('carries the job, the customer, the device and the conditions', () {
      final ticket = buildRepairTicket(_job(), settings: _settings());

      expect(ticket.shopName, 'محل النور للهواتف');
      expect(ticket.shopPhone, '0912223344');
      expect(ticket.shopHeaderLines, ['شارع عمر المختار', 'طرابلس']);
      expect(ticket.jobNumber, 'REP-20260924-000123');
      expect(ticket.scanCode, '20260924-000123');
      expect(ticket.customerName, 'مروان الطرابلسي');
      expect(ticket.problem, 'الشاشة مكسورة واللمس لا يعمل');
      expect(ticket.quotedPrice, 250);
      expect(ticket.diagnosisFee, 10);
      expect(ticket.receivedBy, 'منى');
      expect(ticket.devices.single.name, 'Samsung Galaxy S23');
      expect(ticket.devices.single.identifiers, [
        'IMEI 352099001761481',
        'الرقم التسلسلي R5CT31ABCD',
      ]);
      expect(ticket.devices.single.color, 'أسود');
      expect(ticket.terms, const RepairTicketLabels.arabic().defaultTerms);
    });

    test("prints the shop's own conditions, in the shop's order", () {
      final ticket = buildRepairTicket(
        _job(),
        settings: _settings(terms: ['الشرط الأول', 'الشرط الثاني']),
      );

      expect(ticket.terms, ['الشرط الأول', 'الشرط الثاني']);
    });

    test(
      'a shop that cleared every condition prints none, not the defaults',
      () {
        final ticket = buildRepairTicket(
          _job(),
          settings: _settings(terms: []),
        );

        expect(ticket.terms, isEmpty);
      },
    );

    test('a walk-in with no name is still somebody on the receipt', () {
      final ticket = buildRepairTicket(_job(customerName: ''));

      expect(ticket.customerName, 'زبون');
      expect(ticket.shopName, 'نقطة البيع');
      expect(ticket.diagnosisFee, isNull);
    });

    test('counts warranty days the way Arabic does', () {
      const labels = RepairTicketLabels.arabic();
      expect(labels.warrantyDays(1), 'يوم واحد');
      expect(labels.warrantyDays(2), 'يومان');
      expect(labels.warrantyDays(7), '7 أيام');
      expect(labels.warrantyDays(30), '30 يومًا');
    });
  });

  group('device sticker content', () {
    test('is a product label carrying the customer and the job', () {
      final line = repairLabelPrintLine(_job());

      expect(line.label.displayName, 'مروان الطرابلسي');
      expect(line.label.barcode, '20260924-000123');
      expect(line.label.sku, 'REP-20260924-000123');
      expect(line.includePrice, isFalse);
      expect(line.copies, 1);
      expect(line.caption, 'الشاشة مكسورة واللمس…');
    });

    test('falls back to the device name when there is no description', () {
      final line = repairLabelPrintLine(_job(symptoms: ''));

      expect(line.caption, 'Samsung Galaxy S23');
    });

    test(
      'raw label languages print the caption where the price goes',
      () async {
        final bytes = await const BarcodeLabelCommandEncoder().encodeLabels(
          lines: [repairLabelPrintLine(_job())],
          endpoint: const PrinterEndpoint(
            kind: PrintTransportKind.fake,
            name: 'labels',
            labelWidthMm: 40,
            labelHeightMm: 30,
          ),
          language: BarcodeLabelPrinterLanguage.tspl,
        );
        final text = utf8.decode(bytes);

        expect(text, contains('الشاشة مكسورة'));
        expect(text, contains('"20260924-000123"'));
        expect(text, contains('REP-20260924-000123'));
        expect(text, isNot(contains('السعر')));
      },
    );
  });

  group('ESC/POS ticket', () {
    test('packs the job number into Code 128 set C pairs', () {
      final data = escPosCode128Data('20260924-000123');

      expect(data, [
        '{', 'C', //
        String.fromCharCode(20), String.fromCharCode(26),
        String.fromCharCode(9), String.fromCharCode(24),
        '{', 'B', '-', //
        '{', 'C', //
        String.fromCharCode(0), String.fromCharCode(1),
        String.fromCharCode(23),
      ]);
      // Start, 4 pairs, B, "-", C, 3 pairs, check (11 each) + stop (13).
      expect(escPosCode128Modules(data), 145);
    });

    test('keeps an odd run\'s first digit in B so the pairs line up', () {
      expect(escPosCode128Data('A12345'), [
        '{', 'B', 'A', '1', //
        '{', 'C', String.fromCharCode(23), String.fromCharCode(45),
      ]);
      expect(escPosCode128Data('AB-12'), ['{', 'B', 'A', 'B', '-', '1', '2']);
    });

    test(
      'prints through the receipt printer with the barcode and number',
      () async {
        final harness = _PrinterHarness(receiptWidthMm: 80);

        final result = await harness.repository.printRepairTicket(
          ticket: buildRepairTicket(_job(), settings: _settings()),
          shopSettings: _settings(),
        );

        expect(result.isSuccess, isTrue, reason: result.message);
        final bytes = harness.transport.sent.single;
        expect(_ascii(bytes), contains('REP-20260924-000123'));
        // GS k, Code 128 (m = 73), then the length-prefixed set C data.
        final barcode = _indexOf(bytes, [0x1D, 0x6B, 73]);
        expect(barcode, greaterThan(0));
        expect(bytes[barcode + 3], 14);
        expect(bytes.sublist(barcode + 4, barcode + 6), '{C'.codeUnits);
        // Three dots a bar on 80 mm, where it fits with its quiet zones.
        expect(_barWidthBefore(bytes, barcode), 3);
      },
    );

    test('narrows the bars to two dots on a 58 mm roll', () async {
      final harness = _PrinterHarness(receiptWidthMm: 58);

      await harness.repository.printRepairTicket(
        ticket: buildRepairTicket(_job(), settings: _settings()),
      );

      final bytes = harness.transport.sent.single;
      final barcode = _indexOf(bytes, [0x1D, 0x6B, 73]);
      expect(_barWidthBefore(bytes, barcode), 2);
    });

    test('with no receipt printer, says so instead of printing', () async {
      final harness = _PrinterHarness(receiptWidthMm: null);

      final result = await harness.repository.printRepairTicket(
        ticket: buildRepairTicket(_job()),
      );

      expect(result.isSuccess, isFalse);
      expect(result.unassignedRole, PrinterRole.posReceipt);
      expect(harness.transport.sent, isEmpty);
    });
  });

  group('PDF ticket', () {
    const service = RepairTicketDocumentService(fontLoader: _TestFontLoader());

    test(
      'a roll is one page, as wide as the paper and as tall as the slip',
      () async {
        for (final (size, widthMm) in const [
          (PdfPageSize.roll58, 58),
          (PdfPageSize.roll80, 80),
        ]) {
          final render = await service.buildRender(
            ticket: buildRepairTicket(_job(), settings: _settings()),
            pageSize: size,
          );

          expect(render.mediaWidthMm, widthMm.toDouble());
          expect(render.mediaHeightMm, greaterThan(100));
          final widths = _mediaBoxWidths(render.bytes);
          expect(widths, hasLength(1));
          expect(widths.single, closeTo(widthMm * PdfPageFormat.mm, 1));
        }
      },
    );

    test('A4 is a full page that the driver already knows', () async {
      final render = await service.buildRender(
        ticket: buildRepairTicket(_job(), settings: _settings()),
        pageSize: PdfPageSize.a4,
      );

      expect(render.mediaWidthMm, isNull);
      expect(_mediaBoxWidths(render.bytes).single, closeTo(595.28, 1));
    });

    // Opt-in: writes the ticket at every size and the device sticker, with the
    // real Arabic fonts, so the design can be looked at or replayed onto a
    // printer. Run with POINTY_REPAIR_TICKET_DUMP=<dir>.
    test(
      'writes tickets and the sticker when POINTY_REPAIR_TICKET_DUMP set',
      () async {
        final dumpDir = Platform.environment['POINTY_REPAIR_TICKET_DUMP'];
        if (dumpDir == null || dumpDir.isEmpty) {
          return;
        }
        Directory(dumpDir).createSync(recursive: true);
        const dumpService = RepairTicketDocumentService(
          fontLoader: _FileFontLoader(),
        );
        final ticket = buildRepairTicket(_job(), settings: _settings());
        for (final (size, name) in const [
          (PdfPageSize.roll58, 'roll-58'),
          (PdfPageSize.roll80, 'roll-80'),
          (PdfPageSize.a4, 'a4'),
        ]) {
          for (final compact in const [false, true]) {
            if (compact && size == PdfPageSize.a4) {
              continue;
            }
            final render = await dumpService.buildRender(
              ticket: ticket,
              pageSize: size,
              compact: compact,
            );
            await File(
              '$dumpDir/ticket-$name${compact ? '-compact' : ''}.pdf',
            ).writeAsBytes(render.bytes, flush: true);
          }
        }
        // The raw ESC/POS tickets too, ready to replay onto a printer
        // (`cat ticket-escpos-80.bin > /dev/usb/lp0`).
        for (final width in const [58, 80]) {
          final harness = _PrinterHarness(receiptWidthMm: width);
          await harness.repository.printRepairTicket(
            ticket: ticket,
            shopSettings: _settings(),
          );
          await File(
            '$dumpDir/ticket-escpos-$width.bin',
          ).writeAsBytes(harness.transport.sent.single, flush: true);
        }
        const labels = BarcodeLabelDocumentService(
          fontLoader: _FileFontLoader(),
        );
        for (final (width, height, name) in const [
          (38, 26, 'sticker-38x26'),
          (50, 30, 'sticker-50x30'),
        ]) {
          final bytes = await labels.buildLabelsPdf(
            lines: [
              repairLabelPrintLine(_job()),
              // A product label beside it: the same card, so the two can be
              // seen to be one design.
              const BarcodeLabelPrintLine(
                label: BarcodeLabelDraft(
                  displayName: 'شاحن سامسونج 25 واط',
                  sku: 'CHG-25',
                  barcode: '6281234567890',
                  unitPrice: 45,
                ),
                copies: 1,
              ),
            ],
            endpoint: PrinterEndpoint(
              kind: PrintTransportKind.system,
              name: 'labels',
              outputMode: PrinterOutputMode.pdfA4,
              labelWidthMm: width,
              labelHeightMm: height,
            ),
          );
          await File('$dumpDir/$name.pdf').writeAsBytes(bytes, flush: true);
        }
        expect(Directory(dumpDir).listSync(), isNotEmpty);
      },
    );
  });
}

OperationsJob _job({
  String customerName = 'مروان الطرابلسي',
  String symptoms = 'الشاشة مكسورة واللمس لا يعمل',
}) {
  return OperationsJob(
    id: 123,
    jobNumber: 'REP-20260924-000123',
    jobType: OperationsJobType.repair,
    workflowTemplate: 1,
    currentStage: 1,
    status: OperationsJobStatus.open,
    customerName: customerName,
    customerPhone: '0925550142',
    assignedToName: '',
    assignedEmployeeName: '',
    priority: OperationsJobPriority.normal,
    symptoms: symptoms,
    diagnosis: '',
    technicianNotes: '',
    warrantyDays: 30,
    outputVariantName: '',
    salesChannelName: '',
    orderReceiptNumber: '',
    publicToken: '',
    assets: [
      JobAssetLink(
        id: 1,
        asset: 7,
        assetDetails: CustomerAsset.fromJson(const {
          'id': 7,
          'asset_type': 1,
          'display_name': 'Samsung Galaxy S23',
          'brand': 'Samsung',
          'model_name': 'Galaxy S23',
          'imei': '352099001761481',
          'serial_number': 'R5CT31ABCD',
          'color': 'أسود',
        }),
      ),
    ],
    materials: const [],
    stageEvents: const [],
    materialsTotal: 0,
    quotedPrice: 250,
    dueAt: DateTime(2026, 9, 25, 18),
    createdAt: DateTime(2026, 9, 24, 14, 30),
    createdByName: 'منى',
  );
}

ShopSettings _settings({List<String>? terms}) {
  return ShopSettings.fromJson({
    'shop_name': 'محل النور للهواتف',
    'shop_phone': '0912223344',
    'receipt_header': 'شارع عمر المختار\nطرابلس',
    'receipt_footer': 'شكرًا لثقتكم',
    'repair_diagnosis_fee': '10.00',
    'repair_ticket_terms': terms,
  });
}

String _ascii(List<int> bytes) =>
    String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127));

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return i;
    }
  }
  return -1;
}

/// The `GS w n` bar width set nearest before the barcode at [barcodeIndex].
int _barWidthBefore(List<int> bytes, int barcodeIndex) {
  for (var i = barcodeIndex - 3; i >= 0; i--) {
    if (bytes[i] == 0x1D && bytes[i + 1] == 0x77) {
      return bytes[i + 2];
    }
  }
  return -1;
}

List<double> _mediaBoxWidths(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final re = RegExp(
    r'MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)',
  );
  return re.allMatches(text).map((m) => double.parse(m.group(3)!)).toList();
}

/// A device whose receipt printer is a raw ESC/POS printer on the fake
/// transport, which records what it was sent.
class _PrinterHarness {
  _PrinterHarness({required int? receiptWidthMm}) {
    repository = PrintingRepository(
      PosApiService(),
      fakeTransport: transport,
      printersStorage: _Printers(
        DevicePrinters([
          if (receiptWidthMm != null)
            DevicePrinter(
              id: 'receipts',
              config: PrinterConfig(
                endpoint: PrinterEndpoint(
                  kind: PrintTransportKind.fake,
                  name: 'receipts',
                  address: 'fake',
                  paperWidthMm: receiptWidthMm,
                ),
              ),
              roles: const {PrinterRole.posReceipt},
            ),
        ]),
      ),
    );
  }

  final transport = _CapturingTransport();
  late final PrintingRepository repository;
}

class _CapturingTransport extends FakePrintTransport {
  _CapturingTransport();

  final List<List<int>> sent = [];

  @override
  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    sent.add(bytes);
    return const PrintTransportResult.success('captured');
  }
}

class _Printers extends DevicePrintersStorage {
  const _Printers(this.printers);

  final DevicePrinters printers;

  @override
  Future<DevicePrinters> load() async => printers;
}

class _TestFontLoader extends PointyPdfFontLoader {
  const _TestFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async => const Type1PointyPdfFontData();
}

/// Loads the bundled Arabic TTFs off disk so dumped PDFs shape Arabic (the
/// asset bundle is not available under `flutter test`).
class _FileFontLoader extends PointyPdfFontLoader {
  const _FileFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async {
    final base = await File(
      'assets/fonts/IBMPlexSansArabic-Regular.ttf',
    ).readAsBytes();
    final bold = await File(
      'assets/fonts/IBMPlexSansArabic-Bold.ttf',
    ).readAsBytes();
    return TtfPointyPdfFontData(
      base: ByteData.view(Uint8List.fromList(base).buffer),
      bold: ByteData.view(Uint8List.fromList(bold).buffer),
    );
  }
}
