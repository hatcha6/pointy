import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/models/catalog.dart';
import '../data/repositories/catalog_repository.dart';
import 'art_cache.dart';

/// How much decoded art memory holds. A tile takes about half a megabyte, so
/// this is most of the shelf; Flutter's own limit of 100 MB held 170 tiles,
/// and scrolling past them threw the first ones out to be decoded again.
const int kArtMemoryBytes = 256 << 20;

/// Decodes the art this device already has into memory, before any of it is
/// scrolled to, so that a card is on screen the moment it is reached. Only
/// what is stored is read: nothing here spends the customer's data.
class ArtPreloader with WidgetsBindingObserver {
  ArtPreloader({
    required this.catalog,
    Future<bool> Function(String url)? isStored,
    Future<void> Function(ImageProvider image)? decode,
    int Function()? memoryUsed,
    this.picture = artImage,
  }) : _isStored = isStored ?? _storedInArtCache,
       _decode = decode ?? _decodeIntoMemory,
       _memoryUsed =
           memoryUsed ??
           (() => PaintingBinding.instance.imageCache.currentSizeBytes);

  final CatalogRepository catalog;
  final ImageProvider Function(String url, {int? width}) picture;
  final Future<bool> Function(String url) _isStored;
  final Future<void> Function(ImageProvider image) _decode;
  final int Function() _memoryUsed;

  /// Decoding side by side, in the engine's background threads.
  static const _parallel = 4;

  /// Room left for what is on screen and being opened.
  static const _budget = kArtMemoryBytes * 7 ~/ 8;

  /// Enough to fill the first screen, whichever row it opens on.
  static const _firstScreen = 40;
  static const _firstScreenWait = Duration(milliseconds: 700);

  /// Raises memory's limit for the art.
  static void prepareMemory() {
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = kArtMemoryBytes
      ..maximumSize = 4000;
  }

  /// Readies what the app opens on before its first frame: the system's
  /// splash stays up a moment longer, and the shelf comes up whole. Never
  /// longer than [_firstScreenWait], whatever the device.
  Future<void> prepareFirstScreen() async {
    try {
      final shelf = await catalog.cached();
      if (shelf == null) {
        return;
      }
      await _read(
        shelf,
        preloadOrder(shelf.brands).take(_firstScreen),
        keepGoing: () => true,
      ).timeout(_firstScreenWait);
    } on Object {
      // The shelf loads its art the ordinary way.
    }
  }

  CardCatalog? _shelf;
  bool _running = false;
  bool _stopped = false;

  /// Reads [shelf]'s art; a newer shelf replaces whatever is left of an
  /// older one's.
  Future<void> preload(CardCatalog shelf) async {
    if (identical(shelf, _shelf) || shelf.brands.isEmpty) {
      return;
    }
    _shelf = shelf;
    if (_running || _stopped) {
      return;
    }
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    try {
      CardCatalog? done;
      while (!_stopped && !identical(done, _shelf)) {
        done = _shelf;
        final shelf = done!;
        await _read(
          shelf,
          preloadOrder(shelf.brands),
          keepGoing: () => !_stopped && identical(shelf, _shelf),
        );
      }
    } finally {
      WidgetsBinding.instance.removeObserver(this);
      _running = false;
    }
  }

  Future<void> _read(
    CardCatalog shelf,
    Iterable<CardBrand> brands, {
    required bool Function() keepGoing,
  }) async {
    final queue = brands.iterator;
    Future<void> worker() async {
      while (keepGoing() && _memoryUsed() < _budget && queue.moveNext()) {
        final brand = queue.current;
        final url = catalog.imageUrl(brand.logo).toString();
        try {
          if (await _isStored(url)) {
            await _decode(picture(url, width: artTileWidth));
            // A featured card's tile fills the screen's width.
            if (brand.featured) {
              await _decode(picture(url));
            }
          }
        } catch (_) {
          // A picture that cannot be read loads when it is shown, or falls
          // back to the drawn card there.
        }
      }
    }

    await Future.wait([for (var i = 0; i < _parallel; i++) worker()]);
  }

  /// The system is short of memory and Flutter has emptied the image cache:
  /// filling it again would only make things worse.
  @override
  void didHaveMemoryPressure() => _stopped = true;

  /// The order a customer reaches art in: the featured, then each category's
  /// first card, then each one's second. Scrolling down a shelf meets the
  /// head of every row long before the end of any.
  @visibleForTesting
  static List<CardBrand> preloadOrder(List<CardBrand> brands) {
    final rows = <String, List<CardBrand>>{};
    final sorted = [...brands.where((brand) => brand.logo.isNotEmpty)]
      ..sort((a, b) => a.rank.compareTo(b.rank));
    for (final brand in sorted) {
      (rows[brand.category] ??= []).add(brand);
    }
    final order = sorted.where((brand) => brand.featured).toList();
    final seen = order.toSet();
    final longest = rows.values.fold<int>(
      0,
      (most, row) => row.length > most ? row.length : most,
    );
    for (var i = 0; i < longest; i++) {
      for (final row in rows.values) {
        if (i < row.length && seen.add(row[i])) {
          order.add(row[i]);
        }
      }
    }
    return order;
  }

  static Future<bool> _storedInArtCache(String url) async =>
      await artCache.getFileFromCache(url) != null;

  static Future<void> _decodeIntoMemory(ImageProvider image) {
    final done = Completer<void>();
    final stream = image.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void finish() {
      stream.removeListener(listener);
      if (!done.isCompleted) {
        done.complete();
      }
    }

    listener = ImageStreamListener(
      (_, _) => finish(),
      onError: (_, _) {
        image.evict();
        finish();
      },
    );
    stream.addListener(listener);
    return done.future;
  }
}
