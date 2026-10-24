// The splash's pictures, made from the real logos.
//
//   flutter test tool/render_splash_test.dart
//     writes assets/branding/splash_logo_android12.png: the Daftar mark
//     (assets/branding/daftar_mark.png, 512 px = 128 dp) centred on Android
//     12's 1152 px icon canvas, inside its circular mask. The other platforms
//     use daftar_mark.png itself. Then `dart run flutter_native_splash:create`
//     (`make cards-splash` does both).
//
//   SPLASH_FRAMES=<dir> flutter test tool/render_splash_test.dart
//     also writes the opening at a few moments, and the drawn Daftar mark
//     beside the real one with their difference, to judge them by.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/animation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/features/splash/logo_morph_painter.dart';

Future<ui.Image> _decode(String path, {int? size}) async {
  final codec = await ui.instantiateImageCodec(
    File(path).readAsBytesSync(),
    targetWidth: size,
    targetHeight: size,
  );
  return (await codec.getNextFrame()).image;
}

Future<ui.Image> _draw(int size, void Function(Canvas canvas) paint) {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  return recorder.endRecording().toImage(size, size);
}

Future<void> _save(ui.Image image, String path) async {
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

Future<Uint8List> _rgba(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

void main() {
  test('the Android 12 splash icon', () async {
    final mark = await _decode('assets/branding/daftar_mark.png');
    final icon = await _draw(1152, (canvas) {
      canvas.drawImage(mark, const Offset(320, 320), Paint());
    });
    await _save(icon, 'assets/branding/splash_logo_android12.png');
  });

  test('the drawn Daftar mark matches the picture', () async {
    const size = 512;
    final real = await _decode(
      '../shared/pointy_brand/assets/branding/daftar_logo.png',
      size: size,
    );
    final drawn = await _draw(size, (canvas) {
      LogoMorphPainter(
        progress: const AlwaysStoppedAnimation(0.0001),
      ).paint(canvas, const Size.square(512));
    });
    final a = await _rgba(real);
    final b = await _rgba(drawn);
    var off = 0;
    final diff = Uint8List(a.length);
    for (var i = 0; i < a.length; i += 4) {
      var d = 0;
      for (var c = 0; c < 4; c++) {
        d = d > (a[i + c] - b[i + c]).abs() ? d : (a[i + c] - b[i + c]).abs();
      }
      if (d > 48) {
        off++;
      }
      diff[i] = diff[i + 1] = diff[i + 2] = d * 3 > 255 ? 255 : d * 3;
      diff[i + 3] = 255;
    }
    final share = off / (size * size);
    // ignore: avoid_print
    print('pixels that differ visibly: ${(share * 100).toStringAsFixed(2)}%');
    final frames = Platform.environment['SPLASH_FRAMES'];
    if (frames != null) {
      await _save(real, '$frames/daftar-real.png');
      await _save(drawn, '$frames/daftar-drawn.png');
      final buffer = await ui.ImmutableBuffer.fromUint8List(diff);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: size,
        height: size,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      await _save((await codec.getNextFrame()).image, '$frames/daftar-diff.png');
    }
    // Edges anti-alias a little differently; anything more is a mismatch.
    expect(share, lessThan(0.01));
  });

  test('the opening, frame by frame', () async {
    final frames = Platform.environment['SPLASH_FRAMES'];
    if (frames == null) {
      return;
    }
    final daftar = await _decode('assets/branding/daftar_mark.png', size: 256);
    final cards = await _decode('assets/branding/cards_mark.png', size: 256);
    for (final at in [0.0, 0.06, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0]) {
      final frame = await _draw(256, (canvas) {
        LogoMorphPainter(
          progress: AlwaysStoppedAnimation(at),
          daftar: daftar,
          cards: cards,
        ).paint(canvas, const Size.square(256));
      });
      await _save(frame, '$frames/morph-${(at * 100).round()}.png');
    }
  });
}
