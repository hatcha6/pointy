import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/animation.dart';
import 'package:flutter/rendering.dart';

import '../splash/logo_geometry.dart';

/// The three onboarding pictures, drawn in the mark's own vocabulary: the
/// teal tile, mint cards with the amber stripe, the chip and the two lines,
/// the same soft shadow.
///
/// They are one picture that changes, not three: the same three cards, the
/// same amber badge and the pocket move, turn and recolour from one scene's
/// pose into the next as [position] runs from 0 (the shelf) through 1 (the
/// instant code) to 2 (the vault), so a swipe morphs the artwork in place.
enum OnboardingScene {
  /// Every card in one place: a fan of cards opening out.
  shelf,

  /// Paid and delivered at once: the card's code appears, a check lands.
  instant,

  /// Kept safe: cards tucked in a pocket behind the phone's lock.
  vault,
}

/// Where one card stands in a scene, and what it wears.
class _Pose {
  const _Pose({
    required this.centre,
    required this.width,
    required this.degrees,
    required this.color,
    this.stripe = const Color(0x00000000),
    this.chip = 0,
    this.lines = 0,
    this.code = 0,
    this.opacity = 1,
  });

  final Offset centre;
  final double width;
  final double degrees;
  final Color color;

  /// The stripe's colour; clear for a card without one.
  final Color stripe;

  /// How much of the chip, the two lines and the code show (0 to 1).
  final double chip;
  final double lines;
  final double code;
  final double opacity;

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(
    centre: Offset.lerp(a.centre, b.centre, t)!,
    width: lerpDouble(a.width, b.width, t)!,
    degrees: lerpDouble(a.degrees, b.degrees, t)!,
    color: Color.lerp(a.color, b.color, t)!,
    stripe: Color.lerp(a.stripe, b.stripe, t)!,
    chip: lerpDouble(a.chip, b.chip, t)!,
    lines: lerpDouble(a.lines, b.lines, t)!,
    code: lerpDouble(a.code, b.code, t)!,
    opacity: lerpDouble(a.opacity, b.opacity, t)!,
  );
}

class OnboardingArtPainter extends CustomPainter {
  OnboardingArtPainter({required this.position, this.intro = 1});

  /// Where the steps are: 0 the shelf, 1 the instant code, 2 the vault, and
  /// anything between while a swipe is under way.
  final double position;

  /// 0 to 1: the first picture opening out of the mark itself (the splash's
  /// tile lands on that first frame).
  final double intro;

  /// The pictures are drawn on a square this many units wide.
  static const double _units = 1000;

  static const Color _line = Color(0xFF9DC7C1);

  // The mark's two cards (assets/branding/cards_mark.svg), on this square:
  // each turned about the tile's centre, so its centre moves with it.
  static const Offset _markBack = Offset(534.4, 444.1);
  static const double _markBackWidth = 507.8;
  static const Offset _markFront = Offset(485.7, 550.6);
  static const double _markFrontWidth = 527.3;
  static const Color _deepTeal = Color(0xFF0B5A56);
  static const Color _white = Color(0xFFFFFFFF);

  // The three cards, back to front, in each scene. The mark is where the
  // shelf starts from.
  static const _mark = [
    _Pose(
      centre: _markBack,
      width: _markBackWidth,
      degrees: -14,
      color: LogoGeometry.cardsBackSheet,
    ),
    _Pose(
      centre: _markBack,
      width: _markBackWidth,
      degrees: -14,
      color: LogoGeometry.amber,
      stripe: LogoGeometry.cardsSheet,
      lines: 1,
      opacity: 0,
    ),
    _Pose(
      centre: _markFront,
      width: _markFrontWidth,
      degrees: -6,
      color: LogoGeometry.cardsSheet,
      stripe: LogoGeometry.amber,
      chip: 1,
      lines: 1,
    ),
  ];

  static const _scenes = [
    // Every card in one place: fanned out.
    [
      _Pose(
        centre: Offset(395, 530),
        width: 440,
        degrees: -20,
        color: LogoGeometry.cardsBackSheet,
      ),
      _Pose(
        centre: Offset(505, 485),
        width: 450,
        degrees: -5,
        color: LogoGeometry.amber,
        stripe: LogoGeometry.cardsSheet,
        lines: 1,
      ),
      _Pose(
        centre: Offset(600, 575),
        width: 460,
        degrees: 11,
        color: LogoGeometry.cardsSheet,
        stripe: LogoGeometry.amber,
        chip: 1,
        lines: 1,
      ),
    ],
    // Paid and delivered: one card forward, its code written on it.
    [
      _Pose(
        centre: Offset(560, 440),
        width: 470,
        degrees: -12,
        color: LogoGeometry.cardsBackSheet,
      ),
      _Pose(
        centre: Offset(600, 420),
        width: 440,
        degrees: -2,
        color: LogoGeometry.amber,
        stripe: LogoGeometry.cardsSheet,
        opacity: 0,
      ),
      _Pose(
        centre: Offset(545, 560),
        width: 540,
        degrees: -4,
        color: LogoGeometry.cardsSheet,
        stripe: LogoGeometry.amber,
        code: 1,
      ),
    ],
    // Kept safe: two cards slipping into the pocket.
    [
      _Pose(
        centre: Offset(500, 650),
        width: 380,
        degrees: 0,
        color: LogoGeometry.cardsBackSheet,
        opacity: 0,
      ),
      _Pose(
        centre: Offset(560, 410),
        width: 400,
        degrees: 7,
        color: LogoGeometry.amber,
        stripe: LogoGeometry.cardsSheet,
      ),
      _Pose(
        centre: Offset(445, 440),
        width: 400,
        degrees: -9,
        color: LogoGeometry.cardsSheet,
        stripe: LogoGeometry.amber,
        chip: 1,
      ),
    ],
  ];

  // The amber badge: none on the shelf, the check on the code's card, the
  // lock on the pocket.
  static const _badgeAt = [
    Offset(760, 395),
    Offset(760, 395),
    Offset(500, 690),
  ];
  static const _badgeRadius = [0.0, 92.0, 112.0];

  /// How much scene [index] is on screen: 1 when shown, fading to 0 a whole
  /// step away.
  double _weight(int index) =>
      Curves.easeInOut.transform((1 - (position - index).abs()).clamp(0, 1));

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / _units);
    final opened = Curves.easeOutCubic.transform(intro.clamp(0.0, 1.0));
    _tile(canvas, opened);

    // Between which two scenes, and how far: eased, so each card glides
    // rather than sliding at the finger's raw speed.
    final p = position.clamp(0.0, _scenes.length - 1.0);
    final from = p.floor().clamp(0, _scenes.length - 2);
    final t = Curves.easeInOutCubic.transform(p - from);
    final instant = _weight(1);
    final vault = _weight(2);

    _speedLines(canvas, instant);
    for (var card = 0; card < 3; card++) {
      var a = _scenes[from][card];
      if (from == 0) {
        a = _Pose.lerp(_mark[card], a, opened);
      }
      _posed(canvas, _Pose.lerp(a, _scenes[from + 1][card], t));
    }
    _pocket(canvas, vault);
    final badge = Offset.lerp(_badgeAt[from], _badgeAt[from + 1], t)!;
    final radius = lerpDouble(_badgeRadius[from], _badgeRadius[from + 1], t)!;
    _badge(canvas, badge, radius * (from == 0 ? opened : 1));
    _check(canvas, badge, radius / 92, instant);
    _lock(canvas, badge, radius / 112, vault);

    final shelf = _weight(0) * opened;
    _sparkle(canvas, const Offset(225, 270), 26 * shelf, LogoGeometry.amber);
    _sparkle(
      canvas,
      const Offset(800, 250),
      18 * shelf,
      LogoGeometry.cardsSheet,
    );
    _dot(canvas, const Offset(820, 790), 14 * shelf, LogoGeometry.amber);
    _dot(canvas, const Offset(180, 760), 10 * shelf, LogoGeometry.cardsSheet);
    _dot(canvas, const Offset(220, 780), 12 * instant, LogoGeometry.amber);
    _sparkle(
      canvas,
      const Offset(820, 800),
      20 * instant,
      LogoGeometry.cardsSheet,
    );
    _sparkle(canvas, const Offset(210, 300), 22 * vault, LogoGeometry.amber);
    _dot(canvas, const Offset(820, 300), 12 * vault, LogoGeometry.cardsSheet);
    canvas.restore();
  }

  void _tile(Canvas canvas, double light) {
    const rect = Rect.fromLTWH(0, 0, _units, _units);
    final tile = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(LogoGeometry.cardsTileRadius * _units / 1024),
    );
    canvas.drawRRect(tile, Paint()..color = LogoGeometry.cardsTile);
    // A soft light from the top, as on the icon's glass.
    canvas.drawRRect(
      tile,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(-0.3, -0.9),
          radius: 1.1,
          colors: [
            const Color(0xFFFFFFFF).withValues(alpha: 0.12 * light),
            const Color(0x00FFFFFF),
          ],
        ).createShader(rect),
    );
  }

  /// Speed lines trailing the delivered card in.
  void _speedLines(Canvas canvas, double shown) {
    for (final (index, (y, length)) in [
      (430.0, 130.0),
      (500.0, 190.0),
      (570.0, 110.0),
    ].indexed) {
      final each = ((shown - index * 0.12) / 0.64).clamp(0.0, 1.0);
      if (each == 0) {
        continue;
      }
      final x = lerpDouble(250, 105, each)!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y - 13, length * each, 26),
          const Radius.circular(13),
        ),
        Paint()
          ..color = LogoGeometry.cardsBackSheet.withValues(alpha: 0.55 * each),
      );
    }
  }

  void _posed(Canvas canvas, _Pose pose) {
    _card(
      canvas,
      centre: pose.centre,
      width: pose.width,
      degrees: pose.degrees,
      color: pose.color,
      stripe: pose.stripe.a == 0 ? null : pose.stripe,
      chip: pose.chip,
      lines: pose.lines,
      opacity: pose.opacity,
      paintFace: pose.code <= 0
          ? null
          : (canvas, width, height) {
              // The code, group by group: four blocks on the card's face.
              const groups = 4;
              final gap = width * 0.035;
              final block = (width * 0.78 - gap * (groups - 1)) / groups;
              final left = -width * 0.39;
              for (var i = 0; i < groups; i++) {
                final shown = ((pose.code - i * 0.12) / 0.64).clamp(0.0, 1.0);
                if (shown == 0) {
                  continue;
                }
                canvas.drawRRect(
                  RRect.fromRectAndRadius(
                    Rect.fromLTWH(
                      left + i * (block + gap),
                      height * 0.12,
                      block,
                      height * 0.17,
                    ),
                    Radius.circular(height * 0.06),
                  ),
                  Paint()..color = _deepTeal.withValues(alpha: 0.85 * shown),
                );
              }
            },
    );
  }

  /// The pocket, in front of the cards, rising into place with the vault.
  void _pocket(Canvas canvas, double shown) {
    if (shown <= 0) {
      return;
    }
    final pocket = const Rect.fromLTRB(
      215,
      520,
      785,
      830,
    ).shift(Offset(0, (1 - shown) * 260));
    if (shown < 1) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, shown));
    } else {
      canvas.save();
    }
    _shadow(canvas, RRect.fromRectAndRadius(pocket, const Radius.circular(70)));
    final shape = RRect.fromRectAndCorners(
      pocket,
      topLeft: const Radius.circular(36),
      topRight: const Radius.circular(36),
      bottomLeft: const Radius.circular(70),
      bottomRight: const Radius.circular(70),
    );
    canvas.drawRRect(shape, Paint()..color = LogoGeometry.cardsBackSheet);
    // Its stitched seam.
    final seam = Path()..addRRect(shape.deflate(30));
    final dashes = Paint()
      ..color = _line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    for (final metric in seam.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 46) {
        canvas.drawPath(metric.extractPath(d, d + 22), dashes);
      }
    }
    canvas.restore();
  }

  /// The check on the badge, at [scale] of its full size.
  void _check(Canvas canvas, Offset badge, double scale, double shown) {
    if (shown <= 0 || scale <= 0) {
      return;
    }
    final s = scale * shown;
    final check = Path()
      ..moveTo(badge.dx - 38 * s, badge.dy + 2 * s)
      ..lineTo(badge.dx - 10 * s, badge.dy + 30 * s)
      ..lineTo(badge.dx + 40 * s, badge.dy - 26 * s);
    canvas.drawPath(
      check,
      Paint()
        ..color = _white.withValues(alpha: shown)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  /// The lock on the badge, at [scale] of its full size.
  void _lock(Canvas canvas, Offset lock, double scale, double shown) {
    if (shown <= 0 || scale <= 0) {
      return;
    }
    final s = scale * shown;
    final white = _white.withValues(alpha: shown);
    final stroke = Paint()
      ..color = white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16 * s
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(
        center: lock + Offset(0, -18 * s),
        width: 76 * s,
        height: 84 * s,
      ),
      math.pi,
      math.pi,
      false,
      stroke,
    );
    canvas.drawLine(
      lock + Offset(-38 * s, -18 * s),
      lock + Offset(-38 * s, 0),
      stroke,
    );
    canvas.drawLine(
      lock + Offset(38 * s, -18 * s),
      lock + Offset(38 * s, 0),
      stroke,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: lock + Offset(0, 22 * s),
          width: 112 * s,
          height: 84 * s,
        ),
        Radius.circular(18 * s),
      ),
      Paint()..color = white,
    );
    canvas.drawCircle(
      lock + Offset(0, 18 * s),
      11 * s,
      Paint()..color = LogoGeometry.amber.withValues(alpha: shown),
    );
  }

  /// A card like the mark's: rounded, with an optional stripe, chip and two
  /// lines, turned about its centre, casting the mark's shadow.
  void _card(
    Canvas canvas, {
    required Offset centre,
    required double width,
    required double degrees,
    required Color color,
    Color? stripe,
    double chip = 0,
    double lines = 0,
    double opacity = 1,
    void Function(Canvas canvas, double width, double height)? paintFace,
  }) {
    if (opacity <= 0) {
      return;
    }
    final height = width * 0.63;
    if (opacity < 1) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    } else {
      canvas.save();
    }
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(degrees * math.pi / 180);
    final shape = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: width, height: height),
      Radius.circular(width * 0.09),
    );
    _shadow(canvas, shape);
    canvas.drawRRect(shape, Paint()..color = color);
    canvas.clipRRect(shape);
    if (stripe != null) {
      canvas.drawRect(
        Rect.fromLTWH(-width / 2, -height * 0.294, width, height * 0.182),
        Paint()..color = stripe,
      );
    }
    if (chip > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(-width * 0.3, height * 0.18),
            width: width * 0.178,
            height: height * 0.206,
          ),
          Radius.circular(width * 0.03),
        ),
        Paint()..color = LogoGeometry.cardsTile.withValues(alpha: chip),
      );
    }
    if (lines > 0) {
      for (final (dy, length) in [(0.15, 0.278), (0.244, 0.178)]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              -width * 0.152,
              height * (dy - 0.0265),
              width * length,
              height * 0.053,
            ),
            Radius.circular(height * 0.0265),
          ),
          Paint()
            ..color = () {
              // Mint lines on a mint card, pale ones on an amber card.
              final ink = Color.lerp(
                _line,
                LogoGeometry.cardsSheet.withValues(alpha: 0.7),
                _amberness(color),
              )!;
              return ink.withValues(alpha: ink.a * lines);
            }(),
        );
      }
    }
    paintFace?.call(canvas, width, height);
    canvas.restore();
  }

  void _shadow(Canvas canvas, RRect shape) {
    canvas.drawRRect(
      shape.shift(LogoGeometry.cardsShadowOffset),
      Paint()
        ..color = LogoGeometry.shadow
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          LogoGeometry.cardsShadowBlur,
        ),
    );
  }

  /// An amber disc with the mark's shadow, for the check and the lock.
  void _badge(Canvas canvas, Offset centre, double radius) {
    if (radius <= 0) {
      return;
    }
    canvas.drawCircle(
      centre + LogoGeometry.cardsShadowOffset,
      radius,
      Paint()
        ..color = LogoGeometry.shadow
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          LogoGeometry.cardsShadowBlur,
        ),
    );
    canvas.drawCircle(centre, radius, Paint()..color = LogoGeometry.amber);
  }

  /// A four-pointed glint.
  void _sparkle(Canvas canvas, Offset centre, double radius, Color color) {
    if (radius <= 0) {
      return;
    }
    final waist = radius * 0.28;
    final path = Path()..moveTo(centre.dx, centre.dy - radius);
    for (final (corner, point) in [
      (Offset(waist, -waist), Offset(radius, 0)),
      (Offset(waist, waist), Offset(0, radius)),
      (Offset(-waist, waist), Offset(-radius, 0)),
      (Offset(-waist, -waist), Offset(0, -radius)),
    ]) {
      final c = centre + corner;
      final p = centre + point;
      path.quadraticBezierTo(c.dx, c.dy, p.dx, p.dy);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  void _dot(Canvas canvas, Offset centre, double radius, Color color) {
    if (radius > 0) {
      canvas.drawCircle(centre, radius, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(OnboardingArtPainter oldDelegate) =>
      oldDelegate.position != position || oldDelegate.intro != intro;

  /// How amber [color] is, from the mint sheet (0) to the amber (1).
  static double _amberness(Color color) {
    final span = LogoGeometry.amber.r - LogoGeometry.cardsSheet.r;
    return span == 0
        ? 0
        : ((color.r - LogoGeometry.cardsSheet.r) / span).clamp(0.0, 1.0);
  }
}
