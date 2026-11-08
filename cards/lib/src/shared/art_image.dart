import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';
import 'art_cache.dart';

/// A catalog picture filling its box. One already in memory is on screen in
/// the very frame it is built, with no placeholder and no fade. A box wider
/// than a tile gets the stored size on top of the tile's, so it starts sharp
/// enough and only ever gets sharper.
class ArtImage extends StatelessWidget {
  const ArtImage({super.key, required this.url, required this.fallback});

  final String url;

  /// Shown until the picture has come, and for good when it cannot.
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final tile = ArtPicture(
          image: artImage(url, width: artTileWidth),
          under: fallback,
        );
        return constraints.maxWidth * ratio > artTileWidth * 1.2
            ? ArtPicture(image: artImage(url), under: tile)
            : tile;
      },
    );
  }
}

/// [image] over [under]: at once when it is in memory, eased in when it had
/// to be loaded.
class ArtPicture extends StatelessWidget {
  const ArtPicture({super.key, required this.image, required this.under});

  final ImageProvider image;
  final Widget under;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: image,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          return child;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            under,
            AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: CardsMotion.fast,
              child: child,
            ),
          ],
        );
      },
      errorBuilder: (context, error, stack) {
        // The memory holds on to a failure until told to forget it: the next
        // time this picture is built, it tries again.
        image.evict();
        return under;
      },
    );
  }
}
