import '../../../../shared/responsive/responsive.dart';

/// How wide a service card is: exactly as wide as a brand card on the same
/// shelf, so the strip above the brands lines up with the grid below it.
abstract final class ServiceCardLayout {
  static const double minTileWidth = 150;
  static const int maxColumns = 6;

  static ({int columns, double tileWidth, double gap}) forWidth(
    double width,
    AdaptiveSpacing spacing,
  ) {
    final gap = spacing.md;
    final usable = width.isFinite && width > 0;
    final columns = usable
        ? ((width + gap) / (minTileWidth + gap)).floor().clamp(2, maxColumns)
        : 2;
    final tileWidth = usable
        ? (width - gap * (columns - 1)) / columns
        : minTileWidth;
    return (columns: columns, tileWidth: tileWidth, gap: gap);
  }
}
