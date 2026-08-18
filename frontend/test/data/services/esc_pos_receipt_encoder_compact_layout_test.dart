import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';

class _NoBrandLogo extends PointyBrandLogoLoader {
  const _NoBrandLogo();

  @override
  Future<Uint8List?> load() async => null;
}

/// `ESC M 1` / `ESC M 0` — select Font B (small) / Font A.
const _fontB = [0x1B, 0x4D, 1];
const _fontA = [0x1B, 0x4D, 0];

bool _has(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}

/// Parameter-byte counts for the escape sequences this encoder emits. Needed
/// because ESC/POS parameters are themselves printable ASCII — without
/// skipping them, `ESC M 1` leaks a stray "M" into the line text.
const _escParams = <int, int>{
  0x40: 0, // ESC @   initialise
  0x32: 0, // ESC 2   default line spacing
  0x21: 1, // ESC !   print mode
  0x61: 1, // ESC a   justification
  0x4D: 1, // ESC M   font select
  0x45: 1, // ESC E   emphasis
  0x47: 1, // ESC G   double strike
  0x74: 1, // ESC t   code page
  0x64: 1, // ESC d   feed n lines
  0x4A: 1, // ESC J   feed n dots
  0x33: 1, // ESC 3   line spacing
  0x2D: 1, // ESC -   underline
  0x7B: 1, // ESC {   upside down
};

const _gsParams = <int, int>{
  0x21: 1, // GS !  character size
  0x42: 1, // GS B  reverse
  0x56: 1, // GS V  cut
  0x68: 1, // GS h  barcode height
  0x77: 1, // GS w  barcode width
  0x48: 1, // GS H  HRI position
  0x66: 1, // GS f  HRI font
};

/// Printable text lines the slip would show, with control sequences removed.
List<String> _textLines(List<int> bytes) {
  final out = <String>[];
  final current = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1B && i + 1 < bytes.length) {
      final params = _escParams[bytes[i + 1]];
      i += params == null ? 2 : 2 + params;
      continue;
    }
    if (b == 0x1D && i + 1 < bytes.length) {
      final params = _gsParams[bytes[i + 1]];
      i += params == null ? 2 : 2 + params;
      continue;
    }
    if (b == 0x1C) {
      // FS . / FS & — one-byte code page switches, no parameters.
      i += 2;
      continue;
    }
    if (b == 0x0A) {
      final line = current.toString().trim();
      if (line.isNotEmpty) {
        out.add(line);
      }
      current.clear();
      i++;
      continue;
    }
    if (b >= 0x20 && b < 0x7F) {
      current.write(String.fromCharCode(b));
    }
    i++;
  }
  final tail = current.toString().trim();
  if (tail.isNotEmpty) {
    out.add(tail);
  }
  return out;
}

Map<String, Object?> _payload({int items = 3}) => {
  'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
  'order': {
    'receipt_number': 'R-1',
    'document_title': 'RECEIPT',
    'total_label': 'TOTAL',
    'total': '36.00',
    'payment_status': 'paid',
    'lines': [
      for (var i = 0; i < items; i++)
        {
          'name': 'LONG PRODUCT NAME NUMBER $i THAT WILL NOT FIT ON ONE LINE',
          'quantity': '2',
          'unit_price': '6.00',
          'line_total': '12.00',
        },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());

  const sizes = <int>[58, 72, 80];

  for (final mm in sizes) {
    final endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: mm,
    );

    test('${mm}mm: compact puts each item on exactly one row', () async {
      final compact = await encoder.encodePayload(
        payload: _payload(),
        endpoint: endpoint.copyWith(compactReceipt: true),
      );

      // Anchored on the name's leading word, which survives truncation on
      // every paper size. (Matching the money would also catch the total.)
      final rows = _textLines(
        compact,
      ).where((line) => line.contains('LONG')).toList();

      expect(rows, hasLength(3), reason: 'one row per item, none wrapped');
      for (final row in rows) {
        // Name and money detail share the one row.
        expect(row, contains('='));
        expect(row, contains('6.00'));
        expect(row, contains('12.00'));
      }
    });

    test('${mm}mm: compact rows stay within the Font B line width', () async {
      final compact = await encoder.encodePayload(
        payload: _payload(),
        endpoint: endpoint.copyWith(compactReceipt: true),
      );
      final width = switch (mm) { <= 58 => 42, <= 72 => 56, _ => 64 };

      for (final row in _textLines(
        compact,
      ).where((line) => line.contains('LONG'))) {
        expect(row.length, lessThanOrEqualTo(width));
      }
    });

    test('${mm}mm: compact uses fewer lines than standard', () async {
      final standard = await encoder.encodePayload(
        payload: _payload(),
        endpoint: endpoint,
      );
      final compact = await encoder.encodePayload(
        payload: _payload(),
        endpoint: endpoint.copyWith(compactReceipt: true),
      );

      expect(
        _textLines(compact).length,
        lessThan(_textLines(standard).length),
      );
    });
  }

  test('compact selects Font B; standard never does', () async {
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: 80,
    );
    final standard = await encoder.encodePayload(
      payload: _payload(),
      endpoint: endpoint,
    );
    final compact = await encoder.encodePayload(
      payload: _payload(),
      endpoint: endpoint.copyWith(compactReceipt: true),
    );

    expect(_has(compact, _fontB), isTrue);
    expect(_has(standard, _fontB), isFalse);
    // The total is pinned back to Font A so it stays legible.
    expect(_has(compact, _fontA), isTrue);
  });

  test('standard mode still wraps long names across rows', () async {
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: 58,
    );
    final standard = await encoder.encodePayload(
      payload: _payload(items: 1),
      endpoint: endpoint,
    );

    // Standard keeps the name and the money in separate blocks — no row
    // carries both.
    final merged = _textLines(
      standard,
    ).where((line) => line.contains('LONG') && line.contains('='));
    expect(merged, isEmpty);
    // And the long name itself still spans more than one row.
    expect(
      _textLines(standard).where((line) => line.contains('ONE LINE')),
      isNotEmpty,
    );
  });

  test('a name that cannot share the row falls back to two blocks', () async {
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: 58,
    );
    // A unit label long enough that the money detail alone fills a 42-char row.
    final payload = {
      'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
      'order': {
        'receipt_number': 'R-1',
        'document_title': 'RECEIPT',
        'total_label': 'TOTAL',
        'total': '12.00',
        'payment_status': 'paid',
        'lines': [
          {
            'name': 'ITEM',
            'quantity': '2',
            'unit_label': 'VERY LONG UNIT LABEL INDEED FOR A BOX',
            'unit_price': '6.00',
            'line_total': '12.00',
          },
        ],
      },
    };

    final compact = await encoder.encodePayload(
      payload: payload,
      endpoint: endpoint.copyWith(compactReceipt: true),
    );

    // Falls back rather than emitting a stub row; the name survives intact.
    expect(_textLines(compact), contains('ITEM'));
  });

  // Opt-in hardware harness: COMPACT_DUMP=<dir> writes both slips as raw
  // ESC/POS so they can be replayed onto a real printer.
  test('dump compact and standard slips for hardware comparison', () async {
    final dir = Platform.environment['COMPACT_DUMP'];
    if (dir == null || dir.isEmpty) {
      return;
    }
    Directory(dir).createSync(recursive: true);
    for (final mm in sizes) {
      final endpoint = PrinterEndpoint(
        kind: PrintTransportKind.fake,
        name: 'till',
        paperWidthMm: mm,
      );
      final standard = await encoder.encodePayload(
        payload: _payload(),
        endpoint: endpoint,
      );
      final compact = await encoder.encodePayload(
        payload: _payload(),
        endpoint: endpoint.copyWith(compactReceipt: true),
      );
      await File('$dir/standard-$mm.bin').writeAsBytes(standard, flush: true);
      await File('$dir/compact-$mm.bin').writeAsBytes(compact, flush: true);
    }
    expect(Directory(dir).listSync(), isNotEmpty);
  });
}
