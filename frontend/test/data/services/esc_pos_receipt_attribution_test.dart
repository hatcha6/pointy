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

/// The slip's ASCII content. Arabic runs through a code page and comes out as
/// high bytes, which is exactly why the two values under test — a name and a
/// session number — are Latin here: what matters is that they reach the paper.
String _printable(List<int> bytes) => String.fromCharCodes(bytes);

Map<String, Object?> _payload({
  Map<String, Object?>? cashier,
  Map<String, Object?>? registerSession,
}) => {
  'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
  'order': {
    'receipt_number': 'R-1',
    'document_title': 'RECEIPT',
    'total_label': 'TOTAL',
    'total': '12.00',
    'payment_status': 'paid',
    'created_at': '2026-09-15T09:00:00Z',
    'cashier': ?cashier,
    'register_session': ?registerSession,
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

/// A customer brings back a receipt and the owner wants to know who rang it up.
/// Before this the answer was only in the Z-Report, reachable by reconciling
/// shifts against timestamps; the slip itself named nobody.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());
  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.fake,
    name: 'till',
    paperWidthMm: 80,
  );

  test('the receipt names the cashier and the drawer session', () async {
    final bytes = await encoder.encodePayload(
      payload: _payload(
        cashier: const {'id': 4, 'name': 'SALEM'},
        registerSession: const {'id': 7, 'session_number': 'RS-7'},
      ),
      endpoint: endpoint,
    );

    final slip = _printable(bytes);
    expect(slip, contains('SALEM'));
    expect(slip, contains('RS-7'));
  });

  test('a compact slip keeps the attribution', () async {
    final bytes = await encoder.encodePayload(
      payload: _payload(
        cashier: const {'id': 4, 'name': 'SALEM'},
        registerSession: const {'id': 7, 'session_number': 'RS-7'},
      ),
      endpoint: endpoint.copyWith(compactReceipt: true),
    );

    final slip = _printable(bytes);
    expect(slip, contains('SALEM'));
    expect(slip, contains('RS-7'));
  });

  test('a sale rung up on no drawer prints no attribution at all', () async {
    final bytes = await encoder.encodePayload(
      payload: _payload(),
      endpoint: endpoint,
    );

    // Nothing to name and nothing pretending otherwise: an imported or
    // channel order has no cashier, and must not grow an empty label row.
    expect(_printable(bytes), isNot(contains('RS-')));
  });
}
