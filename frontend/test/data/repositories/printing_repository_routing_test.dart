import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';

import '../../support/key_value_store_testing.dart';

/// Records every byte a printer was sent, per transport, so a test can say
/// which printer a job actually reached.
class _RecordingTransport extends PrintTransport {
  final List<List<int>> sent = [];

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async =>
      const PrintTransportStatus(isAvailable: true, message: 'ready');

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async => const PrintTransportResult.success('printed');

  @override
  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    sent.add(bytes);
    return const PrintTransportResult.success('printed');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async =>
      const PrintTransportResult.success('printed');
}

const _counterPrinter = DevicePrinter(
  id: 'counter',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.wifi,
      name: 'XP-80C',
      address: '192.168.1.50',
    ),
  ),
  roles: {PrinterRole.posReceipt},
  kitchenStationIds: {3},
);

const _labelPrinter = DevicePrinter(
  id: 'labels',
  label: 'الملصقات',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.serial,
      name: 'Zebra',
      address: '/dev/tty.zebra',
      barcodeLabelLanguage: BarcodeLabelPrinterLanguage.zpl,
    ),
  ),
  roles: {PrinterRole.barcodeLabels},
);

const _laserPrinter = DevicePrinter(
  id: 'laser',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.system,
      name: 'HP LaserJet',
      address: 'ipp://hp',
      outputMode: PrinterOutputMode.pdfA4,
    ),
  ),
  roles: {PrinterRole.documents},
);

final _labelLine = BarcodeLabelPrintLine(
  label: const BarcodeLabelDraft(
    displayName: 'قهوة',
    productName: 'قهوة',
    sku: 'COF-1',
    barcode: '123456789012',
    unitPrice: 5,
  ),
  copies: 1,
  includePrice: true,
);

PurchaseOrder _purchaseOrder() {
  return PurchaseOrder.fromJson({
    'id': 200,
    'order_number': 'P200',
    'status': 'draft',
    'supplier': 14,
    'lines': [
      {
        'id': 1,
        'product': 1,
        'variant': 7,
        'quantity': '2.000',
        'unit_cost': '3.50',
        'line_total': '7.00',
      },
    ],
    'receipts': const [],
    'adjustments': const [],
    'subtotal': '7.00',
    'total': '7.00',
  });
}

void main() {
  late _RecordingTransport network;
  late _RecordingTransport serial;
  late List<Map<String, Object?>> auditRecords;
  late PrintingRepository repository;

  setUp(() {
    installMemoryKeyValueStore();
    network = _RecordingTransport();
    serial = _RecordingTransport();
    auditRecords = [];
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/print-audit-events/record/')) {
        auditRecords.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode({'id': 1, 'status': 'requested'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.contains('/print-audit-events/')) {
        return http.Response(
          jsonEncode({'id': 1, 'status': 'completed'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    repository = PrintingRepository(
      PosApiService(client: client),
      wifiTransport: network,
      serialTransport: serial,
    );
  });

  Future<void> savePrinters(List<DevicePrinter> printers) async {
    final saved = await repository.saveDevicePrinters(DevicePrinters(printers));
    expect(saved, isA<Ok<void>>());
  }

  test('labels print on the label printer, not the receipt printer', () async {
    await savePrinters([_counterPrinter, _labelPrinter]);

    final result = await repository.printBarcodeLabels([_labelLine]);

    expect(result.isSuccess, isTrue);
    expect(serial.sent, hasLength(1));
    expect(utf8.decode(serial.sent.single), contains('^XA'));
    expect(network.sent, isEmpty);
  });

  test('a job no printer does sends nothing and says which job', () async {
    await savePrinters([_counterPrinter]);

    final result = await repository.printBarcodeLabels([_labelLine]);

    expect(result.isSuccess, isFalse);
    expect(result.unassignedRole, PrinterRole.barcodeLabels);
    expect(network.sent, isEmpty);
    expect(serial.sent, isEmpty);
    final receipt = await repository.loadPrinterConfigFor(
      PrinterRole.barcodeLabels,
    );
    expect(
      (receipt as Error<PrinterConfig>).exception,
      isA<PrinterRoleUnassigned>(),
    );
  });

  test(
    'a purchase order falls back to the receipt printer, and says so',
    () async {
      await savePrinters([_counterPrinter, _labelPrinter]);

      final result = await repository.printPurchaseOrder(
        order: _purchaseOrder(),
      );

      expect(result.isSuccess, isTrue);
      expect(network.sent, hasLength(1));
      expect(serial.sent, isEmpty);
      final metadata = auditRecords.single['metadata'] as Map<String, Object?>;
      expect(metadata['printer_role'], 'pos_receipt');
    },
  );

  test('kitchen stations and documents resolve from the list', () async {
    await savePrinters([_counterPrinter, _labelPrinter, _laserPrinter]);

    final kitchen = await repository.loadKitchenStationConfigs();
    expect(kitchen.keys, [3]);
    expect(kitchen[3]!.endpoint.address, '192.168.1.50');

    final documents = await repository.loadDocumentsPrinterEndpoint();
    expect(documents?.name, 'HP LaserJet');

    final receipts = await repository.loadReceiptPrinterConfig();
    expect((receipts as Ok<PrinterConfig>).value.endpoint.name, 'XP-80C');
  });

  test('no documents printer leaves reports on the print dialog', () async {
    await savePrinters([_counterPrinter]);

    expect(await repository.loadDocumentsPrinterEndpoint(), isNull);
  });
}
