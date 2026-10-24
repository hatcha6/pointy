import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/animation.dart';
import 'package:flutter/rendering.dart';

import 'logo_geometry.dart';

/// The tile, [progress] of the way from Daftar's mark (0) to the card app's
/// (1): the page reshapes into the front card and the pencil shrinks into its
/// amber band, which stretches into the card's stripe; the page behind turns
/// into the card behind; the chip and lines arrive last.
///
/// At rest it is the marks themselves: [daftar] and [cards] are the logo
/// pictures, shown whole at either end and faded into the drawn shapes while
/// those barely move, so the logos on screen are the real ones, not
/// redrawings. Without the pictures (tests, the render tool) the shapes alone
/// are drawn.
class LogoMorphPainter extends CustomPainter {
  LogoMorphPainter({required this.progress, this.daftar, this.cards})
    : super(repaint: progress);

  final Animation<double> progress;
  final ui.Image? daftar;
  final ui.Image? cards;

  /// How much of each end the picture covers while the shapes take over.
  static const double _handOver = 0.12;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final dst = Offset.zero & size;
    final daftar = this.daftar;
    final cards = this.cards;
    if (daftar != null && t <= 0) {
      _picture(canvas, daftar, dst, 1);
      return;
    }
    if (cards != null && t >= 1) {
      _picture(canvas, cards, dst, 1);
      return;
    }
    canvas.save();
    canvas.scale(size.shortestSide / LogoGeometry.size);
    _morph(canvas, t);
    canvas.restore();
    if (daftar != null) {
      _picture(canvas, daftar, dst, 1 - interval(t, 0, _handOver));
    }
    if (cards != null) {
      _picture(canvas, cards, dst, interval(t, 1 - _handOver, 1));
    }
  }

  void _picture(Canvas canvas, ui.Image image, Rect dst, double opacity) {
    if (opacity <= 0) {
      return;
    }
    canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, opacity),
    );
  }

  void _morph(Canvas canvas, double t) {
    final shape = Curves.easeInOutCubic.transform(t);
    _tile(canvas, Curves.easeInOut.transform(interval(t, 0.1, 0.9)));
    final back = LogoGeometry.daftarBack.lerpTo(LogoGeometry.cardsBack, shape);
    final front = LogoGeometry.daftarFront.lerpTo(
      LogoGeometry.cardsFront,
      shape,
    );
    // Daftar's page behind is lit from the right; the card behind is flat.
    canvas.drawPath(
      back.path,
      Paint()
        ..shader = ui.Gradient.linear(
          LogoGeometry.daftarBackLightFrom,
          LogoGeometry.daftarBackLightTo,
          [
            Color.lerp(
              LogoGeometry.daftarBackPageFoot,
              LogoGeometry.cardsBackSheet,
              shape,
            )!,
            Color.lerp(
              LogoGeometry.daftarBackPageSide,
              LogoGeometry.cardsBackSheet,
              shape,
            )!,
          ],
        ),
    );
    final frontPath = front.path;
    canvas.drawPath(
      frontPath.shift(
        Offset.lerp(
          LogoGeometry.daftarShadowOffset,
          LogoGeometry.cardsShadowOffset,
          shape,
        )!,
      ),
      Paint()
        ..color = LogoGeometry.shadow
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          ui.lerpDouble(
            LogoGeometry.daftarShadowBlur,
            LogoGeometry.cardsShadowBlur,
            shape,
          )!,
        ),
    );
    canvas.drawPath(frontPath, Paint()..color = front.color);

    canvas.save();
    canvas.clipPath(frontPath);
    // The pencil shrinks into its band while the band becomes the stripe.
    final pencil = Curves.easeIn.transform(interval(t, 0, 0.45));
    _pencil(canvas, front, shrink: pencil, opacity: 1 - pencil);
    _bandToStripe(
      canvas,
      front,
      Curves.easeInOutCubic.transform(interval(t, 0.12, 0.78)),
    );
    _details(canvas, front, Curves.easeOutBack.transform(interval(t, 0.6, 1)));
    canvas.restore();
  }

  /// Daftar's squircle eased into the card app's rounded square: the two
  /// shapes cross-faded additively in one layer, so where they overlap the
  /// tile stays fully solid instead of the page showing through.
  void _tile(Canvas canvas, double t) {
    final colour = Color.lerp(
      LogoGeometry.daftarTile,
      LogoGeometry.cardsTile,
      t,
    )!;
    canvas.saveLayer(
      Offset.zero & const Size.square(LogoGeometry.size),
      Paint(),
    );
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectAndRadius(
        LogoGeometry.daftarTileRect,
        const Radius.circular(LogoGeometry.daftarTileRadius),
      ),
      Paint()..color = colour.withValues(alpha: 1 - t),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & const Size.square(LogoGeometry.size),
        const Radius.circular(LogoGeometry.cardsTileRadius),
      ),
      Paint()
        ..color = colour.withValues(alpha: t)
        ..blendMode = BlendMode.plus,
    );
    canvas.restore();
  }

  /// [sheet]'s own frame: its middle, square to its top edge.
  void _enter(Canvas canvas, Sheet sheet) {
    final middle = sheet.middle;
    canvas.translate(middle.dx, middle.dy);
    canvas.rotate(sheet.angle);
  }

  /// A point of Daftar's page, in the page's own frame.
  static Offset _onDaftarPage(Offset p) {
    const page = LogoGeometry.daftarFront;
    final v = p - page.middle;
    final a = -page.angle;
    return Offset(
      v.dx * math.cos(a) - v.dy * math.sin(a),
      v.dx * math.sin(a) + v.dy * math.cos(a),
    );
  }

  /// The pencil rides on the page: [shrink] pulls both ends in to the band.
  void _pencil(
    Canvas canvas,
    Sheet page, {
    required double shrink,
    required double opacity,
  }) {
    if (opacity <= 0) {
      return;
    }
    const band = (LogoGeometry.bandFrom + LogoGeometry.bandTo) / 2;
    final from = band * shrink;
    final to =
        LogoGeometry.pencilLength + (band - LogoGeometry.pencilLength) * shrink;
    if (to - from < 1) {
      return;
    }
    const w = LogoGeometry.pencilWidth;
    const pointLength = LogoGeometry.pencilPoint;
    // Half the pencil's width at a distance along it: the point tapers
    // straight from the tip, the far end is round.
    double halfAt(double d) => w / 2 * math.min(d / pointLength, 1);
    final shoulder = math.max(from, math.min(pointLength, to));
    final capStart = math.max(shoulder, to - w / 2);
    canvas.save();
    _enter(canvas, page);
    final tip = _onDaftarPage(LogoGeometry.pencilTip);
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(LogoGeometry.pencilAngle - LogoGeometry.daftarFront.angle);
    final body = Path()
      ..moveTo(from, -halfAt(from))
      ..lineTo(shoulder, -halfAt(shoulder))
      ..lineTo(capStart, -w / 2)
      ..arcToPoint(
        Offset(capStart, w / 2),
        radius: const Radius.circular(w / 2),
      )
      ..lineTo(shoulder, halfAt(shoulder))
      ..lineTo(from, halfAt(from))
      ..close();
    final alpha = opacity.clamp(0.0, 1.0);
    // Its shadow falls down and to the right of the tile, however the page
    // is turned.
    canvas.save();
    canvas.rotate(-(LogoGeometry.pencilAngle - LogoGeometry.daftarFront.angle));
    canvas.rotate(-LogoGeometry.daftarFront.angle);
    canvas.translate(
      LogoGeometry.pencilShadowOffset.dx,
      LogoGeometry.pencilShadowOffset.dy,
    );
    canvas.rotate(LogoGeometry.daftarFront.angle);
    canvas.rotate(LogoGeometry.pencilAngle - LogoGeometry.daftarFront.angle);
    canvas.drawPath(
      body,
      Paint()
        ..color = LogoGeometry.pencilShadow.withValues(
          alpha: LogoGeometry.pencilShadow.a * alpha,
        )
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          LogoGeometry.pencilShadowBlur,
        ),
    );
    canvas.restore();
    canvas.drawPath(
      body,
      Paint()..color = LogoGeometry.daftarPencil.withValues(alpha: alpha),
    );
    canvas.restore();
  }

  /// The pencil's band, [t] of the way to being the card's stripe, in the
  /// front sheet's frame as that sheet turns from page into card.
  void _bandToStripe(Canvas canvas, Sheet front, double t) {
    const along = (LogoGeometry.bandFrom + LogoGeometry.bandTo) / 2;
    final bandAt = _onDaftarPage(
      LogoGeometry.pencilTip +
          Offset(
                math.cos(LogoGeometry.pencilAngle),
                math.sin(LogoGeometry.pencilAngle),
              ) *
              along,
    );
    // Across the pencil, the band is turned a quarter from it.
    const bandAngle = LogoGeometry.pencilAngle + math.pi / 2;
    final cardWidth = (front.corners[1] - front.corners[0]).distance;
    canvas.save();
    _enter(canvas, front);
    canvas.translate(
      ui.lerpDouble(bandAt.dx, 0, t)!,
      ui.lerpDouble(bandAt.dy, LogoGeometry.stripeCentreY, t)!,
    );
    canvas.rotate(
      ui.lerpDouble(bandAngle - LogoGeometry.daftarFront.angle, 0, t)!,
    );
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset.zero,
        width: ui.lerpDouble(LogoGeometry.pencilWidth, cardWidth + 40, t)!,
        height: ui.lerpDouble(
          LogoGeometry.bandTo - LogoGeometry.bandFrom,
          LogoGeometry.stripeHeight,
          t,
        )!,
      ),
      Paint()
        ..color = Color.lerp(LogoGeometry.daftarBand, LogoGeometry.amber, t)!,
    );
    canvas.restore();
  }

  /// The chip and the two lines, popping in at [t].
  void _details(Canvas canvas, Sheet card, double t) {
    if (t <= 0) {
      return;
    }
    final opacity = t.clamp(0.0, 1.0);
    canvas.save();
    _enter(canvas, card);
    canvas.save();
    canvas.translate(LogoGeometry.chipCentre.dx, LogoGeometry.chipCentre.dy);
    canvas.scale(t);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset.zero,
          width: LogoGeometry.chipWidth,
          height: LogoGeometry.chipHeight,
        ),
        const Radius.circular(LogoGeometry.chipRadius),
      ),
      Paint()..color = LogoGeometry.cardsTile.withValues(alpha: opacity),
    );
    canvas.restore();
    final line = Paint()
      ..color = LogoGeometry.cardsTile.withValues(alpha: 0.35 * opacity);
    for (final (centre, width) in LogoGeometry.lines) {
      // Each line grows from its start, like ink.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            centre.dx - width / 2,
            centre.dy - LogoGeometry.lineHeight / 2,
            width * opacity,
            LogoGeometry.lineHeight,
          ),
          const Radius.circular(LogoGeometry.lineHeight / 2),
        ),
        line,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LogoMorphPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.daftar != daftar ||
      oldDelegate.cards != cards;
}
