import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';

/// A brand-logo loader that returns fixed bytes (or none), so the tagline path is
/// exercised deterministically without touching the asset bundle.
class _StubBrandLogoLoader extends PointyBrandLogoLoader {
  const _StubBrandLogoLoader(this.bytes);

  final Uint8List? bytes;

  @override
  Future<Uint8List?> load() async => bytes;
}

/// True when [haystack] contains the contiguous byte run [needle].
bool _containsSequence(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) {
    return false;
  }
  for (var i = 0; i <= haystack.length - needle.length; i++) {
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

Map<String, Object?> _salePayload() => {
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
        'unit_price': '6.00',
        'line_total': '12.00',
      },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A real, decodable PNG so the brand-mark raster path actually emits image
  // bytes (the encoder decodes + downscales it).
  final markBytes = Uint8List.fromList(
    img.encodePng(img.Image(width: 16, height: 16)),
  );

  const base = PrinterEndpoint(
    kind: PrintTransportKind.fake,
    name: 'till',
    paperWidthMm: 80,
  );

  // ESC 3 26 — the reduced line-spacing command a compact slip emits after reset.
  const tightSpacing = [0x1b, 0x33, 26];

  test(
    'compact mode emits the tight line-spacing command; standard does not',
    () async {
      const encoder = EscPosReceiptEncoder(
        brandLogoLoader: _StubBrandLogoLoader(null),
      );

      final standard = await encoder.encodePayload(
        payload: _salePayload(),
        endpoint: base,
      );
      final compact = await encoder.encodePayload(
        payload: _salePayload(),
        endpoint: base.copyWith(compactReceipt: true),
      );

      expect(_containsSequence(standard, tightSpacing), isFalse);
      expect(_containsSequence(compact, tightSpacing), isTrue);
    },
  );

  test(
    'the closing tagline renders the brand mark when its bytes are available',
    () async {
      final withMark = EscPosReceiptEncoder(
        brandLogoLoader: _StubBrandLogoLoader(markBytes),
      );
      const withoutMark = EscPosReceiptEncoder(
        brandLogoLoader: _StubBrandLogoLoader(null),
      );

      final marked = await withMark.encodePayload(
        payload: _salePayload(),
        endpoint: base,
      );
      final plain = await withoutMark.encodePayload(
        payload: _salePayload(),
        endpoint: base,
      );

      // The raster image adds a substantial run of bytes over the text-only tagline.
      expect(marked.length, greaterThan(plain.length));
    },
  );

  test('a compact z-report also tightens line spacing', () async {
    const encoder = EscPosReceiptEncoder(
      brandLogoLoader: _StubBrandLogoLoader(null),
    );
    final bytes = await encoder.encodePayload(
      endpoint: base.copyWith(compactReceipt: true),
      payload: {
        'kind': 'z_report',
        'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
        'report': {
          'title': 'Z-REPORT',
          'meta': const <String>[],
          'sections': [
            {
              'title': 'SALES',
              'rows': [
                {'label': 'NET', 'value': '110.00 LYD'},
              ],
            },
          ],
        },
      },
    );
    expect(_containsSequence(bytes, tightSpacing), isTrue);
  });
}
