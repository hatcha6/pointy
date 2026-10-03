import 'package:flutter/material.dart';

import '../design/design.dart';

/// Someone else's brand mark — a resale provider, a payment method — sized for
/// a row or a tile.
///
/// Third-party marks are drawn for a light background, so the artwork sits on
/// a white chip in both themes rather than being tinted. A mark that is a
/// whole app tile already ([fillsBox]) fills the box instead: a white chip
/// around a tile reads as a frame around a picture of a frame.
///
/// A missing asset is the normal case for a brand without artwork yet, not a
/// bug: [fallbackIcon] is drawn in its place, on the theme's own tint.
class PointyBrandMark extends StatelessWidget {
  const PointyBrandMark({
    super.key,
    required this.asset,
    required this.fallbackIcon,
    this.size = 48,
    this.aspectRatio = 1,
    this.fillsBox = false,
  });

  /// The bundled image, or null for a brand drawn as [fallbackIcon] on purpose.
  final String? asset;
  final IconData fallbackIcon;

  /// Height of the chip. Width is [size] × [aspectRatio].
  final double size;

  /// Square in a list, so a column of brands lines up whatever shape each
  /// mark is. Wider inline, where a landscape mark squeezed into a square
  /// loses a third of its height to letterboxing and stops being readable.
  final double aspectRatio;
  final bool fillsBox;

  /// Light enough for black artwork in either theme, warm enough not to read
  /// as a hole punched in the surface.
  static const Color _chip = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final radius = BorderRadius.circular(size <= 28 ? 6 : PointyRadii.card);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryStrong.withValues(alpha: 0.10),
      ),
      child: Icon(fallbackIcon, color: colors.primaryStrong),
    );
    final asset = this.asset;

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: size,
        width: size * aspectRatio,
        child: asset == null
            ? fallback
            : Image.asset(
                asset,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => fallback,
                frameBuilder: (context, child, frame, wasSynchronous) {
                  if (fillsBox) {
                    return child;
                  }
                  // Only artwork gets the chip. Wrapping the fallback too
                  // would put a white square behind a themed icon.
                  return DecoratedBox(
                    decoration: const BoxDecoration(color: _chip),
                    child: Padding(
                      padding: EdgeInsets.all(size * 0.12),
                      child: child,
                    ),
                  );
                },
              ),
      ),
    );
  }
}
