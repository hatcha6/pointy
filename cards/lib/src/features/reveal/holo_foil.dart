import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shared/tilt_card.dart';

/// The holographic foil a QR waits under: silver, stamped with the app's mark,
/// its rainbow moving as the phone tilts in the hand, the way a real hologram
/// catches the light. A sweep of light crosses it when it first appears.
class HoloFoil extends StatefulWidget {
  const HoloFoil({super.key, required this.radius, required this.label});

  final double radius;
  final String label;

  @override
  State<HoloFoil> createState() => _HoloFoilState();
}

class _HoloFoilState extends State<HoloFoil>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (MediaQuery.disableAnimationsOf(context)) {
        _sweep.value = 1;
      } else {
        _sweep.forward();
      }
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: widget.label,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _FoilPainter(
            tilt: TiltCard.lightOf(context),
            sweep: _sweep,
            radius: widget.radius,
          ),
        ),
      ),
    );
  }
}

class _FoilPainter extends CustomPainter {
  _FoilPainter({required this.tilt, required this.sweep, required this.radius})
    : super(repaint: Listenable.merge([sweep, ?tilt]));

  final ValueListenable<Offset>? tilt;
  final Animation<double> sweep;
  final double radius;

  /// One trip round the colours. Pastel for the foil's sheen, richer for the
  /// stamped marks, which have to show against it.
  static const _sheen = [
    Color(0xFFFFC6E5),
    Color(0xFFD8C4FF),
    Color(0xFFB4D8FF),
    Color(0xFFB2F4EA),
    Color(0xFFCDF7B4),
    Color(0xFFFFF2AC),
    Color(0xFFFFD0B4),
    Color(0xFFFFC6E5),
  ];
  static const _rich = [
    Color(0xFFF062B5),
    Color(0xFF9A6BFF),
    Color(0xFF4FA3FF),
    Color(0xFF33D6BE),
    Color(0xFF7FDB5A),
    Color(0xFFF5CE3A),
    Color(0xFFFF9A5C),
    Color(0xFFF062B5),
  ];
  static final _stops = [
    for (var i = 0; i < _sheen.length; i++) i / (_sheen.length - 1),
  ];

  /// The colours, laid along [direction] and slid [phase] trips along it.
  static Shader _rainbow(
    List<Color> colors,
    Size size,
    Offset direction,
    double period,
    double phase,
  ) {
    final from = size.center(Offset.zero) + direction * period * phase;
    return LinearGradient(
      colors: colors,
      stops: _stops,
      tileMode: TileMode.repeated,
    ).createShader(
      Rect.fromPoints(from, from + direction * period),
      textDirection: TextDirection.ltr,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final lean = tilt?.value ?? Offset.zero;
    final s = Curves.easeInOutSine.transform(sweep.value);
    // A small lean moves a good part of the rainbow: it runs far quicker than
    // the card turns, as it does on real foil. The sweep is one whole trip, so
    // it ends with the colours where they started.
    final phase = lean.dx * 0.9 + lean.dy * 0.6 + s;
    final period = size.width * 1.15;

    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF1F3F5), Color(0xFFC9CED6), Color(0xFFECEEF1)],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xD9000000)
        ..shader = _rainbow(
          _sheen,
          size,
          const Offset(0.82, 0.57),
          period,
          phase,
        ),
    );
    // A second layer crossing the first and sliding against it: the bands
    // bend instead of marching in straight lines.
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0x59000000)
        ..shader = _rainbow(
          _sheen,
          size,
          const Offset(-0.5, 0.87),
          period * 0.8,
          -phase * 0.7 + 0.3,
        ),
    );

    // The marks, pressed into the foil: a shadow on one side, a lit edge on
    // the other, and the richer rainbow running through them a half trip on.
    final marks = _marks(size);
    canvas.drawPath(
      marks.shift(const Offset(0.7, 0.9)),
      Paint()..color = const Color(0x24000000),
    );
    canvas.drawPath(
      marks.shift(const Offset(-0.6, -0.7)),
      Paint()..color = const Color(0xA6FFFFFF),
    );
    canvas.drawPath(
      marks,
      Paint()
        ..color = const Color(0x8C000000)
        ..shader = _rainbow(
          _rich,
          size,
          const Offset(0.82, 0.57),
          period * 0.9,
          phase * 1.3 + 0.5,
        ),
    );

    _sparkle(canvas, size, phase);

    // The light itself: a soft band that crosses with the sweep and follows
    // the lean.
    final travel = lean.dx * 0.8 + lean.dy * 0.8 + (s * 2.6 - 1.3);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-1 + travel, -1 + travel),
          end: Alignment(1 + travel, 1 + travel),
          stops: const [0.34, 0.5, 0.66],
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.75),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.restore();
  }

  /// Fixed specks that each flash at their own angle, as flecks in foil do.
  void _sparkle(Canvas canvas, Size size, double phase) {
    final paint = Paint();
    for (var i = 0; i < 42; i++) {
      final x = _noise(i * 3.1) * size.width;
      final y = _noise(i * 7.7 + 1) * size.height;
      // Whole turns per unit of phase, so the sweep ends as it began.
      final wave = math.sin((phase * 3 + _noise(i * 5.3)) * 2 * math.pi);
      final flash = math.pow(math.max(0.0, wave), 12).toDouble();
      if (flash < 0.02) {
        continue;
      }
      paint.color = Colors.white.withValues(alpha: flash);
      canvas.drawCircle(Offset(x, y), 0.7 + _noise(i * 2.2) * 1.1, paint);
    }
  }

  static double _noise(double v) {
    final n = math.sin(v * 12.9898) * 43758.5453;
    return n - n.floorToDouble();
  }

  static Size? _lastSize;
  static Path? _lastMarks;

  /// The mark, staggered across the foil. Laid out once for a size.
  static Path _marks(Size size) {
    if (size == _lastSize) {
      return _lastMarks!;
    }
    final tile = size.width / 4.2;
    final stepX = tile * 1.34;
    final stepY = tile * 1.04;
    final mark = _mark.transform(
      (Matrix4.identity()..scaleByDouble(tile, tile, 1, 1)).storage,
    );
    final path = Path();
    var row = 0;
    for (var y = -tile; y < size.height; y += stepY) {
      final inset = row.isOdd ? stepX / 2 : 0.0;
      for (var x = -tile + inset; x < size.width; x += stepX) {
        path.addPath(mark, Offset(x, y));
      }
      row++;
    }
    _lastSize = size;
    _lastMarks = path;
    return path;
  }

  /// The «دفتر كروت» mark's card stack, in one colour on a unit square: the
  /// numbers of `assets/branding/cards_mark.svg`, with a gap between the two
  /// cards and the stripe and chip cut out of the front one.
  static final Path _mark = () {
    Path rounded(Rect rect, double radius, double degrees) {
      final turn = Matrix4.identity()
        ..translateByDouble(512, 512, 0, 1)
        ..rotateZ(degrees * math.pi / 180)
        ..translateByDouble(-512, -512, 0, 1);
      return (Path()
            ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius))))
          .transform(turn.storage);
    }

    const frontRect = Rect.fromLTWH(222, 392, 540, 340);
    final back = Path.combine(
      PathOperation.difference,
      rounded(const Rect.fromLTWH(300, 300, 520, 330), 48, -14),
      rounded(frontRect.inflate(26), 66, -6),
    );
    var front = rounded(frontRect, 48, -6);
    for (final cut in [
      rounded(const Rect.fromLTWH(200, 462, 580, 62), 0, -6),
      rounded(const Rect.fromLTWH(282, 588, 96, 70), 16, -6),
    ]) {
      front = Path.combine(PathOperation.difference, front, cut);
    }
    final scale = 1 / 1024;
    return (Path()
          ..addPath(back, Offset.zero)
          ..addPath(front, Offset.zero))
        .transform(
          (Matrix4.identity()..scaleByDouble(scale, scale, 1, 1)).storage,
        );
  }();

  @override
  bool shouldRepaint(_FoilPainter old) =>
      old.tilt != tilt || old.sweep != sweep || old.radius != radius;
}
