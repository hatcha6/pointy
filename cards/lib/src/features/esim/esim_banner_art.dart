import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The eSIM banner's picture, in the mark's vocabulary (a mint card, an amber
/// accent, the same soft shadow): a globe, an eSIM card lying over it, and a
/// plane on a dashed route. [flight] runs from 0 to 1 as the plane arrives.
class EsimBannerArtPainter extends CustomPainter {
  const EsimBannerArtPainter({required this.flight, required this.rtl});

  final double flight;
  final bool rtl;

  static const _amber = Color(0xFFF0A93C);
  static const _mint = Color(0xFFE6F5F1);
  static const _teal = Color(0xFF0F766E);

  @override
  void paint(Canvas canvas, Size size) {
    // The picture keeps to its own column at the banner's end (the left in
    // Arabic), whatever the text beside it makes the banner's height.
    final side = rtl ? 1.0 : -1.0;
    final radius = math.min(size.height * 0.36, 60.0);
    final centre = Offset(
      rtl ? radius * 1.12 : size.width - radius * 1.12,
      size.height * 0.56,
    );
    _glow(canvas, centre, radius);
    _globe(canvas, centre, radius * 1.5);
    _route(canvas, centre, radius, side);
    _card(canvas, centre + Offset(0, radius * 0.1), radius);
  }

  void _glow(Canvas canvas, Offset centre, double radius) {
    canvas.drawCircle(
      centre,
      radius * 2.2,
      Paint()
        ..shader = RadialGradient(
          colors: [_amber.withValues(alpha: 0.16), _amber.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: centre, radius: radius * 2.2)),
    );
  }

  void _globe(Canvas canvas, Offset centre, double radius) {
    final rect = Rect.fromCircle(center: centre, radius: radius);
    canvas.drawCircle(
      centre,
      radius,
      Paint()..color = Colors.white.withValues(alpha: 0.07),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.22);
    canvas.drawCircle(centre, radius, line);
    // Meridians, then parallels clipped to the sphere.
    for (final squeeze in [0.34, 0.72]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: centre,
          width: radius * 2 * squeeze,
          height: radius * 2,
        ),
        line,
      );
    }
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    for (final lat in [-0.55, 0.0, 0.55]) {
      canvas.drawLine(
        centre + Offset(-radius, radius * lat),
        centre + Offset(radius, radius * lat),
        line,
      );
    }
    canvas.restore();
  }

  /// Where the route is at [t]: a bow rising from behind the card, over the
  /// globe, towards the text.
  Offset _on(double t, Offset centre, double radius, double side) {
    final start = centre + Offset(-side * radius * 0.95, radius * 0.25);
    final control = centre + Offset(-side * radius * 0.35, -radius * 1.85);
    final end = centre + Offset(side * radius * 1.0, -radius * 0.95);
    final u = 1 - t;
    return start * (u * u) + control * (2 * u * t) + end * (t * t);
  }

  void _route(Canvas canvas, Offset centre, double radius, double side) {
    final dash = Paint()
      ..color = _amber
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    const dashes = 22;
    for (var i = 0; i < dashes; i += 2) {
      final from = i / dashes;
      if (from >= flight) {
        break;
      }
      final to = math.min((i + 1) / dashes, flight);
      canvas.drawLine(
        _on(from, centre, radius, side),
        _on(to, centre, radius, side),
        dash,
      );
    }
    final at = _on(flight, centre, radius, side);
    final ahead = _on(math.min(flight + 0.02, 1), centre, radius, side);
    final behind = _on(math.max(flight - 0.02, 0), centre, radius, side);
    final heading = (ahead - behind).direction;
    const icon = Icons.flight_rounded;
    final plane = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: radius * 0.38,
          color: Colors.white,
        ),
      ),
    )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    // The glyph points up.
    canvas.rotate(heading + math.pi / 2);
    plane.paint(canvas, Offset(-plane.width / 2, -plane.height / 2));
    canvas.restore();
    plane.dispose();
  }

  /// An eSIM card: the SIM's cut corner, an amber contact plate, and the
  /// signal it brings.
  void _card(Canvas canvas, Offset centre, double radius) {
    final width = radius * 0.98;
    final height = width * 1.26;
    final cut = width * 0.26;
    final corner = Radius.circular(width * 0.12);
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(-0.16);
    final left = -width / 2, top = -height / 2;
    final right = width / 2, bottom = height / 2;
    final card = Path()
      ..moveTo(left + corner.x, top)
      ..lineTo(right - cut, top)
      ..lineTo(right, top + cut)
      ..lineTo(right, bottom - corner.y)
      ..arcToPoint(Offset(right - corner.x, bottom), radius: corner)
      ..lineTo(left + corner.x, bottom)
      ..arcToPoint(Offset(left, bottom - corner.y), radius: corner)
      ..lineTo(left, top + corner.y)
      ..arcToPoint(Offset(left + corner.x, top), radius: corner)
      ..close();
    canvas.drawShadow(card, const Color(0xFF00241F), 10, true);
    canvas.drawPath(card, Paint()..color = _mint);

    // The contact plate.
    final plate = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, height * 0.14),
        width: width * 0.60,
        height: height * 0.42,
      ),
      Radius.circular(width * 0.08),
    );
    canvas.drawRRect(plate, Paint()..color = _amber);
    final contacts = Paint()
      ..color = const Color(0xFF8A5A14).withValues(alpha: 0.55)
      ..strokeWidth = 1.1;
    final box = plate.outerRect;
    canvas.drawLine(
      Offset(box.left, box.center.dy),
      Offset(box.right, box.center.dy),
      contacts,
    );
    for (final x in [box.left + box.width / 3, box.left + box.width * 2 / 3]) {
      canvas.drawLine(Offset(x, box.top), Offset(x, box.bottom), contacts);
    }

    // The signal, over the plate.
    final signal = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = _teal;
    final source = Offset(-width * 0.06, -height * 0.13);
    canvas.drawCircle(source, 1.6, Paint()..color = _teal);
    for (final reach in [width * 0.14, width * 0.25]) {
      canvas.drawArc(
        Rect.fromCircle(center: source, radius: reach),
        -math.pi * 0.78,
        math.pi * 0.56,
        false,
        signal,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(EsimBannerArtPainter oldDelegate) =>
      oldDelegate.flight != flight || oldDelegate.rtl != rtl;
}
