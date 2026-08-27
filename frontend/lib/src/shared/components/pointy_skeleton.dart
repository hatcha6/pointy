import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../design/design.dart';

/// Wraps a subtree of [PointySkeletonBox]es and sweeps a shimmer highlight
/// across them while content loads. One wrapper per screen, so wrap a whole
/// screen's placeholders in a single [PointySkeleton] rather than each row.
///
/// The shimmer colours derive from the active palette, so it adapts to dark
/// mode automatically.
///
/// ## Why this paints itself instead of using a [ShaderMask]
///
/// The obvious implementation — one `ShaderMask` over the whole subtree — was
/// the app's single most expensive thing to draw. A `ShaderMask` forces a
/// `saveLayer` the size of what it masks, and this one masks a screen: every
/// frame allocated a full-window offscreen buffer, painted the placeholders
/// into it, then composited it back. At 60fps for as long as a screen was
/// loading. In the field that showed up as a median *raster* time of 19.9ms on
/// the dashboard and 16.8ms on the catalog against 4.4ms on the POS — and the
/// split was not a coincidence: a Flutter screen only produces frames when
/// something moves, so on a screen that is otherwise static the shimmer *is*
/// most of the frames ever measured there.
///
/// Instead each placeholder paints its own slice of one screen-wide gradient,
/// anchored to its position on screen so the wave still crosses the page as one
/// continuous sweep. No `saveLayer`, and the pixels touched are the
/// placeholders themselves rather than the whole window. Each animating box is
/// its own repaint boundary so a shimmering placeholder never dirties the page
/// behind it.
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
  // Built eagerly, not lazily: a skeleton that starts out disabled would
  // otherwise construct its controller for the first time inside dispose(),
  // where the ticker's ancestor lookup is no longer legal.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    );
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

    // Note this build does *not* run per frame: the boxes repaint themselves
    // off the controller. Rebuilding a screenful of placeholders 60 times a
    // second to move a gradient would be its own waste.
    return _SkeletonScope(
      config: _ShimmerConfig(
        animation: widget.enabled ? _controller : null,
        base: base,
        highlight: highlight,
        sweepWidth: MediaQuery.maybeSizeOf(context)?.width ?? 0,
      ),
      child: widget.child,
    );
  }
}

/// Everything a [PointySkeletonBox] needs to paint itself, resolved once by the
/// enclosing [PointySkeleton].
@immutable
class _ShimmerConfig {
  const _ShimmerConfig({
    required this.animation,
    required this.base,
    required this.highlight,
    required this.sweepWidth,
  });

  /// Null when the skeleton is disabled — boxes then paint a flat [base].
  final Animation<double>? animation;
  final Color base;
  final Color highlight;

  /// How far the highlight travels before repeating. The window width, so the
  /// wave reads as one sweep across the page rather than each box pulsing on
  /// its own.
  final double sweepWidth;

  @override
  bool operator ==(Object other) {
    return other is _ShimmerConfig &&
        other.animation == animation &&
        other.base == base &&
        other.highlight == highlight &&
        other.sweepWidth == sweepWidth;
  }

  @override
  int get hashCode => Object.hash(animation, base, highlight, sweepWidth);
}

/// Carries the resolved shimmer down to descendant boxes, so a box outside any
/// [PointySkeleton] still paints something sensible.
class _SkeletonScope extends InheritedWidget {
  const _SkeletonScope({required this.config, required super.child});

  final _ShimmerConfig config;

  static _ShimmerConfig of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SkeletonScope>();
    if (scope != null) {
      return scope.config;
    }
    final fallback = context.pointyColors.surfaceSunken;
    return _ShimmerConfig(
      animation: null,
      base: fallback,
      highlight: fallback,
      sweepWidth: 0,
    );
  }

  @override
  bool updateShouldNotify(_SkeletonScope oldWidget) =>
      config != oldWidget.config;
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
    return _ShimmerShape(
      config: _SkeletonScope.of(context),
      width: width,
      height: height,
      borderRadius: borderRadius,
      circle: _circle,
    );
  }
}

class _ShimmerShape extends LeafRenderObjectWidget {
  const _ShimmerShape({
    required this.config,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.circle,
  });

  final _ShimmerConfig config;
  final double? width;
  final double height;
  final double borderRadius;
  final bool circle;

  @override
  _RenderShimmerShape createRenderObject(BuildContext context) {
    return _RenderShimmerShape(
      config: config,
      width: width,
      height: height,
      borderRadius: borderRadius,
      circle: circle,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderShimmerShape renderObject,
  ) {
    renderObject
      ..config = config
      ..width = width
      ..height = height
      ..borderRadius = borderRadius
      ..circle = circle;
  }
}

class _RenderShimmerShape extends RenderBox {
  _RenderShimmerShape({
    required _ShimmerConfig config,
    required double? width,
    required double height,
    required double borderRadius,
    required bool circle,
  }) : _config = config,
       _width = width,
       _height = height,
       _borderRadius = borderRadius,
       _circle = circle;

  _ShimmerConfig _config;
  _ShimmerConfig get config => _config;
  set config(_ShimmerConfig value) {
    if (_config == value) {
      return;
    }
    final wasAnimating = _config.animation != null;
    if (attached) {
      _config.animation?.removeListener(markNeedsPaint);
      value.animation?.addListener(markNeedsPaint);
    }
    _config = value;
    if (wasAnimating != (value.animation != null)) {
      // isRepaintBoundary is derived from this, so the compositing bits have to
      // be recomputed when the skeleton starts or stops animating.
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  double? _width;
  set width(double? value) {
    if (_width == value) {
      return;
    }
    _width = value;
    markNeedsLayout();
  }

  double _height;
  set height(double value) {
    if (_height == value) {
      return;
    }
    _height = value;
    markNeedsLayout();
  }

  double _borderRadius;
  set borderRadius(double value) {
    if (_borderRadius == value) {
      return;
    }
    _borderRadius = value;
    markNeedsPaint();
  }

  bool _circle;
  set circle(bool value) {
    if (_circle == value) {
      return;
    }
    _circle = value;
    markNeedsPaint();
  }

  /// Only while animating: a static placeholder has nothing to isolate, and an
  /// idle layer is not free.
  @override
  bool get isRepaintBoundary => _config.animation != null;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _config.animation?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _config.animation?.removeListener(markNeedsPaint);
    super.detach();
  }

  Size _measure(BoxConstraints constraints) {
    // A null width means "as wide as offered", matching the Container this
    // replaced. Under unbounded width there is nothing to fill, so collapse
    // rather than throw.
    final width =
        _width ?? (constraints.hasBoundedWidth ? constraints.maxWidth : 0.0);
    return constraints.constrain(Size(width, _height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _measure(constraints);

  @override
  void performLayout() {
    size = _measure(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      return;
    }
    final rect = offset & size;
    final paint = Paint();
    final animation = _config.animation;
    if (animation == null) {
      paint.color = _config.base;
    } else {
      paint.shader = _sweepShader(animation.value, offset);
    }

    final canvas = context.canvas;
    if (_circle) {
      canvas.drawOval(rect, paint);
    } else if (_borderRadius > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(_borderRadius)),
        paint,
      );
    } else {
      canvas.drawRect(rect, paint);
    }
  }

  /// The slice of the screen-wide sweep that falls on this box.
  ///
  /// The gradient is built over a rect spanning the whole sweep, positioned so
  /// its origin sits at screen x=0 in this canvas's coordinates. Every box on
  /// the page therefore samples one shared wave and the highlight travels
  /// across them in step, exactly as the old full-screen mask did.
  Shader _sweepShader(double t, Offset offset) {
    final sweepWidth = _config.sweepWidth > 0 ? _config.sweepWidth : size.width;
    final screenOrigin = offset.dx - localToGlobal(Offset.zero).dx;
    final sweepRect = Rect.fromLTWH(
      screenOrigin,
      offset.dy,
      sweepWidth,
      size.height,
    );
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [_config.base, _config.highlight, _config.base],
      stops: const [0.30, 0.5, 0.70],
      transform: _SweepGradientTransform(t),
    ).createShader(sweepRect);
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
