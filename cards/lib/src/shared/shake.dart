import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tells a [Shake] to shake.
class ShakeController extends ChangeNotifier {
  void shake() => notifyListeners();
}

/// The phone's own "no": a quick side to side that settles, as the lock
/// screen does on a wrong passcode. Under reduced motion it stays still (the
/// error haptic and the message still say it).
class Shake extends StatefulWidget {
  const Shake({super.key, required this.controller, required this.child});

  final ShakeController controller;
  final Widget child;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_shake);
  }

  @override
  void didUpdateWidget(Shake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_shake);
      widget.controller.addListener(_shake);
    }
  }

  void _shake() {
    if (MediaQuery.of(context).disableAnimations) {
      return;
    }
    _motion.forward(from: 0);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_shake);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _motion,
      child: widget.child,
      builder: (context, child) {
        final t = _motion.value;
        // Three swings, each smaller than the last.
        final dx = math.sin(t * math.pi * 6) * (1 - t) * 12;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}
