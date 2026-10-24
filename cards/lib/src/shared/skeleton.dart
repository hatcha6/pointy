import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';

/// A soft block where content is about to be, with a light sweeping across
/// it (still when the system asks for reduced motion).
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.radius = CardsRadii.field,
    this.aspectRatio,
  });

  final double? width;
  final double? height;
  final double radius;
  final double? aspectRatio;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    final light = Color.lerp(base, Theme.of(context).colorScheme.surface, 0.7)!;
    Widget box = AnimatedBuilder(
      animation: _sweep,
      builder: (context, _) {
        final t = _sweep.value * 3 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(t - 1, 0),
              end: Alignment(t + 1, 0),
              colors: [base, light, base],
            ),
          ),
        );
      },
    );
    if (widget.aspectRatio != null) {
      box = AspectRatio(aspectRatio: widget.aspectRatio!, child: box);
    }
    return ExcludeSemantics(child: box);
  }
}
