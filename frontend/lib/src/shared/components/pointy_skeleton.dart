import 'package:flutter/material.dart';

import '../design/design.dart';

/// Wraps a subtree of [PointySkeletonBox]es and sweeps a shimmer highlight
/// across them while content loads. One controller per wrapper, so wrap a whole
/// screen's placeholders in a single [PointySkeleton] rather than each row.
///
/// The shimmer colours derive from the active palette, so it adapts to dark
/// mode automatically.
class PointySkeleton extends StatefulWidget {
  const PointySkeleton({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// When false the child renders as plain (static) boxes with no animation —
  /// useful for tests/screenshots.
  final bool enabled;

  @override
  State<PointySkeleton> createState() => _PointySkeletonState();
}

class _PointySkeletonState extends State<PointySkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1350),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(PointySkeleton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = context.pointyColors;
    final base = Color.alphaBlend(
      colors.mutedInk.withValues(alpha: isDark ? 0.22 : 0.18),
      colors.surface,
    );
    final highlight = Color.alphaBlend(
      Colors.white.withValues(alpha: isDark ? 0.10 : 0.55),
      base,
    );

    if (!widget.enabled) {
      return _SkeletonBaseColor(color: base, child: widget.child);
    }

    return _SkeletonBaseColor(
      color: base,
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [base, highlight, base],
                stops: const [0.30, 0.5, 0.70],
                transform: _SweepGradientTransform(_controller.value),
              ).createShader(bounds);
            },
            child: child,
          );
        },
      ),
    );
  }
}

/// Slides the shimmer gradient from off-screen-left to off-screen-right.
class _SweepGradientTransform extends GradientTransform {
  const _SweepGradientTransform(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final dx = bounds.width * (2 * t - 1);
    return Matrix4.translationValues(dx, 0, 0);
  }
}

/// Provides the resolved base colour to descendant [PointySkeletonBox]es so a
/// box outside any [ShaderMask] still paints something sensible.
class _SkeletonBaseColor extends InheritedWidget {
  const _SkeletonBaseColor({required this.color, required super.child});

  final Color color;

  static Color of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_SkeletonBaseColor>();
    return scope?.color ?? context.pointyColors.surfaceSunken;
  }

  @override
  bool updateShouldNotify(_SkeletonBaseColor oldWidget) =>
      color != oldWidget.color;
}

/// A single opaque placeholder shape. Its colour is replaced by the shimmer
/// gradient when wrapped in a [PointySkeleton]; standalone it paints the base
/// skeleton tone.
class PointySkeletonBox extends StatelessWidget {
  const PointySkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = 7,
  }) : _circle = false;

  const PointySkeletonBox.circle({super.key, required double size})
    : width = size,
      height = size,
      borderRadius = 0,
      _circle = true;

  final double? width;
  final double height;
  final double borderRadius;
  final bool _circle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _circle ? width : (width ?? double.infinity),
      height: height,
      decoration: BoxDecoration(
        color: _SkeletonBaseColor.of(context),
        shape: _circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: _circle ? null : BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Placeholder shaped like a [ListTile] row: leading circle, two text lines,
/// trailing short line. Use several inside one [PointySkeleton].
class PointySkeletonListTile extends StatelessWidget {
  const PointySkeletonListTile({super.key, this.showLeading = true});

  final bool showLeading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(
        children: [
          if (showLeading) ...[
            const PointySkeletonBox.circle(size: 40),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                PointySkeletonBox(width: 180, height: 14),
                SizedBox(height: 8),
                PointySkeletonBox(width: 110, height: 12),
              ],
            ),
          ),
          const SizedBox(width: 16),
          const PointySkeletonBox(width: 56, height: 14),
        ],
      ),
    );
  }
}

/// Placeholder shaped like a catalog product card for grid layouts.
class PointySkeletonCard extends StatelessWidget {
  const PointySkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: context.pointyColors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: const [
          Row(
            children: [
              PointySkeletonBox.circle(size: 36),
              Spacer(),
              PointySkeletonBox(width: 44, height: 20),
            ],
          ),
          SizedBox(height: 18),
          PointySkeletonBox(height: 14),
          SizedBox(height: 8),
          PointySkeletonBox(width: 120, height: 12),
          SizedBox(height: 18),
          PointySkeletonBox(width: 80, height: 18),
        ],
      ),
    );
  }
}
