import 'dart:convert';
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

/// Parameter-byte counts for the escape sequences this encoder emits, so a
/// printable parameter byte is never mistaken for text.
const _escParams = <int, int>{
  0x40: 0, // ESC @   initialise
  0x32: 0, // ESC 2   default line spacing
  0x21: 1, // ESC !   print mode
  0x24: 2, // ESC $   absolute position
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
};

/// One printed line's text. A line with Arabic in it reaches the printer as
/// UTF-8; one without goes through the code page as Latin-1 (the `×` of an
/// item line included).
String _decodeLine(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// The slip's printed lines, top to bottom, left untrimmed so a padded line
/// keeps the width it was laid out to.
List<String> _printedLines(List<int> bytes) {
  final lines = <String>[];
  final current = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final byte = bytes[i];
    if (byte == 0x1B && i + 1 < bytes.length) {
      i += 2 + (_escParams[bytes[i + 1]] ?? 0);
      continue;
    }
    if (byte == 0x1D && i + 1 < bytes.length) {
      i += 2 + (_gsParams[bytes[i + 1]] ?? 0);
      continue;
    }
    if (byte == 0x1C) {
      // FS . / FS & — one-byte code page switches, no parameters.
      i += 2;
      continue;
    }
    if (byte == 0x0A) {
      final line = _decodeLine(current);
      if (line.trim().isNotEmpty) {
        lines.add(line);
      }
      current.clear();
    } else if (byte >= 0x20) {
      current.add(byte);
    }
    i++;
  }
  return lines;
}

Map<String, Object?> _payload({
  String paymentStatus = 'paid',
  String cashier = 'SALEM',
  String session = 'RS-7',
}) => {
  'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
  'order': {
    'receipt_number': 'R-1',
    'document_title': 'RECEIPT',
    'total_label': 'TOTAL',
    'total': '12.00',
    'balance_due': const {'paid', 'void'}.contains(paymentStatus)
        ? '0.00'
        : '12.00',
    'payment_status': paymentStatus,
    'created_at': '2026-09-15T09:00:00Z',
    'cashier': {'id': 4, 'name': cashier},
    'register_session': {'id': 7, 'session_number': session},
    'lines': [
      {
        'name': 'WIDGET',
        'quantity': '2',
        'unit_price': '6.00',
        'line_total': '12.00',
      },
    ],
  },
};

/// The slip's header used to spend a line on each short fact. Two of them
/// now share a line wherever the paper allows: the date across from the
/// payment status, the cashier across from the drawer session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());

  Future<List<String>> slip(
    Map<String, Object?> payload, {
    int paperWidthMm = 80,
    bool compact = false,
  }) async {
    final bytes = await encoder.encodePayload(
      payload: payload,
      endpoint: PrinterEndpoint(
        kind: PrintTransportKind.fake,
        name: 'till',
        paperWidthMm: paperWidthMm,
        compactReceipt: compact,
      ),
    );
    return _printedLines(bytes);
  }

  test('the date shares its line with the payment status', () async {
    final lines = await slip(_payload());

    final dated = lines.singleWhere((line) => line.contains('مدفوعة بالكامل'));
    // The date at the reading edge, the status padded out to the far edge of
    // an 80 mm roll's 48 columns.
    expect(dated, startsWith('2026/09/'));
    expect(dated, endsWith('مدفوعة بالكامل'));
    expect(dated.length, 48);
  });

  test('a voided sale prints as void, never as paid in full', () async {
    // Given back whole it owes nothing, which the balance alone would call
    // paid — and a reprint would pass for a sale that stood.
    final lines = await slip(_payload(paymentStatus: 'void'));

    expect(lines.where((line) => line.contains('ملغاة')), hasLength(1));
    expect(lines.where((line) => line.contains('مدفوعة')), isEmpty);
  });

  test('the status is printed once, up with the date, not under the '
      'total', () async {
    final lines = await slip(_payload());

    final status = lines.indexWhere((line) => line.contains('مدفوعة'));
    final total = lines.indexWhere((line) => line.contains('TOTAL'));
    expect(lines.where((line) => line.contains('مدفوعة')), hasLength(1));
    expect(status, lessThan(total));
  });

  for (final compact in [false, true]) {
    test('${compact ? 'a compact' : 'a standard'} 58 mm slip puts the cashier '
        'and the drawer session on one line', () async {
      final lines = await slip(_payload(), paperWidthMm: 58, compact: compact);

      final attribution = lines.singleWhere((line) => line.contains('SALEM'));
      expect(attribution, startsWith('الكاشير: SALEM'));
      expect(attribution, endsWith('جلسة RS-7'));
      // Font A's 32 columns: the header never drops to Font B.
      expect(attribution.length, 32);
    });
  }

  test('a pair too wide for the roll prints a line each', () async {
    final lines = await slip(
      _payload(
        paymentStatus: 'unpaid',
        cashier: 'ABDULRAHMAN ALFITOURI',
        session: 'RS-12345',
      ),
      paperWidthMm: 58,
    );

    // Neither is clipped or run together; each simply takes its own line.
    expect(lines, contains('الكاشير: ABDULRAHMAN ALFITOURI'));
    expect(lines, contains('جلسة RS-12345'));
    // A date and "آجل — غير مدفوعة" fill all 32 columns, leaving no gap.
    expect(lines, contains('آجل — غير مدفوعة'));
    expect(lines.where((line) => line.startsWith('2026/09/')), hasLength(1));
  });

  test('a slip with no status prints the date alone, unpadded', () async {
    final lines = await slip(_payload(paymentStatus: ''));

    final dated = lines.singleWhere((line) => line.startsWith('2026/09/'));
    expect(dated, matches(RegExp(r'^2026/09/\d\d \d\d:\d\d$')));
  });
}
