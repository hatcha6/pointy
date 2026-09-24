import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';

const _thermal = PrinterEndpoint(
  kind: PrintTransportKind.wifi,
  name: 'XP-80C',
  address: '192.168.1.50',
);

const _driver = PrinterEndpoint(
  kind: PrintTransportKind.system,
  name: 'HP LaserJet',
  address: 'ipp://hp',
  outputMode: PrinterOutputMode.pdfA4,
);

DevicePrinter _printer(
  String id, {
  PrinterEndpoint endpoint = _thermal,
  Set<PrinterRole> roles = const {},
  Set<int> stations = const {},
}) {
  return DevicePrinter(
    id: id,
    config: PrinterConfig(endpoint: endpoint),
    roles: roles,
    kitchenStationIds: stations,
  );
}

void main() {
  group('DevicePrinters.upsert', () {
    test('a printer that takes a job takes it from whoever had it', () {
      final printers = DevicePrinters([
        _printer(
          'counter',
          roles: {PrinterRole.posReceipt, PrinterRole.barcodeLabels},
        ),
      ]).upsert(_printer('labels', roles: {PrinterRole.barcodeLabels}));

      expect(printers.holderOf(PrinterRole.posReceipt)?.id, 'counter');
      expect(printers.holderOf(PrinterRole.barcodeLabels)?.id, 'labels');
      expect(printers.byId('counter')!.roles, {PrinterRole.posReceipt});
    });

    test('replaces a printer in place, keeping the list order', () {
      final printers = DevicePrinters([
        _printer('a'),
        _printer('b'),
      ]).upsert(_printer('a', roles: {PrinterRole.posReceipt}));

      expect(printers.printers.map((printer) => printer.id), ['a', 'b']);
      expect(printers.byId('a')!.holds(PrinterRole.posReceipt), isTrue);
    });

    test('drops the jobs the printer cannot physically do', () {
      final printers = DevicePrinters.empty.upsert(
        _printer(
          'thermal',
          roles: {PrinterRole.documents, PrinterRole.posReceipt},
        ),
      );

      // Reports are PDFs: a raw thermal printer cannot take them.
      expect(printers.byId('thermal')!.roles, {PrinterRole.posReceipt});
      expect(printers.holderOf(PrinterRole.documents), isNull);

      final withDriver = printers.upsert(
        _printer('laser', endpoint: _driver, stations: {3}),
      );
      // Kitchen chits are raw ESC/POS: a driver printer cannot take them.
      expect(withDriver.byId('laser')!.kitchenStationIds, isEmpty);
    });

    test('moves a kitchen station between printers', () {
      final printers = DevicePrinters([
        _printer('kitchen', stations: {1, 2}),
      ]).upsert(_printer('bar', stations: {2}));

      expect(printers.kitchenPrinterFor(1)?.id, 'kitchen');
      expect(printers.kitchenPrinterFor(2)?.id, 'bar');
      expect(printers.kitchenStationConfigs.keys, unorderedEquals([1, 2]));
    });
  });

  group('DevicePrinters.assignRole', () {
    test('hands a job over and can leave it with nobody', () {
      final printers = DevicePrinters([
        _printer('a', roles: {PrinterRole.posReceipt}),
        _printer('b'),
      ]);

      final moved = printers.assignRole(PrinterRole.posReceipt, 'b');
      expect(moved.holderOf(PrinterRole.posReceipt)?.id, 'b');
      expect(moved.byId('a')!.roles, isEmpty);

      final cleared = moved.assignRole(PrinterRole.posReceipt, null);
      expect(cleared.holderOf(PrinterRole.posReceipt), isNull);
    });

    test('refuses a printer that cannot do the job', () {
      final printers = DevicePrinters([
        _printer('thermal'),
        _printer('laser', endpoint: _driver, roles: {PrinterRole.documents}),
      ]);

      final refused = printers.assignRole(PrinterRole.documents, 'thermal');
      expect(refused.holderOf(PrinterRole.documents)?.id, 'laser');
      expect(
        printers.assignKitchenStation(4, 'laser').kitchenPrinterFor(4),
        isNull,
      );
    });
  });

  group('DevicePrinters JSON', () {
    test('round-trips every field', () {
      final printers = DevicePrinters([
        DevicePrinter(
          id: 'labels',
          label: 'الملصقات',
          config: const PrinterConfig(
            endpoint: PrinterEndpoint(
              kind: PrintTransportKind.system,
              name: 'HPRT LPQ80',
              address: 'ipp://hprt',
              outputMode: PrinterOutputMode.pdfA4,
              labelWidthMm: 38,
              labelHeightMm: 26,
              labelPdfOffsetXMm: 20,
              labelPdfPitchMm: 27.28,
            ),
          ),
          roles: const {PrinterRole.barcodeLabels},
        ),
        _printer('kitchen', stations: {2, 7}),
      ]);

      final restored = DevicePrinters.fromJson(printers.toJson());

      expect(restored.printers, hasLength(2));
      expect(restored.printers.first.sameAs(printers.printers.first), isTrue);
      expect(restored.printers.last.sameAs(printers.printers.last), isTrue);
      expect(restored.byId('labels')!.endpoint.labelPdfPitchMm, 27.28);
    });

    test('repairs what the rules forbid instead of failing', () {
      final restored = DevicePrinters.fromJson({
        'printers': [
          {
            'id': 'first',
            'roles': ['pos_receipt', 'barcode_labels'],
            'kitchen_station_ids': [5],
            'config': {'endpoint': _thermal.toJson()},
          },
          {
            // Claims jobs the first already has: the first one keeps them.
            'id': 'second',
            'roles': ['pos_receipt', 'documents', 'price_tags'],
            'kitchen_station_ids': ['5', 6],
            'config': {'endpoint': _thermal.toJson()},
          },
          {'roles': <Object?>[]},
          'not a printer',
        ],
      });

      expect(restored.printers.map((printer) => printer.id), [
        'first',
        'second',
      ]);
      expect(restored.holderOf(PrinterRole.posReceipt)?.id, 'first');
      // Documents need a driver printer, and an unknown job is skipped.
      expect(restored.byId('second')!.roles, isEmpty);
      expect(restored.kitchenPrinterFor(5)?.id, 'first');
      expect(restored.kitchenPrinterFor(6)?.id, 'second');
    });
  });

  test('isConfigured refuses the untouched out-of-the-box serial port', () {
    expect(PrinterConfig.defaultConfig().endpoint.isConfigured, isFalse);
    expect(_thermal.isConfigured, isTrue);
    expect(
      const PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
      ).isConfigured,
      isTrue,
    );
  });
}
