import 'package:flutter/material.dart';

import '../../../data/models/voucher_menu.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/design/design.dart';

/// Gift cards are wider than tall: the company's card art is 16:10.
const double kVoucherArtAspectRatio = 16 / 10;

/// A brand's card art, full-bleed in a rounded frame with a hairline border —
/// the display logo the company uploaded, or a drawn card when it has none.
///
/// No padding box around the art: it is the card, the way a gift card on a
/// shop's rack is. [muted] greys it out for a brand that cannot be sold now.
class VoucherCardArt extends StatelessWidget {
  const VoucherCardArt({
    super.key,
    required this.brand,
    this.radius = 12,
    this.muted = false,
  });

  final VoucherBrand brand;
  final double radius;
  final bool muted;

  static const _greyscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final fallback = VoucherFallbackArt(brand: brand);
    final url = brand.logoUrl;
    Widget art = url == null
        ? fallback
        : PointyProductImageFrame(
            imageUrl: url,
            fallbackText: brand.displayName,
            fit: BoxFit.cover,
            padding: EdgeInsets.zero,
            borderRadius: 0,
            backgroundColor: colors.subtleFill,
            fallback: fallback,
          );
    if (muted) {
      art = ColorFiltered(colorFilter: _greyscale, child: art);
    }
    final shape = BorderRadius.circular(radius);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: shape),
      foregroundDecoration: BoxDecoration(
        borderRadius: shape,
        border: Border.all(color: colors.ink.withValues(alpha: 0.10)),
      ),
      child: art,
    );
  }
}

/// The card a brand without art still gets: a gradient in one of the
/// palette's hues (picked by the brand, so neighbours differ), a soft sheen,
/// the brand's initial as a monogram and a gift-card mark. Drawn, not
/// placeholder-grey, so a shelf of brands without logos still looks stocked.
class VoucherFallbackArt extends StatelessWidget {
  const VoucherFallbackArt({super.key, required this.brand});

  final VoucherBrand brand;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tones = [
      colors.primary,
      colors.paymentCard,
      colors.paymentTransfer,
      colors.accentAmber,
      colors.paymentCash,
    ];
    final seed = brand.key.isEmpty ? brand.displayName : brand.key;
    final hash = seed.codeUnits.fold<int>(
      7,
      (value, unit) => (value * 31 + unit) & 0x7fffffff,
    );
    final tone = HSLColor.fromColor(tones[hash % tones.length]);
    final saturated = tone.withSaturation(tone.saturation.clamp(0.42, 0.78));
    final light = saturated.withLightness(0.40).toColor();
    final deep = saturated.withLightness(0.24).toColor();
    final initial = _monogramOf(brand.displayName);

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.maxWidth / kVoucherArtAspectRatio;
        final monogram = (height * 0.5).clamp(18.0, 120.0);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [light, deep],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The sheen and the two rings a printed card carries.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.9, -1.1),
                    radius: 1.1,
                    colors: [
                      Colors.white.withValues(alpha: 0.22),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
              PositionedDirectional(
                end: -height * 0.35,
                bottom: -height * 0.55,
                child: _Ring(diameter: height * 1.25, alpha: 0.10),
              ),
              PositionedDirectional(
                end: -height * 0.05,
                bottom: -height * 0.75,
                child: _Ring(diameter: height * 1.05, alpha: 0.07),
              ),
              PositionedDirectional(
                top: height * 0.11,
                end: height * 0.11,
                child: Icon(
                  Icons.card_giftcard_rounded,
                  size: (height * 0.17).clamp(12.0, 32.0),
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              Center(
                child: Container(
                  width: monogram * 1.5,
                  height: monogram * 1.5,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.38),
                      width: 1.2,
                    ),
                  ),
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontFamily: PointyTypography.fontFamily,
                      fontSize: monogram * 0.78,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
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

/// The letter a brand is known by: «المدار» is «م», not the article's «ا».
String _monogramOf(String name) {
  var text = name.trim();
  if (text.startsWith('ال') && text.characters.length > 3) {
    text = text.substring(2);
  }
  return text.isEmpty ? '' : text.characters.first;
}

class _Ring extends StatelessWidget {
  const _Ring({required this.diameter, required this.alpha});

  final double diameter;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: alpha * 2),
          width: diameter * 0.06,
        ),
        color: Colors.white.withValues(alpha: alpha * 0.4),
      ),
    );
  }
}

/// What a sticker on a card says: a promotion, a brand the company features,
/// or that nothing of it can be sold now.
enum VoucherStickerTone { promo, featured, muted }

/// A small pill stuck on a card's edge — warm amber for a promotion, brand
/// teal with a gold star for a featured brand. Its outline is the surface's
/// colour, so it reads as cut out whether it sits on the art or beside it.
class VoucherSticker extends StatelessWidget {
  const VoucherSticker({
    super.key,
    required this.tone,
    this.label,
    this.tooltip,
  });

  final VoucherStickerTone tone;

  /// Null draws the icon alone (a featured star beside a promotion).
  final String? label;

  /// What a hover or a screen reader says when [label] is not drawn.
  final String? tooltip;

  static const _gold = Color(0xFFFFC94D);

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final background = switch (tone) {
      VoucherStickerTone.promo => colors.accentAmber,
      VoucherStickerTone.featured => colors.primary,
      VoucherStickerTone.muted => colors.surfaceSunken,
    };
    final foreground = switch (tone) {
      VoucherStickerTone.muted => colors.mutedInk,
      _ =>
        ThemeData.estimateBrightnessForColor(background) == Brightness.light
            ? const Color(0xFF241600)
            : Colors.white,
    };
    final icon = switch (tone) {
      VoucherStickerTone.promo => Icons.local_offer_rounded,
      VoucherStickerTone.featured => Icons.star_rounded,
      VoucherStickerTone.muted => Icons.block_rounded,
    };
    final iconColor = tone == VoucherStickerTone.featured ? _gold : foreground;
    final label = this.label;
    final iconOnly = label == null || label.isEmpty;

    final sticker = Container(
      height: 22,
      constraints: const BoxConstraints(minWidth: 22),
      padding: EdgeInsetsDirectional.only(
        start: iconOnly ? 0 : 6,
        end: iconOnly ? 0 : 8,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
        border: Border.all(color: colors.surface, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.16),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 13, color: iconColor),
          if (!iconOnly) ...[
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    final message = tooltip;
    if (message == null || message.isEmpty) {
      return sticker;
    }
    return Tooltip(message: message, child: sticker);
  }
}
