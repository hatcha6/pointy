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
import '../../core/analytics/analytics.dart';

/// The code as a QR, shown the way a wallet shows a pass: the card lifts out
/// of the page into the middle of the screen and turns over, its back now
/// the QR, while the page dims away behind it and the screen brightens for
/// the scanner. Closing turns it back and sets it down where it was.
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
  /// completes once it is set back down.
  static Future<void> open(
    BuildContext context, {
    required Rect from,
    required CardBrand brand,
    required ArtPalette palette,
    required String code,
    required bool used,
    required VoidCallback onCopy,
  }) {
    Haptics.tap();
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        settings: screenSettings('qr_pass'),
        opaque: false,
        barrierDismissible: true,
        barrierLabel: AppLocalizations.of(context).closeAction,
        transitionDuration: const Duration(milliseconds: 620),
        reverseTransitionDuration: const Duration(milliseconds: 460),
        pageBuilder: (context, animation, _) => _QrPassPage(
          animation: animation,
          from: from,
          brand: brand,
          palette: palette,
          code: code,
          used: used,
          onCopy: onCopy,
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
  });

  final Animation<double> animation;
  final Rect from;
  final CardBrand brand;
  final ArtPalette palette;
  final String code;
  final bool used;
  final VoidCallback onCopy;

  @override
  State<_QrPassPage> createState() => _QrPassPageState();
}

class _QrPassPageState extends State<_QrPassPage> {
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
    _brighten(false);
    super.dispose();
  }

  /// The phone's own brightness comes back as soon as the card starts down.
  void _status(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
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
    final media = MediaQuery.of(context);
    final still = media.disableAnimations;
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
    final face = QrCardFace(
      brand: widget.brand,
      palette: widget.palette,
      code: widget.code,
      used: widget.used,
      onCopy: widget.onCopy,
    );
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final raw = widget.animation.value;
        final t = Curves.easeInOutCubic.transform(raw);
        // The turn runs a little behind the lift, so the card is clear of
        // the page before its face goes edge-on.
        final turn = still
            ? 1.0
            : Curves.easeInOutBack.transform(
                ((raw - 0.12) / 0.88).clamp(0.0, 1.0),
              );
        final rect = still
            ? to
            : Rect.lerp(widget.from, to, t)!.shift(Offset(0, _drag));
        final angle = turn.clamp(0.0, 1.0) * math.pi;
        final showQr = angle > math.pi / 2;
        // Lifted off the page: a touch larger at mid-turn, as a card raised
        // toward the eye.
        final lift = still ? 1.0 : 1 + 0.06 * math.sin(t * math.pi);
        final card = showQr
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.rotationY(math.pi),
                // The card answers the phone's tilt, gently: enough to catch
                // the light, not enough to skew the code for the scanner.
                child: TiltCard(
                  radius: CardsRadii.tile,
                  strength: _HalfOf(widget.animation),
                  child: face,
                ),
              )
            : CodeCardFace(
                brand: widget.brand,
                palette: widget.palette,
                code: widget.code,
                used: widget.used,
              );
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
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..scaleByDouble(lift, lift, 1, 1)
                    ..rotateY(angle),
                  child: FittedBox(
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: card,
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
