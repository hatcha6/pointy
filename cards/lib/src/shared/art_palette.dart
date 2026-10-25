import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../data/models/catalog.dart';
import '../design/cards_tokens.dart';
import 'art_cache.dart';
import 'card_art.dart';
import 'cards_scope.dart';

/// A brand's colours, read from its own art: [light] and [dark] for a
/// gradient that white text stays readable on, and [tint] for washing a page
/// in the card's colour.
@immutable
class ArtPalette {
  const ArtPalette({
    required this.light,
    required this.dark,
    required this.tint,
  });

  /// The drawn card's colours, for a brand with no art or before it loads.
  factory ArtPalette.drawn(CardBrand brand) {
    final (light, dark) = DrawnCard.palette(brand.category);
    return ArtPalette(light: light, dark: dark, tint: light);
  }

  /// Built around the art's most telling colour: kept dark enough under
  /// white text (a yellow card's back turns deep gold, not unreadable
  /// lemon), the tint as it is.
  factory ArtPalette.from(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    final light = hsl
        .withLightness(hsl.lightness.clamp(0.22, 0.42))
        .withSaturation(hsl.saturation.clamp(0.0, 0.85));
    final dark = light.withLightness(light.lightness * 0.55);
    return ArtPalette(
      light: light.toColor(),
      dark: dark.toColor(),
      tint: dominant,
    );
  }

  final Color light;
  final Color dark;
  final Color tint;

  static ArtPalette lerp(ArtPalette a, ArtPalette b, double t) => ArtPalette(
    light: Color.lerp(a.light, b.light, t)!,
    dark: Color.lerp(a.dark, b.dark, t)!,
    tint: Color.lerp(a.tint, b.tint, t)!,
  );

  /// One reading per image for the life of the app: art never changes at an
  /// address.
  static final Map<String, Future<Color?>> _read = {};

  static Future<ArtPalette?> of(BuildContext context, CardBrand brand) async {
    if (brand.logo.isEmpty) {
      return null;
    }
    final url = CardsScope.of(context).catalog.imageUrl(brand.logo).toString();
    final dominant = await (_read[url] ??= _dominantOf(url));
    return dominant == null ? null : ArtPalette.from(dominant);
  }

  static Future<Color?> _dominantOf(String url) async {
    final completer = Completer<ui.Image?>();
    final stream = CachedNetworkImageProvider(
      url,
      cacheManager: artCache,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        completer.complete(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (_, _) {
        completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future;
    if (image == null) {
      return null;
    }
    try {
      final bytes = await image.toByteData();
      return bytes == null
          ? null
          : dominantColor(bytes, image.width, image.height);
    } finally {
      image.dispose();
    }
  }

  /// The colour the art is mostly made of, the way the eye names it: pixels
  /// are grouped by hue, near-white and near-black (logos, text, shadows)
  /// count for little, and the fullest, most colourful group wins. Art with
  /// no colour at all gives its average.
  @visibleForTesting
  static Color? dominantColor(ByteData rgba, int width, int height) {
    const hues = 24;
    final weight = List<double>.filled(hues, 0);
    final sums = List.generate(hues, (_) => [0.0, 0.0, 0.0]);
    var r = 0.0, g = 0.0, b = 0.0, n = 0;
    // Every fourth pixel each way is plenty for a colour.
    for (var y = 0; y < height; y += 4) {
      for (var x = 0; x < width; x += 4) {
        final i = (y * width + x) * 4;
        if (rgba.getUint8(i + 3) < 128) {
          continue;
        }
        final color = Color.fromARGB(
          255,
          rgba.getUint8(i),
          rgba.getUint8(i + 1),
          rgba.getUint8(i + 2),
        );
        r += color.r;
        g += color.g;
        b += color.b;
        n++;
        final hsv = HSVColor.fromColor(color);
        if (hsv.saturation < 0.2 || hsv.value < 0.18) {
          continue;
        }
        final bucket = (hsv.hue / 360 * hues).floor() % hues;
        final w = hsv.saturation * hsv.value;
        weight[bucket] += w;
        sums[bucket][0] += color.r * w;
        sums[bucket][1] += color.g * w;
        sums[bucket][2] += color.b * w;
      }
    }
    if (n == 0) {
      return null;
    }
    var best = 0;
    for (var i = 1; i < hues; i++) {
      if (weight[i] > weight[best]) {
        best = i;
      }
    }
    // Colour has to make up a real share of the art to lead it.
    if (weight[best] < n * 0.04) {
      return Color.from(alpha: 1, red: r / n, green: g / n, blue: b / n);
    }
    final w = weight[best];
    return Color.from(
      alpha: 1,
      red: sums[best][0] / w,
      green: sums[best][1] / w,
      blue: sums[best][2] / w,
    );
  }
}

/// Builds with a brand's art palette: the drawn card's colours at first, then
/// easing into the art's own once they are read, so a page never flashes.
class ArtPaletteBuilder extends StatefulWidget {
  const ArtPaletteBuilder({
    super.key,
    required this.brand,
    required this.builder,
  });

  final CardBrand? brand;
  final Widget Function(BuildContext context, ArtPalette palette) builder;

  @override
  State<ArtPaletteBuilder> createState() => _ArtPaletteBuilderState();
}

class _ArtPaletteBuilderState extends State<ArtPaletteBuilder> {
  ArtPalette? _palette;

  static const _plain = ArtPalette(
    light: Color(0xFF0F766E),
    dark: Color(0xFF064E3B),
    tint: Color(0xFF0F766E),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _read();
  }

  @override
  void didUpdateWidget(ArtPaletteBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.brand?.logo != widget.brand?.logo) {
      _read();
    }
  }

  void _read() {
    final brand = widget.brand;
    if (brand == null) {
      return;
    }
    ArtPalette.of(context, brand).then((palette) {
      if (mounted && palette != null && widget.brand?.logo == brand.logo) {
        setState(() => _palette = palette);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final brand = widget.brand;
    final start = brand == null ? _plain : ArtPalette.drawn(brand);
    final target = _palette ?? start;
    return TweenAnimationBuilder<double>(
      key: ValueKey(_palette == null),
      tween: Tween(begin: 0, end: 1),
      duration: _palette == null ? Duration.zero : CardsMotion.emphasized,
      curve: CardsMotion.curve,
      builder: (context, t, _) =>
          widget.builder(context, ArtPalette.lerp(start, target, t)),
    );
  }
}
