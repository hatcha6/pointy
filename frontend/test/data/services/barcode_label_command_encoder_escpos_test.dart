import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_command_encoder.dart';

/// `GS k 73` — ESC/POS Code128. Its presence is what proves the label went out
/// as a real scannable barcode rather than plain text.
const _gsKCode128 = <int>[0x1D, 0x6B, 0x49];

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
}

PrinterEndpoint _endpoint({
  ReceiptCutMode cutMode = ReceiptCutMode.none,
  int paperWidthMm = 80,
}) {
  return PrinterEndpoint(
    kind: PrintTransportKind.usb,
    name: 'HPRT LPQ80',
    address: 'printer:20d1:7008',
    paperWidthMm: paperWidthMm,
    cutMode: cutMode,
    barcodeLabelLanguage: BarcodeLabelPrinterLanguage.escPos,
  );
}

BarcodeLabelPrintLine _line({
  String name = 'WIDGET 500ml',
  String barcode = '123456789012',
  String sku = 'SKU-4471',
  int copies = 1,
}) {
  return BarcodeLabelPrintLine(
    label: BarcodeLabelDraft(
      displayName: name,
      sku: sku,
      barcode: barcode,
      unitPrice: 4.75,
    ),
    copies: copies,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const encoder = BarcodeLabelCommandEncoder();

  test('escPos labels carry a native GS k Code128 barcode', () async {
    final bytes = await encoder.encodeLabels(
      lines: [_line()],
      endpoint: _endpoint(),
    );

    expect(bytes, isNotEmpty);
    expect(
      _contains(bytes, _gsKCode128),
      isTrue,
      reason: 'label must use the printer\'s native Code128, not raster text',
    );
    // Subset-B prefix + payload must survive into the barcode data.
    expect(_contains(bytes, '{B123456789012'.codeUnits), isTrue);
  });

  test('escPos honours the copy count', () async {
    final single = await encoder.encodeLabels(
      lines: [_line()],
      endpoint: _endpoint(),
    );
    final triple = await encoder.encodeLabels(
      lines: [_line(copies: 3)],
      endpoint: _endpoint(),
    );

    expect(triple.length, greaterThan(single.length * 2));
  });

  test('escPos skips non-positive copy counts', () async {
    final bytes = await encoder.encodeLabels(
      lines: [_line(copies: 0)],
      endpoint: _endpoint(),
    );

    expect(bytes, isEmpty);
  });

  test('escPos rejects a label with no barcode', () async {
    expect(
      () => encoder.encodeLabels(
        lines: [_line(barcode: '   ')],
        endpoint: _endpoint(),
      ),
      throwsArgumentError,
    );
  });

  test(
    'escPos falls back to text when the payload is not Code128-safe',
    () async {
      // Arabic in the *barcode* field cannot be expressed in Code128; the label
      // should still print something identifiable rather than come out blank.
      final bytes = await encoder.encodeLabels(
        lines: [_line(barcode: 'منتج')],
        endpoint: _endpoint(),
      );

      expect(bytes, isNotEmpty);
      expect(_contains(bytes, _gsKCode128), isFalse);
    },
  );

  test('escPos renders an Arabic product name without throwing', () async {
    final bytes = await encoder.encodeLabels(
      lines: [_line(name: 'قهوة عربية')],
      endpoint: _endpoint(),
    );

    expect(bytes, isNotEmpty);
    expect(_contains(bytes, _gsKCode128), isTrue);
  });

  test('cutMode none feeds instead of cutting', () async {
    final feeding = await encoder.encodeLabels(
      lines: [_line()],
      endpoint: _endpoint(),
    );
    final cutting = await encoder.encodeLabels(
      lines: [_line()],
      endpoint: _endpoint(cutMode: ReceiptCutMode.full),
    );

    // ESC d n (feed) vs GS V (cut).
    expect(_contains(feeding, <int>[0x1D, 0x56]), isFalse);
    expect(_contains(cutting, <int>[0x1D, 0x56]), isTrue);
  });

  test('auto language is still rejected', () async {
    expect(
      () => encoder.encodeLabels(
        lines: [_line()],
        endpoint: _endpoint(),
        language: BarcodeLabelPrinterLanguage.auto,
      ),
      throwsArgumentError,
    );
  });

  // Opt-in: writes the exact bytes Pointy would send so they can be replayed
  // onto real hardware. Run with LABEL_DUMP=/path/to/label.bin.
  test('dump encoder output for hardware verification', () async {
    final target = Platform.environment['LABEL_DUMP'];
    if (target == null || target.isEmpty) {
      return;
    }
    final bytes = await encoder.encodeLabels(
      lines: [
        _line(),
        _line(name: 'قهوة عربية', barcode: '5901234123457'),
      ],
      endpoint: _endpoint(),
    );
    await File(target).writeAsBytes(bytes, flush: true);
    expect(await File(target).length(), bytes.length);
  });
}
