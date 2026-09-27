import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';

/// No brand mark, so the shop logo is the ticket's only raster image.
class _NoBrandLogoLoader extends PointyBrandLogoLoader {
  const _NoBrandLogoLoader();

  @override
  Future<Uint8List?> load() async => null;
}

Map<String, Object?> _receiptWithLogo(img.Image logo) => {
  'shop': {
    'name': 'SHOP',
    'currency_symbol': 'LYD',
    'logo_bytes': base64Encode(img.encodePng(logo)),
  },
  'order': {
    'receipt_number': 'R-1',
    'total': '6.00',
    'lines': [
      {
        'name': 'ITEM',
        'quantity': '1',
        'unit_price': '6.00',
        'line_total': '6.00',
      },
    ],
  },
};

/// [logo] painted [paper], then opaque black across its left half: lopsided,
/// so a mirrored or off-centre raster fails as surely as a blank one.
img.Image _inkLeftHalf(img.Image logo, {required img.Color paper}) {
  img.fill(logo, color: paper);
  return img.fillRect(
    logo,
    x1: 0,
    y1: 0,
    x2: logo.width ~/ 2 - 1,
    y2: logo.height - 1,
    color: img.ColorRgba8(0, 0, 0, 255),
  );
}

/// The first `GS v 0` image in [ticket]: its declared size, the data that
/// size covers, and the three bytes after it.
({int widthBytes, int height, List<int> data, List<int> next}) _firstRaster(
  List<int> ticket,
) {
  for (var i = 0; i + 8 <= ticket.length; i++) {
    if (ticket[i] == 0x1D && ticket[i + 1] == 0x76 && ticket[i + 2] == 0x30) {
      final widthBytes = ticket[i + 4] | ticket[i + 5] << 8;
      final height = ticket[i + 6] | ticket[i + 7] << 8;
      final end = i + 8 + widthBytes * height;
      if (end > ticket.length) {
        fail('the declared raster runs past the end of the ticket');
      }
      return (
        widthBytes: widthBytes,
        height: height,
        data: ticket.sublist(i + 8, end),
        next: ticket.skip(end).take(3).toList(),
      );
    }
  }
  fail('no GS v 0 raster image in the ticket');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogoLoader());
  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.fake,
    name: 'till',
    paperWidthMm: 80,
  );

  // A 300-dot logo pads to 304 (38 bytes): two blank dots each side, then the
  // left 150 dots inked — dots 2..151 of every row.
  final centred300 = [0x3F, ...List.filled(18, 0xFF), ...List.filled(19, 0)];
  final cases = <(String, img.Image, List<int>)>[
    (
      'RGB, 300 dots wide',
      _inkLeftHalf(
        img.Image(width: 300, height: 24),
        paper: img.ColorRgb8(255, 255, 255),
      ),
      centred300,
    ),
    (
      'RGBA on a transparent background, 300 dots wide',
      _inkLeftHalf(
        img.Image(width: 300, height: 24, numChannels: 4),
        paper: img.ColorRgba8(0, 0, 0, 0),
      ),
      centred300,
    ),
    (
      'grayscale, 300 dots wide',
      _inkLeftHalf(
        img.Image(width: 300, height: 24, numChannels: 1),
        paper: img.ColorRgb8(255, 255, 255),
      ),
      centred300,
    ),
    (
      'RGBA on a transparent background, already 304 dots wide',
      _inkLeftHalf(
        img.Image(width: 304, height: 24, numChannels: 4),
        paper: img.ColorRgba8(0, 0, 0, 0),
      ),
      [...List.filled(19, 0xFF), ...List.filled(19, 0)],
    ),
  ];

  for (final (name, logo, row) in cases) {
    test('prints the shop logo intact: $name', () async {
      final ticket = await encoder.encodePayload(
        payload: _receiptWithLogo(logo),
        endpoint: endpoint,
      );

      final raster = _firstRaster(ticket);
      expect(raster.widthBytes, 38);
      expect(raster.height, 24);
      expect(
        raster.next,
        [0x1B, 0x64, 0x01],
        reason:
            'the declared data must end where the logo does: the feed '
            'that follows it, not stray padding',
      );
      expect(
        raster.data.any((byte) => byte != 0),
        isTrue,
        reason: 'the logo printed blank',
      );
      for (var y = 0; y < raster.height; y++) {
        expect(
          raster.data.sublist(y * 38, (y + 1) * 38),
          row,
          reason: 'row $y',
        );
      }
    });
  }
}
