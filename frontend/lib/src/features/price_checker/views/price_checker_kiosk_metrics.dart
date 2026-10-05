import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Derived sizing for the current viewport. Everything the kiosk renders is a
/// function of the shortest edge so it scales smoothly from ~3" verifiers to
/// large monitors, with hard clamps that guarantee legibility at the extremes.
///
/// Shared by every kiosk state (price, not-found, the recall notice) so they
/// all read at the same distance.
class KioskMetrics {
  const KioskMetrics({
    required this.size,
    required this.scale,
    required this.isWide,
    required this.gap,
  });

  final Size size;
  final double scale;
  final bool isWide;
  final double gap;

  factory KioskMetrics.of(Size size) {
    final shortest = math.min(size.width, size.height);
    // 420 ≈ a typical small tablet; clamp keeps tiny + huge screens sane.
    final scale = (shortest / 420).clamp(0.62, 2.6).toDouble();
    final isWide = size.width >= 760 && size.width > size.height * 1.15;
    return KioskMetrics(
      size: size,
      scale: scale,
      isWide: isWide,
      gap: (16 * scale).clamp(10, 40).toDouble(),
    );
  }

  double font(double base, {double min = 0, double max = double.infinity}) =>
      (base * scale).clamp(min == 0 ? base * 0.62 : min, max).toDouble();
}
