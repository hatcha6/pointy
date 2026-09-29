import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Reads a code the way a phone camera sees paper: it never resolves single
/// 0.125 mm dots — its optics blur them together (one 3×3 box blur) and its
/// sensor samples a few pixels a module (an area average over [scale]×[scale]
/// dots). The dots sit on a margin of white paper.
String? readLikeAPhone(
  int width,
  int height,
  bool Function(int x, int y) black, {
  required int scale,
}) {
  const margin = 36;
  final w = width + 2 * margin;
  final h = height + 2 * margin;
  final paper = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      paper[y * w + x] = black(x - margin, y - margin) ? 0 : 255;
    }
  }
  final blurred = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      var count = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          final yy = y + dy;
          if (xx >= 0 && yy >= 0 && xx < w && yy < h) {
            sum += paper[yy * w + xx];
            count++;
          }
        }
      }
      blurred[y * w + x] = sum / count;
    }
  }
  final sw = w ~/ scale;
  final sh = h ~/ scale;
  final pixels = Int32List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      var sum = 0.0;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          sum += blurred[(y * scale + dy) * w + x * scale + dx];
        }
      }
      final grey = (sum / (scale * scale)).round();
      pixels[y * sw + x] = 0xFF000000 | grey << 16 | grey << 8 | grey;
    }
  }
  try {
    return QRCodeReader()
        .decode(
          BinaryBitmap(HybridBinarizer(RGBLuminanceSource(sw, sh, pixels))),
        )
        .text;
  } on ReaderException {
    return null;
  }
}
