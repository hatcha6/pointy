import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_document_service.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';

import '../../support/key_value_store_testing.dart';

/// Stands in for the PDF label path and remembers the shop name it was given.
class _RecordingLabelService extends BarcodeLabelDocumentService {
  final List<String?> shopNames = [];

  @override
  Future<PrintTransportResult> printLabels({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
    String? shopName,
  }) async {
    shopNames.add(shopName);
    return const PrintTransportResult.success('printed');
  }

  @override
  Future<PrintTransportResult> printTest(
    PrinterEndpoint endpoint, {
    String? shopName,
  }) async {
    shopNames.add(shopName);
    return const PrintTransportResult.success('printed');
  }
}

DevicePrinter _labelPrinter({bool shopHeader = true}) => DevicePrinter(
  id: 'labels',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.system,
      name: 'XP-235B',
      address: 'XP-235B',
      outputMode: PrinterOutputMode.pdfA4,
      labelShopHeader: shopHeader,
    ),
  ),
  roles: const {PrinterRole.barcodeLabels},
);

const _line = BarcodeLabelPrintLine(
  label: BarcodeLabelDraft(
    displayName: 'قهوة',
    productName: 'قهوة',
    sku: 'COF-1',
    barcode: '123456789012',
    unitPrice: 5,
  ),
  copies: 1,
  includePrice: true,
);

void main() {
  late _RecordingLabelService labels;
  late PrintingRepository repository;
  late String? shopName;
  late bool settingsAnswer;

  setUp(() {
    installMemoryKeyValueStore();
    labels = _RecordingLabelService();
    shopName = 'محلات النسيم';
    settingsAnswer = true;
    final client = MockClient((request) async {
      if (request.url.path.contains('/shop-settings/') && settingsAnswer) {
        return http.Response(
          jsonEncode({'shop_name': shopName}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 500);
    });
    repository = PrintingRepository(
      PosApiService(client: client),
      barcodeLabelDocumentService: labels,
    );
  });

  Future<void> savePrinter(DevicePrinter printer) async {
    final saved = await repository.saveDevicePrinters(
      DevicePrinters([printer]),
    );
    expect(saved, isA<Ok<void>>());
  }

  test('a PDF label printer heads its stickers with the shop name', () async {
    await savePrinter(_labelPrinter());

    await repository.printBarcodeLabels([_line]);
    await repository.printBarcodeLabelTest(_labelPrinter().config);

    expect(labels.shopNames, ['محلات النسيم', 'محلات النسيم']);
  });

  test('a printer with the bar off is never handed a name', () async {
    await savePrinter(_labelPrinter(shopHeader: false));

    await repository.printBarcodeLabels([_line]);

    expect(labels.shopNames, [null]);
  });

  test('a lost answer keeps the last name, and never the label', () async {
    await savePrinter(_labelPrinter());
    await repository.printBarcodeLabels([_line]);

    settingsAnswer = false;
    final result = await repository.printBarcodeLabels([_line]);

    expect(result.isSuccess, isTrue);
    expect(labels.shopNames, ['محلات النسيم', 'محلات النسيم']);
  });

  test('a shop with no name gets no bar', () async {
    shopName = '  ';
    await savePrinter(_labelPrinter());

    await repository.printBarcodeLabels([_line]);

    expect(labels.shopNames, [null]);
  });
}
