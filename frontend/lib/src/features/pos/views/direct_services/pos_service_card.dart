import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../voucher_card_art.dart';
import 'service_card_art.dart';
import 'service_texts.dart';

/// One direct service drawn like a gift card on a shop's rack: its art
/// full-bleed, a «جديد» sticker on the art's edge, then its name, a one-line
/// promise of what it does, and how far it reaches.
///
/// The same footprint, proportions and press feel as [PosVoucherBrandCard],
/// so a row of them above the brands reads as part of the same shelf — and
/// explains itself, because a service the shop has never sold needs saying.
///
/// Public so the preview harness, the capture test and widget tests can draw
/// one without a menu behind it.
class PosServiceCard extends StatefulWidget {
  const PosServiceCard({
    super.key,
    required this.kind,
    this.countries = 0,
    this.providers = 0,
    this.onTap,
    this.showsNewBadge = true,
    this.dense = false,
  });

  final ServiceCardKind kind;

  /// How many countries and providers stand behind it, for its caption; zero
  /// leaves the caption out.
  final int countries;
  final int providers;

  /// Null on a till that cannot sell.
  final VoidCallback? onTap;
  final bool showsNewBadge;

  /// A shorter card, for a screen with little height: the reach caption goes,
  /// the name and the promise stay.
  final bool dense;

  /// Height of everything under the art, the same on every card.
  static const double infoHeight = 122;
  static const double denseInfoHeight = 90;

  static double infoHeightFor(TextScaler scaler, {bool dense = false}) {
    final base = dense ? denseInfoHeight : infoHeight;
    return math.max(base, scaler.scale(base));
  }

  /// How tall a card [width] wide is.
  static double extentFor(
    double width, {
    TextScaler scaler = TextScaler.noScaling,
    bool dense = false,
  }) => width / kVoucherArtAspectRatio + infoHeightFor(scaler, dense: dense);

  @override
  State<PosServiceCard> createState() => _PosServiceCardState();
}

class _PosServiceCardState extends State<PosServiceCard> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final enabled = widget.onTap != null;
    final lifted = enabled && (_hovered || _focused);
    final title = serviceCardTitle(l10n, widget.kind);
    final promise = serviceCardPromise(l10n, widget.kind);
    final caption = widget.dense
        ? null
        : serviceCardCaption(
            l10n,
            widget.kind,
            countries: widget.countries,
            providers: widget.providers,
          );

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
        child: ServiceCardArt(kind: widget.kind),
      ),
    );

    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: kVoucherArtAspectRatio,
          child: AnimatedSlide(
            duration: PointyMotion.fast,
            curve: PointyMotion.curve,
            offset: Offset(0, lifted ? -0.025 : 0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: art),
                if (widget.showsNewBadge)
                  PositionedDirectional(
                    start: 10,
                    bottom: -11,
                    child: VoucherSticker(
                      tone: VoucherStickerTone.promo,
                      label: l10n.posServicesNewBadge,
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: PosServiceCard.infoHeightFor(
            MediaQuery.textScalerOf(context),
            dense: widget.dense,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              2,
              widget.dense ? 15 : 17,
              2,
              2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: Text(
                    promise,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                      fontSize: widget.dense ? 11.5 : null,
                      height: widget.dense ? 1.3 : 1.35,
                    ),
                  ),
                ),
                if (caption != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.primaryStrong,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: '$title. $promise',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: widget.onTap,
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
}
