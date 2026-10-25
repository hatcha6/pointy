import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/art_palette.dart';

/// Art [width]x[height] painted [base], with a [mark] block over the middle
/// [share] of it: a logo on a coloured card.
ByteData art(Color base, Color mark, {double share = 0.3}) {
  const width = 80, height = 50;
  final bytes = ByteData(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inMark =
          (x - width / 2).abs() < width * share / 2 &&
          (y - height / 2).abs() < height * share / 2;
      final c = inMark ? mark : base;
      final i = (y * width + x) * 4;
      bytes
        ..setUint8(i, (c.r * 255).round())
        ..setUint8(i + 1, (c.g * 255).round())
        ..setUint8(i + 2, (c.b * 255).round())
        ..setUint8(i + 3, 255);
    }
  }
  return bytes;
}

double hueOf(Color c) => HSVColor.fromColor(c).hue;

void main() {
  test('a white logo on purple reads as purple', () {
    final color = ArtPalette.dominantColor(
      art(const Color(0xFF8E2C9A), Colors.white),
      80,
      50,
    )!;
    expect(hueOf(color), closeTo(293, 8));
  });

  test('black lettering on yellow reads as yellow', () {
    final color = ArtPalette.dominantColor(
      art(const Color(0xFFFFC21A), Colors.black, share: 0.5),
      80,
      50,
    )!;
    expect(hueOf(color), closeTo(44, 8));
  });

  test('a yellow card\'s back stays dark enough for white text', () {
    final palette = ArtPalette.from(const Color(0xFFFFC21A));
    expect(
      HSLColor.fromColor(palette.light).lightness,
      lessThanOrEqualTo(0.43),
    );
    expect(hueOf(palette.light), closeTo(44, 4));
    // The page's tint is the art's colour as it is.
    expect(palette.tint, const Color(0xFFFFC21A));
  });

  test('colourless art gives its average', () {
    final color = ArtPalette.dominantColor(
      art(const Color(0xFF222222), Colors.white, share: 0.2),
      80,
      50,
    )!;
    expect(HSVColor.fromColor(color).saturation, lessThan(0.05));
  });
}
