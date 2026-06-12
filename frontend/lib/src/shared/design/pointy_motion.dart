import 'package:flutter/material.dart';

/// Motion tokens. Pointy is an operational tool: transitions confirm state
/// changes, they never decorate. Anything longer than [emphasized] is too slow
/// for a cashier flow.
abstract final class PointyMotion {
  /// Hover/pressed feedback, small state swaps.
  static const Duration fast = Duration(milliseconds: 150);

  /// Pane and detail content swaps, sheet/panel entrances.
  static const Duration standard = Duration(milliseconds: 200);

  /// Full-surface transitions that need a touch more presence.
  static const Duration emphasized = Duration(milliseconds: 250);

  static const Curve curve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Curves.easeInOutCubicEmphasized;
}
