import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../data/models/catalog.dart';
import '../design/cards_tokens.dart';
import 'art_cache.dart';
import 'cards_scope.dart';

/// Card art is 16:10, like a gift card on a rack.
const double kCardAspect = 16 / 10;

/// A brand's card: the art the company uploaded, or a drawn card with the
/// brand's name when it has none or it has not loaded. [muted] greys a brand
/// that cannot be bought right now: still on the rack, its prices readable.
class CardArt extends StatelessWidget {
  const CardArt({
    super.key,
    required this.brand,
    this.radius = CardsRadii.card,
    this.muted = false,
    this.shadow = true,
  });

  final CardBrand brand;
  final double radius;
  final bool muted;
  final bool shadow;

  static const _greyscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    Widget art = CardArtImage(brand: brand);
    if (muted) {
      art = Opacity(
        opacity: 0.55,
        child: ColorFiltered(colorFilter: _greyscale, child: art),
      );
    }
    return AspectRatio(
      aspectRatio: kCardAspect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: shadow && !muted ? CardsShadows.art : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: art,
        ),
      ),
    );
  }
}

/// The art alone, filling whatever box it is given (cropped, never
/// stretched): the card on a rack, or the whole header of the brand's page.
class CardArtImage extends StatelessWidget {
  const CardArtImage({super.key, required this.brand});

  final CardBrand brand;

  @override
  Widget build(BuildContext context) {
    final fallback = DrawnCard(brand: brand);
    if (brand.logo.isEmpty) {
      return fallback;
    }
    return CachedNetworkImage(
      imageUrl: CardsScope.of(context).catalog.imageUrl(brand.logo).toString(),
      cacheManager: artCache,
      fit: BoxFit.cover,
      fadeInDuration: CardsMotion.fast,
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

/// The colour a brand's page is tinted with: its category's, the way album
/// art tints Apple Music's pages.
Color brandTint(CardBrand brand) => DrawnCard.palette(brand.category).$1;

class DrawnCard extends StatelessWidget {
  const DrawnCard({super.key, required this.brand});

  final CardBrand brand;

  static (Color, Color) palette(String category) => switch (category) {
    'telecom' ||
    'intl_topup' => (const Color(0xFF0F766E), const Color(0xFF064E3B)),
    'internet' => (const Color(0xFF1D4ED8), const Color(0xFF1E3A8A)),
    'gaming' => (const Color(0xFF7E22CE), const Color(0xFF3B0764)),
    'tv' => (const Color(0xFFB42318), const Color(0xFF55160C)),
    _ => (const Color(0xFFC98A3B), const Color(0xFF7A4B12)),
  };

  @override
  Widget build(BuildContext context) {
    final (light, dark) = palette(brand.category);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [light, dark],
            ),
          ),
          child: Stack(
            children: [
              PositionedDirectional(
                start: 0,
                end: 0,
                top: width * 0.16,
                child: Container(
                  height: width * 0.07,
                  color: PointyColors.accentAmber,
                ),
              ),
              PositionedDirectional(
                start: width * 0.07,
                end: width * 0.07,
                bottom: width * 0.08,
                child: Text(
                  brand.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: (width * 0.1).clamp(12, 28),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
