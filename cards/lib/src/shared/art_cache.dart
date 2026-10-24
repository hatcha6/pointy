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
    maxNrOfCacheObjects: 600,
  ),
);
