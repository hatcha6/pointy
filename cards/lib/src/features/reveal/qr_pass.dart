import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/haptics.dart';
import '../../shared/tilt_card.dart';
import 'card_faces.dart';
import 'scratch_off.dart';
import '../../core/analytics/analytics.dart';

/// The card held up for a scanner, the way a wallet shows a pass: it lifts out
/// of the page into the middle of the screen, as it is, while the page dims
/// away behind it and the screen brightens. The first time, the foil over its
/// QR is scratched off once it lands. Closing sets it back down.
class QrPass {
  const QrPass._();

  /// Turns the brightness up while a pass shows, and gives the phone its own
  /// back after. Tests swap in their own.
  @visibleForTesting
  static ({Future<void> Function() up, Future<void> Function() down})
  brightness = (
    up: () => ScreenBrightness.instance.setApplicationScreenBrightness(1),
    down: () => ScreenBrightness.instance.resetApplicationScreenBrightness(),
  );

  /// Opens the pass from the card at [from] (its box on screen), and
  /// completes once it is set back down. [scratch] is whether its QR is still
  /// under the foil.
  static Future<void> open(
    BuildContext context, {
    required Rect from,
    required CardBrand brand,
    required ArtPalette palette,
    required String code,
    required bool used,
    required VoidCallback onCopy,
    required bool scratch,
  }) {
    Haptics.tap();
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        settings: screenSettings('qr_pass'),
        opaque: false,
        barrierDismissible: true,
        barrierLabel: AppLocalizations.of(context).closeAction,
        transitionDuration: const Duration(milliseconds: 460),
        reverseTransitionDuration: const Duration(milliseconds: 340),
        pageBuilder: (context, animation, _) => _QrPassPage(
          animation: animation,
          from: from,
          brand: brand,
          palette: palette,
          code: code,
          used: used,
          onCopy: onCopy,
          scratch: scratch,
        ),
      ),
    );
  }
}

class _QrPassPage extends StatefulWidget {
  const _QrPassPage({
    required this.animation,
    required this.from,
    required this.brand,
    required this.palette,
    required this.code,
    required this.used,
    required this.onCopy,
    required this.scratch,
  });

  final Animation<double> animation;
  final Rect from;
  final CardBrand brand;
  final ArtPalette palette;
  final String code;
  final bool used;
  final VoidCallback onCopy;
  final bool scratch;

  @override
  State<_QrPassPage> createState() => _QrPassPageState();
}

class _QrPassPageState extends State<_QrPassPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scratch =
      AnimationController(
        vsync: this,
        duration: ScratchOff.duration,
        value: widget.scratch ? 0 : 1,
      )..addListener(() {
        if (!_scratch.isAnimating) {
          return;
        }
        // A tick as the hand turns back at each stroke's end, and the
        // system's own "it worked" as the last of the foil goes.
        final stroke = ScratchOff.strokeAt(_scratch.value).floor();
        if (stroke != _stroke) {
          _stroke = stroke;
          if (stroke == ScratchOff.strokes) {
            Haptics.success();
          } else {
            Haptics.select();
          }
        }
      });
  int _stroke = 0;

  bool _bright = false;

  /// How far a downward drag has pulled the card, in points.
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
    _brighten(true);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    _scratch.dispose();
    _brighten(false);
    super.dispose();
  }

  /// The foil comes off once the card has landed. The phone's own brightness
  /// comes back as soon as the card starts down, by when the foil is gone: the
  /// page's card, which it lands back on, has none left.
  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed && _scratch.value == 0) {
      _scratch.forward();
    }
    if (status == AnimationStatus.reverse) {
      _scratch.value = 1;
      _brighten(false);
    }
  }

  void _brighten(bool up) {
    if (up == _bright) {
      return;
    }
    _bright = up;
    final change = up ? QrPass.brightness.up : QrPass.brightness.down;
    change().catchError((Object _) {});
  }

  void _close() {
    if (widget.animation.status != AnimationStatus.reverse) {
      Navigator.of(context).maybePop();
    }
  }

  /// The card's size in the middle: as large as the screen comfortably
  /// takes, so the QR is large too.
  static Size _target(Size screen, EdgeInsets padding) {
    final width = math.min(
      math.min(
        screen.width - padding.horizontal - CardsSpace.gutter * 2,
        (screen.height - padding.vertical) * 0.5 * kCardAspect,
      ),
      560.0,
    );
    return Size(width, width / kCardAspect);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final media = (
      size: MediaQuery.sizeOf(context),
      padding: MediaQuery.paddingOf(context),
    );
    final still = MediaQuery.disableAnimationsOf(context);
    final size = _target(media.size, media.padding);
    final centre = media.padding.topLeft.translate(
      (media.size.width - media.padding.horizontal) / 2,
      (media.size.height - media.padding.vertical) / 2,
    );
    final to = Rect.fromCenter(
      center: centre,
      width: size.width,
      height: size.height,
    );
    final ArtPalette(:dark) = widget.palette;
    // Outside the builder: its QR is not worked out again every frame.
    final face = CodeCardFace(
      brand: widget.brand,
      palette: widget.palette,
      code: widget.code,
      used: widget.used,
      onTap: widget.onCopy,
      qrScratched: still ? kAlwaysCompleteAnimation : _scratch,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([widget.animation, _scratch]),
      builder: (context, _) {
        final raw = widget.animation.value;
        final t = Curves.easeInOutCubic.transform(raw);
        final rect = still
            ? to
            : Rect.lerp(widget.from, to, t)!.shift(Offset(0, _drag));
        // Lifted off the page: a touch larger on the way, as a card raised
        // toward the eye, and it answers the coin's last stroke with a small
        // lift of its own.
        final answer =
            ((_scratch.value - ScratchOff.clearAt) / (1 - ScratchOff.clearAt))
                .clamp(0.0, 1.0);
        final lift = still
            ? 1.0
            : 1 +
                  0.04 * math.sin(t * math.pi) +
                  0.018 * math.sin(answer * math.pi);
        final dim = (still ? raw : t) * (1 - (_drag / 400).clamp(0.0, 1.0));
        return Stack(
          children: [
            // The page dims and blurs away behind the card, in the card's
            // own deep colour.
            Positioned.fill(
              child: GestureDetector(
                onTap: _close,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18 * dim, sigmaY: 18 * dim),
                  child: ColoredBox(
                    color: Color.lerp(
                      Colors.black,
                      dark,
                      0.45,
                    )!.withValues(alpha: 0.78 * dim),
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: rect,
              child: GestureDetector(
                onVerticalDragUpdate: (details) => setState(
                  () => _drag = math.max(0, _drag + details.delta.dy),
                ),
                onVerticalDragEnd: (details) {
                  if (_drag > 90 || details.velocity.pixelsPerSecond.dy > 700) {
                    _close();
                  } else {
                    setState(() => _drag = 0);
                  }
                },
                child: Transform.scale(
                  scale: lift,
                  child: FittedBox(
                    // Laid out as it is on the page and scaled up as a whole:
                    // the same card, held closer, not a new layout of it.
                    child: SizedBox(
                      width: widget.from.width,
                      height: widget.from.height,
                      // The card answers the phone's tilt, gently: enough to
                      // catch the light, not enough to skew the code for the
                      // scanner.
                      child: TiltCard(
                        radius: CardsRadii.tile,
                        strength: _HalfOf(widget.animation),
                        child: face,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Close, and how to close, under the card once it has landed.
            Positioned(
              left: 0,
              right: 0,
              top: to.bottom + CardsSpace.xl,
              child: Opacity(
                opacity:
                    ((raw - 0.6) / 0.4).clamp(0.0, 1.0) *
                    (1 - (_drag / 120).clamp(0.0, 1.0)),
                child: Center(
                  child: IconButton.filledTonal(
                    tooltip: l10n.closeAction,
                    onPressed: _close,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.16),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.square(52),
                    ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Half of [parent]: the pass's tilt runs at half the reveal page's.
class _HalfOf extends Animation<double> with AnimationWithParentMixin<double> {
  _HalfOf(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value => parent.value * 0.5;
}
