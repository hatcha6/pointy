import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/device_printers_storage.dart';

import '../../support/key_value_store_testing.dart';

/// The receipt printer an older build saved, calibrated for labels as well:
/// everything here must survive the move to the printer list.
Map<String, Object?> _legacyReceiptPrinter({
  String name = 'HPRT LPQ80',
  String address = 'ipp://hprt',
}) {
  return {
    'endpoint': {
      'kind': 'system',
      'name': name,
      'address': address,
      'output_mode': 'pdfA4',
      'pdf_page_size': 'roll80',
      'compact_receipt': true,
      'label_width_mm': 38,
      'label_height_mm': 26,
      'label_pdf_offset_x_mm': 20,
      'label_pdf_pitch_mm': 27.28,
    },
    'is_enabled': true,
    'auto_claim_jobs': true,
    'agent_id': 'pointy-local-agent',
  };
}

Map<String, Object?> _thermalConfig(String address) {
  return {
    'endpoint': {'kind': 'wifi', 'name': 'XP-80C', 'address': address},
  };
}

void main() {
  const storage = DevicePrintersStorage();

  group('migration from the one-printer settings', () {
    test('a device that never had a printer starts empty', () async {
      installMemoryKeyValueStore();
      expect((await storage.load()).isEmpty, isTrue);
    });

    test('the old printer keeps receipts, labels and every setting', () async {
      installMemoryKeyValueStore({
        'default_printer_config': jsonEncode(_legacyReceiptPrinter()),
      });

      final printers = await storage.load();

      expect(printers.printers, hasLength(1));
      final printer = printers.printers.single;
      expect(printer.id, 'legacy-receipt');
      expect(printer.roles, {
        PrinterRole.posReceipt,
        PrinterRole.barcodeLabels,
      });
      // It never did documents: reports opened the print dialog, and still do.
      expect(printers.holderOf(PrinterRole.documents), isNull);
      final endpoint = printer.endpoint;
      expect(endpoint.name, 'HPRT LPQ80');
      expect(endpoint.pdfPageSize, PdfPageSize.roll80);
      expect(endpoint.compactReceipt, isTrue);
      expect(endpoint.labelWidthMm, 38);
      expect(endpoint.labelHeightMm, 26);
      expect(endpoint.labelPdfOffsetXMm, 20);
      expect(endpoint.labelPdfPitchMm, 27.28);
    });

    test('the per-role key wins over the older default key', () async {
      installMemoryKeyValueStore({
        'default_printer_config': jsonEncode(_thermalConfig('10.0.0.1')),
        'printer_role_configs': jsonEncode({
          'pos_receipt': _thermalConfig('10.0.0.2'),
        }),
      });

      final printers = await storage.load();

      expect(printers.printers.single.endpoint.address, '10.0.0.2');
    });

    test('an untouched out-of-the-box config is not a printer', () async {
      installMemoryKeyValueStore({
        'default_printer_config': jsonEncode(
          PrinterConfig.defaultConfig().toJson(),
        ),
      });

      expect((await storage.load()).isEmpty, isTrue);
    });

    test(
      'kitchen stations join the printer they share, or get their own',
      () async {
        installMemoryKeyValueStore({
          'default_printer_config': jsonEncode(_thermalConfig('10.0.0.1')),
          'kitchen_station_configs': jsonEncode({
            // The receipt printer itself, byte for byte.
            '1': _thermalConfig('10.0.0.1'),
            // A printer in the kitchen.
            '2': _thermalConfig('10.0.0.9'),
            '3': _thermalConfig('10.0.0.9'),
            // A driver printer never printed a chit: nothing to keep.
            '4': _legacyReceiptPrinter(),
            'not-an-id': _thermalConfig('10.0.0.7'),
          }),
        });

        final printers = await storage.load();

        expect(printers.printers.map((printer) => printer.id), [
          'legacy-receipt',
          'legacy-kitchen-2',
        ]);
        expect(printers.kitchenPrinterFor(1)?.id, 'legacy-receipt');
        expect(printers.kitchenPrinterFor(2)?.id, 'legacy-kitchen-2');
        expect(printers.kitchenPrinterFor(3)?.id, 'legacy-kitchen-2');
        expect(printers.kitchenPrinterFor(4), isNull);
      },
    );

    test('reading migrates without writing anything', () async {
      final store = installMemoryKeyValueStore({
        'default_printer_config': jsonEncode(_thermalConfig('10.0.0.1')),
      });

      await storage.load();
      await storage.load();

      expect(await store.getString(DevicePrintersStorage.printersKey), isNull);
    });
  });

  group('saving', () {
    test('the saved list wins over the old keys from then on', () async {
      final store = installMemoryKeyValueStore({
        'default_printer_config': jsonEncode(_thermalConfig('10.0.0.1')),
      });
      final migrated = await storage.load();
      final labels = DevicePrinter(
        id: 'labels',
        config: PrinterConfig.fromJson(_legacyReceiptPrinter()),
        roles: const {PrinterRole.barcodeLabels},
      );

      await storage.save(migrated.upsert(labels));
      // An older build writing the old key afterwards changes nothing here.
      await store.setString(
        'default_printer_config',
        jsonEncode(_thermalConfig('10.0.0.99')),
      );
      final reloaded = await storage.load();

      expect(reloaded.printers, hasLength(2));
      expect(reloaded.holderOf(PrinterRole.barcodeLabels)?.id, 'labels');
      expect(
        reloaded.holderOf(PrinterRole.posReceipt)?.endpoint.address,
        '10.0.0.1',
      );
    });

    test('mirrors the receipt and kitchen printers for older builds', () async {
      final store = installMemoryKeyValueStore();
      await storage.save(
        DevicePrinters([
          DevicePrinter(
            id: 'counter',
            config: PrinterConfig.fromJson(_thermalConfig('10.0.0.5')),
            roles: const {PrinterRole.posReceipt},
            kitchenStationIds: const {8},
          ),
        ]),
      );

      final defaultConfig =
          jsonDecode((await store.getString('default_printer_config'))!)
              as Map<String, Object?>;
      expect(
        PrinterConfig.fromJson(defaultConfig).endpoint.address,
        '10.0.0.5',
      );
      final roleConfigs =
          jsonDecode((await store.getString('printer_role_configs'))!)
              as Map<String, Object?>;
      expect(roleConfigs.keys, ['pos_receipt']);
      final kitchen =
          jsonDecode((await store.getString('kitchen_station_configs'))!)
              as Map<String, Object?>;
      expect(kitchen.keys, ['8']);

      // No receipt printer any more: an older build must not keep printing
      // receipts on the one that was removed.
      await storage.save(DevicePrinters.empty);
      expect(await store.getString('default_printer_config'), isNull);
      expect(await store.getString('printer_role_configs'), '{}');
      expect(await store.getString('kitchen_station_configs'), '{}');
    });

    test('a damaged list falls back to the mirror', () async {
      installMemoryKeyValueStore({
        DevicePrintersStorage.printersKey: '{not json',
        'default_printer_config': jsonEncode(_thermalConfig('10.0.0.1')),
      });

      final printers = await storage.load();

      expect(
        printers.holderOf(PrinterRole.posReceipt)?.endpoint.address,
        '10.0.0.1',
      );
    });
  });
}
