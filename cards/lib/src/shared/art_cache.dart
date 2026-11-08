import 'dart:ui' show PlatformDispatcher;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The device's store of catalog art: brand logos and flags.
///
/// An image's address is its content hash (`/v1/customers/images/<sha256>`),
/// so a stored copy is never out of date: changed art is a new address, and
/// the old file simply stops being asked for. So the art is kept for a year
/// after it was last shown, room is left for every logo and flag of the shelf
/// several times over, and it has a store of its own so no other image can
/// push it out. The relay answers these with `immutable`, so a browser keeps
/// them just as long on the web build.
final CacheManager artCache = CacheManager(
  Config(
    'cards_art',
    stalePeriod: const Duration(days: 365),
    maxNrOfCacheObjects: 4000,
  ),
);

/// How wide, in pixels, art is decoded for a tile on this device: one size
/// everywhere, so a card decoded once is ready wherever it is shown next.
/// The stored art is 800 wide, and held at that size a shelf would not fit
/// in memory.
final int artTileWidth = _tileWidth();

int _tileWidth() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) {
    return 480;
  }
  final view = views.first;
  final side = view.physicalSize.shortestSide / view.devicePixelRatio;
  final tile = side < 600 ? 164.0 : 200.0;
  return (tile * view.devicePixelRatio).ceil().clamp(240, 600);
}

/// A picture of [url] from [artCache]: at the size given, or the stored size.
ImageProvider artImage(String url, {int? width}) {
  final stored = CachedNetworkImageProvider(url, cacheManager: artCache);
  return width == null ? stored : ResizeImage(stored, width: width);
}
