import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';
import 'haptics.dart';

/// A tappable surface that gives under the finger: it scales to 97 % while
/// pressed and ticks the haptic engine on release. Every card-like thing in
/// the app uses it, so touch feels the same everywhere.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.scale = 0.97,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double scale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down && widget.onTap != null) {
      setState(() => _down = down);
    }
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapCancel: () => _set(false),
        onTapUp: (_) => _set(false),
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) {
                  Haptics.select();
                }
                widget.onTap!();
              },
        child: AnimatedScale(
          scale: _down && !still ? widget.scale : 1,
          duration: CardsMotion.press,
          curve: CardsMotion.curve,
          child: widget.child,
        ),
      ),
    );
  }
}
