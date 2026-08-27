import 'package:flutter/material.dart';

/// Progress indicators that don't repaint the page behind them.
///
/// An indeterminate [CircularProgressIndicator] or [LinearProgressIndicator]
/// animates forever, and every tick calls `markNeedsPaint`. That walks up to the
/// nearest ancestor repaint boundary — and if there isn't one, that's the root,
/// so the *entire window* is re-recorded and re-rasterised at 60fps for as long
/// as the spinner is on screen. A 16px spinner in the app bar was costing whole
/// dashboards and settings pages.
///
/// It also explains a field measurement that otherwise looks like nonsense:
/// build times stayed under 2ms everywhere while raster ran to 15–20ms on the
/// heavier screens. Nothing was rebuilding — one small thing was animating, and
/// everything else was being redrawn to keep it company.
///
/// [RepaintBoundary] gives the animation its own layer so the tick stops there.
/// Prefer these over the Material widgets anywhere in the app; they take the
/// same arguments and render the same pixels.
class PointySpinner extends StatelessWidget {
  const PointySpinner({
    super.key,
    this.value,
    this.strokeWidth = 4.0,
    this.color,
    this.backgroundColor,
    this.valueColor,
    this.semanticsLabel,
    this.semanticsValue,
  });

  /// Null for an indeterminate spinner, 0..1 for a determinate one.
  final double? value;
  final double strokeWidth;
  final Color? color;
  final Color? backgroundColor;
  final Animation<Color?>? valueColor;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CircularProgressIndicator(
        value: value,
        strokeWidth: strokeWidth,
        color: color,
        backgroundColor: backgroundColor,
        valueColor: valueColor,
        semanticsLabel: semanticsLabel,
        semanticsValue: semanticsValue,
      ),
    );
  }
}

/// A [LinearProgressIndicator] isolated behind a [RepaintBoundary].
///
/// See [PointySpinner] for why.
class PointyProgressBar extends StatelessWidget {
  const PointyProgressBar({
    super.key,
    this.value,
    this.color,
    this.backgroundColor,
    this.valueColor,
    this.minHeight,
    this.borderRadius,
    this.semanticsLabel,
    this.semanticsValue,
  });

  /// Null for an indeterminate bar, 0..1 for a determinate one.
  final double? value;
  final Color? color;
  final Color? backgroundColor;
  final Animation<Color?>? valueColor;
  final double? minHeight;
  final BorderRadiusGeometry? borderRadius;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    final indicator = LinearProgressIndicator(
      value: value,
      color: color,
      backgroundColor: backgroundColor,
      valueColor: valueColor,
      minHeight: minHeight,
      semanticsLabel: semanticsLabel,
      semanticsValue: semanticsValue,
    );
    return RepaintBoundary(
      child: borderRadius == null
          ? indicator
          : ClipRRect(borderRadius: borderRadius!, child: indicator),
    );
  }
}
