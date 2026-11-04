import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A scratch-off panel: [cover] scratched away in quick strokes from the
/// reading edge, as with a coin, flecks of it flying off the tip, and a glint
/// crossing what was under it once it is clear.
///
/// [progress] runs 0 to 1 over [duration]: a beat's hold, the strokes, then
/// the last flecks and the glint. [child] is not built until the first stroke,
/// so a panel still covered holds nothing of what it hides.
class ScratchOff extends StatelessWidget {
  const ScratchOff({
    super.key,
    required this.progress,
    required this.cover,
    required this.child,
    required this.radius,
  });

  final Animation<double> progress;
  final Widget cover;
  final Widget child;
  final double radius;

  static const Duration duration = Duration(milliseconds: 1450);

  /// How many strokes the hand makes to clear the panel.
  static const int strokes = 9;

  /// Where in [progress] the hand starts and where the panel is clear.
  static const double _startsAt = 0.08;
  static const double clearAt = 0.72;

  /// The hand's way through the strokes at a [progress]: 2.5 is half way
  /// through the third. Each stroke speeds up and slows at its end, as a hand
  /// does turning back.
  static double strokeAt(double progress) {
    final hand = ((progress - _startsAt) / (clearAt - _startsAt)).clamp(
      0.0,
      1.0,
    );
    final at = hand * strokes;
    final whole = at.floorToDouble();
    return whole + Curves.easeInOut.transform(at - whole);
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final value = progress.value;
        final at = strokeAt(value);
        final started = at > 0;
        final clear = value >= clearAt;
        final done = value >= 1;
        // One shape from start to end, its pieces keyed: the foil keeps its
        // shimmer and the QR is not rebuilt as the scratch passes.
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            if (!clear)
              KeyedSubtree(key: const ValueKey('cover'), child: cover),
            if (started)
              ClipPath(
                key: const ValueKey('child'),
                clipper: clear ? null : _Scratched(at, rtl: rtl),
                clipBehavior: clear ? Clip.none : Clip.antiAlias,
                child: child,
              ),
            if (started && !done)
              IgnorePointer(
                key: const ValueKey('flecks'),
                child: CustomPaint(
                  painter: _Flecks(value, rtl: rtl, radius: radius),
                ),
              ),
          ],
        );
      },
    );
  }
}

double _noise(double v) {
  final n = math.sin(v * 12.9898) * 43758.5453;
  return n - n.floorToDouble();
}

/// Where the hand turns back: off one long edge, then the other, a little
/// unevenly, stepping across the panel.
Offset _turn(int i, Size size, double width, bool rtl) {
  final wobble = math.sin(i * 12.9898);
  final across = i / ScratchOff.strokes + wobble * 0.012;
  final overshoot = width / 2 + wobble * width * 0.2;
  final x = size.width * across;
  return Offset(
    rtl ? size.width - x : x,
    i.isEven ? -overshoot : size.height + overshoot,
  );
}

double _strokeWidth(Size size, double at) =>
    size.height * (0.24 + 0.2 * math.pow(at / ScratchOff.strokes, 6));

/// Where the coin is at [at] strokes in.
Offset _tip(double at, Size size, bool rtl) {
  final width = _strokeWidth(size, at);
  final i = math.min(at.floor(), ScratchOff.strokes - 1);
  return Offset.lerp(
    _turn(i, size, width, rtl),
    _turn(i + 1, size, width, rtl),
    (at - i).clamp(0.0, 1.0),
  )!;
}

/// The ground the strokes have cleared so far. Every piece is wound the same
/// way, so where they overlap they add up instead of cancelling out. Their
/// edges are ragged: a coin tears foil, it does not cut it.
class _Scratched extends CustomClipper<Path> {
  const _Scratched(this.at, {required this.rtl});

  final double at;
  final bool rtl;

  @override
  Path getClip(Size size) {
    final width = _strokeWidth(size, at);
    final path = Path();
    for (var i = 0; i < ScratchOff.strokes && i < at; i++) {
      final from = _turn(i, size, width, rtl);
      final to = _turn(i + 1, size, width, rtl);
      final end = Offset.lerp(from, to, math.min(1, at - i))!;
      _addStroke(path, from, end, width / 2, i);
    }
    return path;
  }

  static void _addStroke(
    Path path,
    Offset from,
    Offset to,
    double half,
    int seed,
  ) {
    final along = to - from;
    final length = along.distance;
    if (length > 0) {
      final normal = Offset(-along.dy, along.dx) / length;
      final steps = math.max(1, (length / 5).ceil());
      // Ragged by where it is on the stroke, not by the frame, so an edge
      // already torn holds still.
      double rag(int step, double side) =>
          half *
          (1 +
              (_noise(seed * 9.1 + side + step * 5 / length * 40) - 0.5) * 0.3);
      final edges = <Offset>[
        for (var step = 0; step <= steps; step++)
          from + along * (step / steps) - normal * rag(step, 1),
        for (var step = steps; step >= 0; step--)
          from + along * (step / steps) + normal * rag(step, 2),
      ];
      path.addPolygon(edges, true);
    }
    _addTip(path, to, half);
  }

  /// A round end on the stroke, wound the same way as the stroke itself.
  static void _addTip(Path path, Offset centre, double radius) {
    const sides = 12;
    path.addPolygon([
      for (var i = 0; i < sides; i++)
        centre + Offset.fromDirection(i / sides * 2 * math.pi, radius),
    ], true);
  }

  @override
  bool shouldReclip(_Scratched old) => old.at != at || old.rtl != rtl;
}

/// The flecks the coin throws up, and the glint once the panel is clear. All
/// worked out from [value], so the whole thing replays the same with no state.
class _Flecks extends CustomPainter {
  const _Flecks(this.value, {required this.rtl, required this.radius});

  final double value;
  final bool rtl;
  final double radius;

  static const _count = 70;

  /// How long a fleck flies, as a share of the whole.
  static const _life = 0.3;
  static const _colors = [
    Color(0xFFE8EBEF),
    Color(0xFFFFB8E0),
    Color(0xFFC9B5FF),
    Color(0xFFA6D2FF),
    Color(0xFFA5F2E5),
    Color(0xFFFFF0A0),
    Color(0xFFCDD2D9),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = ScratchOff.duration.inMilliseconds / 1000;
    final paint = Paint();
    for (var i = 0; i < _count; i++) {
      final thrownAt =
          ScratchOff._startsAt +
          (ScratchOff.clearAt - ScratchOff._startsAt) * (i / _count);
      final age = value - thrownAt;
      if (age <= 0 || age > _life) {
        continue;
      }
      final from = _tip(ScratchOff.strokeAt(thrownAt), size, rtl);
      // Thrown up and out from where the coin was, then falling.
      final t = age * seconds;
      final vx = (_noise(i * 1.7) - 0.5) * 240;
      final vy = -40 - _noise(i * 2.9) * 170;
      final at =
          Offset(
            from.dx.clamp(0.0, size.width),
            from.dy.clamp(0.0, size.height),
          ) +
          Offset(vx * t, vy * t + 700 * t * t);
      final side = 1.4 + _noise(i * 4.3) * 2.6;
      paint.color = _colors[i % _colors.length].withValues(
        alpha: (1 - age / _life).clamp(0.0, 1.0),
      );
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        // Tumbling, so each one catches the light and loses it.
        ..rotate(_noise(i * 3.3) * 6 + t * (6 + _noise(i * 6.1) * 14))
        ..drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: side,
            height: side * 0.55,
          ),
          paint,
        )
        ..restore();
    }
    if (value > ScratchOff.clearAt) {
      _glint(canvas, size);
    }
  }

  void _glint(Canvas canvas, Size size) {
    final t = Curves.easeOut.transform(
      (value - ScratchOff.clearAt) / (1 - ScratchOff.clearAt),
    );
    final travel = t * 3.2 - 1.6;
    final rect = Offset.zero & size;
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)))
      ..drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment(-1 + travel, -1 + travel),
            end: Alignment(1 + travel, 1 + travel),
            stops: const [0.38, 0.5, 0.62],
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.85),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(rect),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_Flecks old) => old.value != value || old.rtl != rtl;
}
