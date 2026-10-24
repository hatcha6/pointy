import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Path, Radius, Rect, lerpDouble;

/// The two marks the opening turns one into the other, on a 1024-unit tile.
///
/// Daftar's is traced from `shared/pointy_brand/assets/branding/daftar_logo.png`
/// (edges fitted to the picture, then each corner's roundness from how far
/// the picture stands off the sharp corner). The card app's is the numbers
/// of `assets/branding/cards_mark.svg`. At rest the opening shows those two
/// pictures themselves; these shapes carry it between them.
abstract final class LogoGeometry {
  static const double size = 1024;
  static const Offset centre = Offset(512, 512);

  // Daftar's colours, as the picture paints them.
  static const Color daftarTile = Color(0xFF0C6D68);
  static const Color daftarPage = Color(0xFFE0F3F1);

  /// The page behind is lit from the right: lighter on its right strip than
  /// along its foot.
  static const Color daftarBackPageFoot = Color(0xFFA8D5CD);
  static const Color daftarBackPageSide = Color(0xFFBADFDA);
  static const Offset daftarBackLightFrom = Offset(500, 830);
  static const Offset daftarBackLightTo = Offset(790, 500);
  static const Color daftarPencil = Color(0xFF0A655E);
  static const Color daftarBand = Color(0xFFEA9E2A);

  // The card app's, as its SVG paints them.
  static const Color cardsTile = Color(0xFF0F6E69);
  static const Color cardsSheet = Color(0xFFE3F3F0);
  static const Color cardsBackSheet = Color(0xFFA9D6D0);
  static const Color amber = Color(0xFFE9A030);
  static const Color shadow = Color(0x4706302E);

  /// The front sheet's shadow on what is behind it: Daftar's page lies close
  /// to its page behind, the card app's card floats a little higher.
  static const Offset daftarShadowOffset = Offset(4, 6);
  static const double daftarShadowBlur = 11;
  static const Offset cardsShadowOffset = Offset(0, 10);
  static const double cardsShadowBlur = 14;

  /// The pencil's own soft shadow on the page, down and to the right.
  static const Offset pencilShadowOffset = Offset(5, 3.5);
  static const double pencilShadowBlur = 5;
  static const Color pencilShadow = Color(0x5506302E);

  /// Daftar's tile is a squircle a little narrower than it is tall.
  static const Rect daftarTileRect = Rect.fromLTRB(8.8, 0, 1011.5, 1024);
  static const double daftarTileRadius = 240;

  /// The card app's tile: the SVG's rounded square.
  static const double cardsTileRadius = 230;

  // Daftar: a page leaning back, a second page behind it bound to it at the
  // bottom left like a spine, and a pencil across the page.
  static const daftarFront = Sheet(
    corners: [
      Offset(311.6, 252.0),
      Offset(784.7, 164.9),
      Offset(715.2, 731.4),
      Offset(212.8, 821.1),
    ],
    radii: [27, 37, 54, 19],
    color: daftarPage,
  );
  static const daftarBack = Sheet(
    corners: [
      Offset(290.2, 375.3),
      Offset(821.0, 277.7),
      Offset(758.9, 842.0),
      Offset(213.5, 817.3),
    ],
    radii: [20, 34, 42, 19],
    color: daftarBackPageFoot,
  );

  /// The pencil, on the tile: its point, the way it runs, how long and wide
  /// it is, how long its point tapers, and where its band sits along it.
  static const Offset pencilTip = Offset(398.6, 710.7);
  static const double pencilAngle = -54.9 * math.pi / 180;
  static const double pencilLength = 496;
  static const double pencilWidth = 66;
  static const double pencilPoint = 80;
  static const double bandFrom = 394;
  static const double bandTo = 414;

  // The card app: two cards fanned out, the front one with a stripe, a chip
  // and two lines. The SVG turns each card about the tile's centre.
  static final cardsBack = Sheet.cardTurnedAboutTile(
    rect: const Rect.fromLTWH(300, 300, 520, 330),
    degrees: -14,
    radius: 48,
    color: cardsBackSheet,
  );
  static final cardsFront = Sheet.cardTurnedAboutTile(
    rect: const Rect.fromLTWH(222, 392, 540, 340),
    degrees: -6,
    radius: 48,
    color: cardsSheet,
  );

  /// The front card's stripe, chip and lines, in the card's own frame (its
  /// centre, square to it).
  static const double stripeCentreY = -69;
  static const double stripeHeight = 62;
  static const Offset chipCentre = Offset(-162, 61);
  static const double chipWidth = 96;
  static const double chipHeight = 70;
  static const double chipRadius = 16;
  static const List<(Offset, double)> lines = [
    (Offset(-7, 51), 150),
    (Offset(-34, 83), 96),
  ];
  static const double lineHeight = 18;
}

/// A page or a card: four corners (top left, top right, bottom right, bottom
/// left), each with its own roundness, and a colour. A page leans and is not
/// quite square, so it is four corners rather than a turned rectangle.
class Sheet {
  const Sheet({
    required this.corners,
    required this.radii,
    required this.color,
  });

  /// A card from the SVG: [rect] turned [degrees] about the tile's centre.
  factory Sheet.cardTurnedAboutTile({
    required Rect rect,
    required double degrees,
    required double radius,
    required Color color,
  }) {
    final angle = degrees * math.pi / 180;
    Offset turn(Offset p) {
      final v = p - LogoGeometry.centre;
      return LogoGeometry.centre +
          Offset(
            v.dx * math.cos(angle) - v.dy * math.sin(angle),
            v.dx * math.sin(angle) + v.dy * math.cos(angle),
          );
    }

    return Sheet(
      corners: [
        turn(rect.topLeft),
        turn(rect.topRight),
        turn(rect.bottomRight),
        turn(rect.bottomLeft),
      ],
      radii: [radius, radius, radius, radius],
      color: color,
    );
  }

  final List<Offset> corners;
  final List<double> radii;
  final Color color;

  /// Where its face is drawn from: its middle, and the way its top runs.
  Offset get middle =>
      corners.reduce((a, b) => a + b) / corners.length.toDouble();
  double get angle {
    final top = corners[1] - corners[0];
    return math.atan2(top.dy, top.dx);
  }

  Sheet lerpTo(Sheet other, double t) => Sheet(
    corners: [
      for (var i = 0; i < 4; i++) Offset.lerp(corners[i], other.corners[i], t)!,
    ],
    radii: [
      for (var i = 0; i < 4; i++) lerpDouble(radii[i], other.radii[i], t)!,
    ],
    color: Color.lerp(color, other.color, t)!,
  );

  /// The outline, each corner rounded by its own radius.
  Path get path {
    final path = Path();
    for (var i = 0; i < 4; i++) {
      final corner = corners[i];
      final before = corners[(i + 3) % 4];
      final after = corners[(i + 1) % 4];
      final r = radii[i];
      final toBefore = before - corner;
      final toAfter = after - corner;
      final turn = math.acos(
        ((toBefore.dx * toAfter.dx + toBefore.dy * toAfter.dy) /
                (toBefore.distance * toAfter.distance))
            .clamp(-1.0, 1.0),
      );
      // How far along each edge the rounding starts.
      final cut = math.min(
        r / math.tan(turn / 2),
        math.min(toBefore.distance, toAfter.distance) / 2,
      );
      // A short edge leaves less room; the arc then rounds less.
      final round = cut * math.tan(turn / 2);
      final start = corner + toBefore / toBefore.distance * cut;
      final end = corner + toAfter / toAfter.distance * cut;
      if (i == 0) {
        path.moveTo(start.dx, start.dy);
      } else {
        path.lineTo(start.dx, start.dy);
      }
      path.arcToPoint(end, radius: Radius.circular(round));
    }
    return path..close();
  }
}

/// [t] mapped onto [start]..[end] and clamped: a step of a longer animation.
double interval(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);
