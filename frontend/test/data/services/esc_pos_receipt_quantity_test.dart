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

/// The slip's bytes as text. Arabic runs through a code page and comes out as
/// high bytes, which is why the names and unit labels here are Latin: a Latin
/// row, its "×" included, goes out as Latin-1 and reads back verbatim.
String _printable(List<int> bytes) => String.fromCharCodes(bytes);

/// Lines as the backend sends them: `float(line.quantity)`, which JSON carries
/// as `6.0` for six pieces.
const _lines = [
  {
    'name': 'COLA',
    'quantity': 6.0,
    'unit_label': 'PCS',
    'unit_price': '1.50',
    'line_total': '9.00',
  },
  {
    'name': 'CHEESE',
    'quantity': 1.25,
    'unit_label': 'KG',
    'unit_price': '8.00',
    'line_total': '10.00',
  },
];

/// Every thermal slip read `6.0 قطعة × 1.50 د.ل` where the invoice PDF of the
/// same sale said `6`. A weighed line has to keep its fraction all the same.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());
  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.fake,
    name: 'till',
    paperWidthMm: 80,
  );

  test('a receipt prints a whole quantity bare and keeps a fraction', () async {
    final bytes = await encoder.encodePayload(
      endpoint: endpoint,
      payload: {
        'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
        'order': {
          'receipt_number': 'R-1',
          'document_title': 'RECEIPT',
          'total_label': 'TOTAL',
          'total': '19.00',
          'payment_status': 'paid',
          'lines': _lines,
        },
      },
    );

    final slip = _printable(bytes);
    expect(slip, contains('6 PCS × 1.50 LYD = 9.00 LYD'));
    expect(slip, contains('1.25 KG × 8.00 LYD = 10.00 LYD'));
    expect(slip, isNot(contains('6.0 PCS')));
  });

  test(
    'a kitchen chit prints a whole quantity bare and keeps a fraction',
    () async {
      final bytes = await encoder.encodePayload(
        endpoint: endpoint,
        payload: {
          'kind': 'kitchen',
          'station': {'id': 1, 'name': 'GRILL'},
          'order': {
            'receipt_number': 'R-1',
            'document_title': 'KITCHEN',
            'lines': _lines,
          },
        },
      );

      final chit = _printable(bytes);
      expect(chit, contains('6 × COLA'));
      expect(chit, contains('1.25 × CHEESE'));
      expect(chit, isNot(contains('6.0 ×')));
    },
  );
}
