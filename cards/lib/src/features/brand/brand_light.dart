import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/tilt_card.dart';

/// The brand page's light: the card's own colours, cast like YouTube's
/// ambient mode around a video. It fills the top of the page behind the
/// card, under the status bar too, and dissolves into the page below it.
///
/// It is on only while the page is settled. While the page slides in, or a
/// back swipe or the back button takes it away, the card is in flight and a
/// light left behind on the page would hang there without it.
class SettledLight extends StatefulWidget {
  const SettledLight({super.key, required this.builder});

  final Widget Function(BuildContext context, Animation<double> light) builder;

  @override
  State<SettledLight> createState() => _SettledLightState();
}

class _SettledLightState extends State<SettledLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    reverseDuration: CardsMotion.press,
  );
  late final Animation<double> _curved = CurvedAnimation(
    parent: _light,
    curve: CardsMotion.curve,
  );
  Animation<double>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (route != _route) {
      _route?.removeStatusListener(_onRoute);
      _route = route?..addStatusListener(_onRoute);
      _onRoute(route?.status ?? AnimationStatus.completed);
    }
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onRoute);
    _light.dispose();
    super.dispose();
  }

  /// Settled in place: light up. Anything else (arriving, leaving, a swipe
  /// pulling the page back): out at once, before the card leaves.
  void _onRoute(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _light.forward();
    } else {
      _light.reverse();
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _curved);
}

/// The ambient light itself: the art blown up past the screen's edges,
/// blurred to pure colour and a little richer, fading out downwards. It
/// scrolls away with the card.
class AmbientLight extends StatelessWidget {
  const AmbientLight({
    super.key,
    required this.brand,
    required this.light,
    required this.scroll,
    required this.height,
  });

  final CardBrand brand;
  final Animation<double> light;
  final ScrollController scroll;

  /// How far down the page the light reaches before it has faded out.
  final double height;

  /// A touch more saturation, the way ambient light reads richer than the
  /// picture it comes from.
  static const _richer = ColorFilter.matrix([
    1.21, -0.19, -0.02, 0, 0, //
    -0.06, 1.14, -0.02, 0, 0, //
    -0.06, -0.19, 1.25, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  /// The art reaches this far past every edge before the blur, so the blur
  /// never pulls in emptiness and darkens the sides.
  static const double _bleed = 120;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // A hint of colour, not a wash: the card stays the brightest thing.
    final strength = (dark ? 0.36 : 0.24) * (brand.anyAvailable ? 1 : 0.35);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([light, scroll]),
        builder: (context, child) {
          // Exactly one view: while the page turns between its narrow and
          // wide layouts, two may be attached for a frame, and `offset`
          // would throw.
          final offset = scroll.positions.length == 1
              ? scroll.offset.clamp(0.0, height)
              : 0.0;
          return Transform.translate(
            offset: Offset(0, -offset),
            child: Opacity(opacity: light.value * strength, child: child),
          );
        },
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.4, 1],
              colors: [Colors.white, Color(0x8CFFFFFF), Colors.transparent],
            ).createShader(rect),
            child: ClipRect(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 64, sigmaY: 64),
                child: LayoutBuilder(
                  builder: (context, constraints) => OverflowBox(
                    maxWidth: constraints.maxWidth + _bleed * 2,
                    maxHeight: constraints.maxHeight + _bleed * 2,
                    child: ColorFiltered(
                      colorFilter: _richer,
                      child: CardArtImage(brand: brand),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card on the page, the way Apple Wallet shows a pass: the one object
/// at the top, at its real 16:10 shape and never larger than its art. Under
/// it, a closer, brighter pool of its light, so it sits in the ambient light
/// rather than on top of it.
class BrandCardStage extends StatelessWidget {
  const BrandCardStage({
    super.key,
    required this.brand,
    required this.heroTag,
    required this.width,
    required this.light,
  });

  final CardBrand brand;
  final String heroTag;
  final double width;
  final Animation<double> light;

  static const EdgeInsets padding = EdgeInsets.only(
    top: CardsSpace.sm,
    bottom: CardsSpace.xxl,
  );

  /// Clear of the page's sides, and never wider than the art's 800 pixels
  /// at this screen's density: shown at its own sharpness, never blown up.
  static double cardWidthFor(MediaQueryData media) {
    final sharp = 800 / media.devicePixelRatio;
    return math.min(
      media.size.width - CardsSpace.gutter * 4,
      math.max(sharp, 240.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = width / kCardAspect;
    return Padding(
      padding: padding,
      child: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // The pool: the art, smaller, lower and blurred to nothing at
              // its edges (decal), spreading out from under the card.
              Positioned.fill(
                top: height * 0.18,
                bottom: -height * 0.14,
                left: width * 0.06,
                right: width * 0.06,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: light,
                    builder: (context, child) => Opacity(
                      opacity: light.value * (brand.anyAvailable ? 0.5 : 0.2),
                      child: Transform.translate(
                        offset: Offset(0, (light.value - 1) * height * 0.12),
                        child: Transform.scale(
                          scale: 0.9 + light.value * 0.1,
                          child: child,
                        ),
                      ),
                    ),
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: 22,
                        sigmaY: 22,
                        tileMode: TileMode.decal,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(CardsRadii.tile),
                        child: CardArtImage(brand: brand),
                      ),
                    ),
                  ),
                ),
              ),
              // Flat in flight; it answers the phone's tilt once landed.
              TiltCard(
                radius: CardsRadii.tile,
                strength: light,
                child: Hero(
                  tag: heroTag,
                  createRectTween: cardRectTween,
                  transitionOnUserGestures: true,
                  child: CardArt(
                    brand: brand,
                    radius: CardsRadii.tile,
                    muted: !brand.anyAvailable,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
