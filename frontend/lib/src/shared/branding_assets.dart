import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

/// Loads the monochrome brand mark (assets/branding/logo_black.png) as small
/// PNG bytes for the printed "دُوِّنَ في دفتر" tagline.
///
/// The bundled asset is large (print-quality); embedding it verbatim would bloat
/// every invoice PDF and slow the thermal raster, so it is decoded and downscaled
/// once, then cached process-wide. Both print paths share the cache: the PDF path
/// embeds these bytes directly (scaled down by the layout), and the ESC/POS path
/// downscales them again to its raster width.
///
/// Loading is best-effort — a missing asset or a test harness without a bundle
/// yields `null`, and callers fall back to a text-only tagline.
class PointyBrandLogoLoader {
  const PointyBrandLogoLoader();

  static const String _asset = 'assets/branding/logo_black.png';

  /// Target width for the cached mark. Small enough to keep PDFs light, large
  /// enough that both a 200-dpi thermal head and an A4 print stay crisp.
  static const int _targetWidth = 240;

  static Uint8List? _cache;

  Future<Uint8List?> load() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    try {
      final data = await rootBundle.load(_asset);
      final decoded = img.decodeImage(data.buffer.asUint8List());
      if (decoded == null) {
        // Asset read but undecodable — a bad file, not a transient error.
        return null;
      }
      final scaled = decoded.width > _targetWidth
          ? img.copyResize(decoded, width: _targetWidth)
          : decoded;
      return _cache = Uint8List.fromList(img.encodePng(scaled));
    } on Object {
      // Transient (e.g. loaded before the binding is ready) — don't cache the
      // failure; a later call retries.
      return null;
    }
  }
}
