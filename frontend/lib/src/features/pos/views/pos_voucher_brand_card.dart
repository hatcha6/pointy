import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/voucher_menu.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import 'voucher_card_art.dart';
import 'voucher_country_flag.dart';

/// One brand on the «كروت دفتر» menu, drawn like a gift card on a shop's rack:
/// the card art full-bleed, a sticker on its edge for a promotion or a brand
/// the company features, then the name, what it costs, and the flags of the
/// countries its cards are for.
///
/// Public so the preview harness, the capture test and widget tests can draw
/// one without a menu behind it.
class PosVoucherBrandCard extends StatefulWidget {
  const PosVoucherBrandCard({
    super.key,
    required this.brand,
    required this.countryFor,
    this.onTap,
  });

  final VoucherBrand brand;

  /// The country a code names, with its Arabic name and flag.
  final VoucherCountry Function(String code) countryFor;

  /// Null for a brand that cannot be sold, or a till that cannot sell.
  final VoidCallback? onTap;

  /// Height of everything under the art, the same on every card so a row of
  /// them lines up whatever each one says.
  static const double infoHeight = 94;

  /// [infoHeight] at the device's text size: a till set to larger text grows
  /// the block with it instead of clipping the price.
  static double infoHeightFor(TextScaler scaler) =>
      math.max(infoHeight, scaler.scale(infoHeight));

  /// How tall a card [width] wide is.
  static double extentFor(
    double width, {
    TextScaler scaler = TextScaler.noScaling,
  }) => width / kVoucherArtAspectRatio + infoHeightFor(scaler);

  /// At most this many flags; the rest are counted.
  static const int maxFlags = 4;

  @override
  State<PosVoucherBrandCard> createState() => _PosVoucherBrandCardState();
}

class _PosVoucherBrandCardState extends State<PosVoucherBrandCard> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  void didUpdateWidget(covariant PosVoucherBrandCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onTap == null && (_hovered || _pressed)) {
      _hovered = false;
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final brand = widget.brand;
    final available = brand.isAvailable;
    final enabled = widget.onTap != null && available;
    final lifted = enabled && (_hovered || _focused);
    final price = _priceLine(l10n, brand);

    final art = AnimatedContainer(
      duration: PointyMotion.fast,
      curve: PointyMotion.curve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: lifted ? 0.20 : 0.10),
            blurRadius: lifted ? 18 : 10,
            spreadRadius: -2,
            offset: Offset(0, lifted ? 9 : 4),
          ),
        ],
      ),
      // The keyboard's place: a ring drawn over the art, moving with it, so
      // focusing never shifts anything else.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused && enabled
              ? colors.primaryStrong
              : colors.primaryStrong.withValues(alpha: 0),
          width: 2.5,
        ),
      ),
      child: AnimatedScale(
        duration: PointyMotion.fast,
        scale: _pressed ? 0.98 : 1,
        child: VoucherCardArt(brand: brand, muted: !available),
      ),
    );

    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: kVoucherArtAspectRatio,
          // The art and its stickers rise together under the mouse or the
          // keyboard, the way a card is lifted off a rack.
          child: AnimatedSlide(
            duration: PointyMotion.fast,
            curve: PointyMotion.curve,
            offset: Offset(0, lifted ? -0.025 : 0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: art),
                // Stuck on the art's lower edge, where card art carries the
                // least: never over the brand's own logo.
                PositionedDirectional(
                  start: 10,
                  end: 10,
                  bottom: -11,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _Stickers(brand: brand, available: available),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: PosVoucherBrandCard.infoHeightFor(
            MediaQuery.textScalerOf(context),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(2, 17, 2, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  brand.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: available ? colors.ink : colors.mutedInk,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const Spacer(),
                if (price != null)
                  Text(
                    price,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PointyTypography.numeric(
                      (textTheme.titleSmall ?? const TextStyle()).copyWith(
                        color: available
                            ? colors.primaryStrong
                            : colors.mutedInk,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 16,
                  child: _Countries(
                    codes: brand.countryCodes,
                    countryFor: widget.countryFor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: available ? 1 : 0.62,
        child: InkWell(
          onTap: enabled ? widget.onTap : null,
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) => setState(() => _focused = value),
          onHighlightChanged: (value) => setState(() => _pressed = value),
          borderRadius: BorderRadius.circular(14),
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: card,
        ),
      ),
    );
  }

  /// «من 15.00 د.ل» across denominations, the one price when there is one.
  static String? _priceLine(AppLocalizations l10n, VoucherBrand brand) {
    final range = brand.priceRange;
    if (range == null) {
      return null;
    }
    if ((range.max - range.min).abs() < 0.005) {
      return formatMoney(range.min);
    }
    return l10n.posVoucherMenuPriceFrom(formatMoney(range.min));
  }
}

/// A promotion in amber, a featured brand in teal — both when both hold, the
/// featured one shrunk to its star; «غير متوفر» alone when nothing sells.
class _Stickers extends StatelessWidget {
  const _Stickers({required this.brand, required this.available});

  final VoucherBrand brand;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!available) {
      return VoucherSticker(
        tone: VoucherStickerTone.muted,
        label: l10n.posVoucherMenuUnavailable,
      );
    }
    final promo = brand.onPromo
        ? (brand.promoBadge ?? l10n.posVoucherMenuPromo)
        : null;
    final featuredLabel = brand.badge.isNotEmpty
        ? brand.badge
        : (brand.featured ? l10n.posVoucherMenuFeatured : null);
    if (promo == null && featuredLabel == null) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (promo != null)
          Flexible(
            child: VoucherSticker(tone: VoucherStickerTone.promo, label: promo),
          ),
        if (promo != null && featuredLabel != null) const SizedBox(width: 4),
        if (featuredLabel != null)
          Flexible(
            child: VoucherSticker(
              tone: VoucherStickerTone.featured,
              label: promo == null ? featuredLabel : null,
              tooltip: promo == null ? null : featuredLabel,
            ),
          ),
      ],
    );
  }
}

/// The flags of the countries a brand's cards are for: one with its name when
/// there is only one, up to [PosVoucherBrandCard.maxFlags] and a count when
/// there are more.
class _Countries extends StatelessWidget {
  const _Countries({required this.codes, required this.countryFor});

  final List<String> codes;
  final VoucherCountry Function(String code) countryFor;

  @override
  Widget build(BuildContext context) {
    if (codes.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.labelSmall?.copyWith(
      color: colors.mutedInk,
      fontWeight: FontWeight.w600,
      height: 1.1,
    );
    if (codes.length == 1) {
      final country = countryFor(codes.single);
      return Row(
        children: [
          VoucherCountryFlag(country: country, width: 21, height: 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              country.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
      );
    }
    final shown = codes.take(PosVoucherBrandCard.maxFlags).toList();
    final more = codes.length - shown.length;
    return Semantics(
      label: [for (final code in codes) countryFor(code).label].join('، '),
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (final code in shown) ...[
              VoucherCountryFlag(
                country: countryFor(code),
                width: 21,
                height: 14,
              ),
              const SizedBox(width: 4),
            ],
            if (more > 0)
              // Left to right, or an Arabic line turns «+2» into «2+».
              Text(
                l10n.posVoucherMenuMoreCountries(more),
                textDirection: TextDirection.ltr,
                style: muted,
              ),
          ],
        ),
      ),
    );
  }
}
