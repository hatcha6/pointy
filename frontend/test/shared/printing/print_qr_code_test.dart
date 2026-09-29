import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/shared/pdf/pdf.dart';
import 'package:pointy_frontend/src/shared/printing/print_qr_code.dart';
import 'package:qr/qr.dart';

import 'phone_camera.dart';

/// The QR code printed beside a provider card's PIN. A customer scans it at
/// home, off a slip a worn thermal head printed, and their phone must offer
/// to dial exactly the operator's redemption code — so these decode the dots
/// the printer is sent, clean and deliberately damaged, back to the text.
void main() {
  const almadar = 'tel:*112*1111222233334%23';
  const libyana = 'tel:1201111222233334';

  group('what the code holds', () {
    test('a USSD code keeps its # as %23, or the phone drops it', () {
      expect(dialQrData('*112*1111222233334#'), almadar);
    });

    test('a call keeps its number as it is', () {
      expect(dialQrData('1201111222233334'), libyana);
    });

    test('anything that is not a dial string gets no code', () {
      for (final dial in ['', '12', 'tel:120', '*112* 1111#', '٣٣٣٣٣٣', 'x']) {
        expect(dialQrData(dial), isNull, reason: dial);
      }
    });
  });

  group('the symbol', () {
    test('is error-correction level H in its smallest version', () {
      final ussd = PrintQrCode.tryEncode(almadar)!;
      final call = PrintQrCode.tryEncode(libyana)!;

      // Split into byte + alphanumeric/numeric segments, the same text needs
      // a version less than one byte segment would: bigger modules on the
      // same paper.
      expect(ussd.version, 3);
      expect(call.version, 2);
      for (final data in [almadar, libyana]) {
        final bytesOnly = QrCode.fromData(
          data: data,
          errorCorrectLevel: QrErrorCorrectLevel.H,
        );
        expect(
          PrintQrCode.tryEncode(data)!.version,
          lessThan(bytesOnly.typeNumber),
          reason: data,
        );
      }
      expect(ussd.moduleCount, 29);
      expect(ussd.moduleCountWithQuietZone, 37);
    });

    test('reads back as the exact text, whatever its shape', () {
      for (final data in [
        almadar,
        libyana,
        'tel:*120*9876543210123%23',
        'tel:#102*1234567890123456%23',
        'https://relay.example/i/abc',
      ]) {
        final code = PrintQrCode.tryEncode(data)!;
        final raster = _Raster.parse(escPosQrRaster(code, moduleDots: 9));
        expect(raster.read(), data, reason: data);
      }
    });
  });

  test('text a phone might misread gets no code at all', () {
    // Bytes above 127 name no character set; readers split between Latin-1
    // and UTF-8, and the package cannot write the header that settles it.
    expect(PrintQrCode.tryEncode('رمز'), isNull);
    expect(PrintQrCode.tryEncode(''), isNull);
  });

  group('the thermal raster', () {
    test('is whole-dot modules framed by blank paper, in whole bytes', () {
      final code = PrintQrCode.tryEncode(almadar)!;
      for (final dots in [4, 9, 10]) {
        final raster = _Raster.parse(escPosQrRaster(code, moduleDots: dots));
        final side = 37 * dots;
        expect(raster.height, side);
        expect(raster.width % 8, 0);
        expect(raster.width - side, lessThan(8));
        final left = (raster.width - side) ~/ 2;
        final quiet = 4 * dots;
        for (var y = 0; y < raster.height; y++) {
          for (var x = 0; x < raster.width; x++) {
            final row = (y - quiet) ~/ dots;
            final column = (x - left - quiet) ~/ dots;
            final inSymbol =
                y >= quiet &&
                x >= left + quiet &&
                row < code.moduleCount &&
                column < code.moduleCount;
            expect(
              raster.dot(x, y),
              inSymbol && code.isDark(row, column),
              reason: 'dot ($x, $y) at $dots dots a module',
            );
          }
        }
      }
    });

    // What a tired head does to a slip, at the size a 58 mm roll prints it
    // (9 dots a module; an 80 mm roll prints 10).
    late _Raster raster;
    setUp(() {
      final code = PrintQrCode.tryEncode(almadar)!;
      raster = _Raster.parse(escPosQrRaster(code, moduleDots: 9));
    });

    test('survives dead heating elements', () {
      // A dead element is a white line down the whole slip. Seven of them,
      // two side by side, one through the middle of a module column.
      final dead = {41, 42, 100, 144, 190, 251, 300};
      expect(raster.read(lost: (x, y) => dead.contains(x)), almadar);
    });

    test('survives a faded head that drops a third of its dots', () {
      final random = math.Random(7);
      final dropped = {
        for (var i = 0; i < raster.width * raster.height; i++)
          if (random.nextDouble() < 0.33) i,
      };
      expect(
        raster.read(lost: (x, y) => dropped.contains(y * raster.width + x)),
        almadar,
      );
    });

    test('survives paper that stuttered through the feed', () {
      // Bands of rows that never printed, as when the motor slips.
      bool stutter(int x, int y) => y % 60 < 2;
      expect(raster.read(lost: stutter), almadar);
    });

    test('survives a blot the head never printed', () {
      // A damp or greasy patch that would not take the heat: a disc of
      // missing data modules, the error correction's to put back.
      final cx = raster.width * 0.45;
      final cy = raster.height * 0.62;
      final radius = raster.width * 0.14;
      bool blot(int x, int y) =>
          (x - cx) * (x - cx) + (y - cy) * (y - cy) < radius * radius;
      expect(raster.read(lost: blot), almadar);
    });
  });

  group('the PDF drawing', () {
    test('reads back from the rectangles on the page', () async {
      final code = PrintQrCode.tryEncode(libyana)!;
      final document = pw.Document(compress: false)
        ..addPage(
          pw.Page(
            pageFormat: const PdfPageFormat(200, 200),
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Align(
              alignment: pw.Alignment.topLeft,
              child: PointyPdfQrCode(code, moduleDots: 8),
            ),
          ),
        );
      final page = _PdfRects.parse(await document.save());

      expect(page.rects, isNotEmpty);
      expect(page.read(dpi: 203, height: 200), libyana);
    });
  });
}

/// A `GS v 0` raster decoded back into dots.
class _Raster {
  _Raster._(this.width, this.height, this._bits);

  factory _Raster.parse(List<int> bytes) {
    expect(bytes.sublist(0, 4), [0x1D, 0x76, 0x30, 0x00]);
    final widthBytes = bytes[4] | bytes[5] << 8;
    final height = bytes[6] | bytes[7] << 8;
    final data = bytes.sublist(8);
    expect(data, hasLength(widthBytes * height));
    return _Raster._(widthBytes * 8, height, Uint8List.fromList(data));
  }

  final int width;
  final int height;
  final Uint8List _bits;

  bool dot(int x, int y) =>
      _bits[y * (width ~/ 8) + (x >> 3)] & (0x80 >> (x & 7)) != 0;

  /// What a phone reads off the printed dots, minus any [lost] to the head.
  String? read({bool Function(int x, int y)? lost}) {
    bool printed(int x, int y) =>
        x >= 0 &&
        y >= 0 &&
        x < width &&
        y < height &&
        dot(x, y) &&
        !(lost?.call(x, y) ?? false);
    return readLikeAPhone(width, height, printed, scale: 3);
  }
}

/// The filled rectangles of an uncompressed one-page PDF, in page points.
class _PdfRects {
  _PdfRects(this.rects);

  factory _PdfRects.parse(Uint8List bytes) {
    final source = String.fromCharCodes(bytes);
    final number = r'(-?[\d.]+)';
    final rects = [
      for (final match in RegExp(
        '$number $number $number $number re',
      ).allMatches(source))
        [for (var i = 1; i <= 4; i++) double.parse(match.group(i)!)],
    ];
    return _PdfRects(rects);
  }

  final List<List<double>> rects;

  /// Rasterises the page the way a driver does at [dpi], top row first, and
  /// reads the code off it.
  String? read({required int dpi, required double height}) {
    final scale = dpi / PdfPageFormat.inch;
    final size = (height * scale).ceil();
    final filled = Uint8List(size * size);
    for (final rect in rects) {
      final left = (rect[0] * scale).round();
      final right = ((rect[0] + rect[2]) * scale).round();
      final bottom = (rect[1] * scale).round();
      final top = ((rect[1] + rect[3]) * scale).round();
      for (var y = bottom; y < top; y++) {
        for (var x = left; x < right; x++) {
          // PDF space runs upward; an image runs down.
          filled[(size - 1 - y) * size + x] = 1;
        }
      }
    }
    return readLikeAPhone(
      size,
      size,
      (x, y) =>
          x >= 0 && y >= 0 && x < size && y < size && filled[y * size + x] == 1,
      scale: 2,
    );
  }
}
