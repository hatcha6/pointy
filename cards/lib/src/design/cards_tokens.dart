import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// The card app's spacing, radii, shadows and motion.
///
/// The premium apps it is measured against (Airbnb, Apple Music) share a few
/// habits: one spacing scale and nothing off it, soft two-layer shadows rather
/// than borders, the artwork as the hero, and motion that confirms rather than
/// decorates. These tokens are those habits.
abstract final class CardsSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;

  /// Side gutter of every page.
  static const double gutter = 20;
}

abstract final class CardsRadii {
  /// Card art: a gift card's own corner.
  static const double art = 14;
  static const double tile = 16;
  static const double card = 20;
  static const double field = 14;
  static const double sheet = 28;

  /// Buttons, chips, pills and badges are capsules.
  static const double pill = 999;
}

abstract final class CardsSizes {
  /// Every tappable thing is at least this tall.
  static const double touch = 48;
  static const double button = 54;
}

/// Soft, ink-tinted two-layer shadows: a wide ambient one and a tight contact
/// one, the way light falls on a card lying on a table.
abstract final class CardsShadows {
  static const List<BoxShadow> art = [
    BoxShadow(
      color: Color(0x1A101828),
      offset: Offset(0, 8),
      blurRadius: 24,
      spreadRadius: -6,
    ),
    BoxShadow(
      color: Color(0x14101828),
      offset: Offset(0, 2),
      blurRadius: 6,
      spreadRadius: -2,
    ),
  ];

  static const List<BoxShadow> hero = [
    BoxShadow(
      color: Color(0x2E101828),
      offset: Offset(0, 18),
      blurRadius: 40,
      spreadRadius: -12,
    ),
    BoxShadow(
      color: Color(0x1A101828),
      offset: Offset(0, 4),
      blurRadius: 10,
      spreadRadius: -4,
    ),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x0F101828), offset: Offset(0, 2), blurRadius: 16),
  ];

  static const List<BoxShadow> bar = [
    BoxShadow(color: Color(0x14101828), offset: Offset(0, -2), blurRadius: 20),
  ];
}

/// Motion confirms what happened. Screens honour the system's "reduce
/// motion" through `MediaQuery.disableAnimations`.
abstract final class CardsMotion {
  static const Duration press = Duration(milliseconds: 110);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration standard = Duration(milliseconds: 240);
  static const Duration emphasized = Duration(milliseconds: 420);
  static const Curve curve = Curves.easeOutCubic;

  /// A gentle overshoot for things that land: the card turning over, the
  /// success mark.
  static const Curve spring = Curves.easeOutBack;
}
