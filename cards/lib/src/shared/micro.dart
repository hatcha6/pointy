import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';

/// Small moves that confirm what just happened. Each stands still when the
/// system asks for reduced motion.

/// Comes in once, as it is first shown: a fade and a short rise, after
/// [delay] (rows of a list arriving one after another).
class AppearRise extends StatefulWidget {
  const AppearRise({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.rise = 10,
  });

  final Widget child;
  final Duration delay;

  /// How far below its place it starts, in points.
  final double rise;

  /// The delay of row [index] in a list: 30 ms apart, the first screenful
  /// only, so a long list is never kept waiting.
  static Duration stagger(int index) =>
      Duration(milliseconds: 30 * index.clamp(0, 8));

  @override
  State<AppearRise> createState() => _AppearRiseState();
}

class _AppearRiseState extends State<AppearRise>
    with SingleTickerProviderStateMixin {
  static const _move = Duration(milliseconds: 280);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _move + widget.delay,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _controller.duration!.inMicroseconds;
    final start = widget.delay.inMicroseconds / total;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = CardsMotion.curve.transform(
          ((_controller.value - start) / (1 - start)).clamp(0.0, 1.0),
        );
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.rise * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

/// A mark that settles into place with a small spring as it is first shown
/// (a tab's filled icon as the tab is chosen).
class Settle extends StatelessWidget {
  const Settle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.72, end: 1),
      duration: CardsMotion.emphasized,
      curve: CardsMotion.spring,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: child,
    );
  }
}

/// One mark taking another's place on the same spot (a circle becoming a
/// check, copy becoming done): the old shrinks away as the new one lands.
class MarkSwitcher extends StatelessWidget {
  const MarkSwitcher({super.key, required this.child});

  /// Told apart from the one before it by its key.
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : CardsMotion.standard,
    switchInCurve: CardsMotion.spring,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: animation, child: child),
    ),
    child: child,
  );
}

/// A figure that counts to its new value rather than jumping to it.
class CountUp extends StatelessWidget {
  const CountUp({super.key, required this.value, required this.builder});

  final int value;
  final Widget Function(BuildContext context, int value) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    // With no beginning, it starts at its value: only a change counts.
    tween: Tween(end: value.toDouble()),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 700),
    curve: CardsMotion.curve,
    builder: (context, shown, _) => builder(context, shown.round()),
  );
}

/// A filled button that narrows to a spinner while its work is under way,
/// and widens back with its label when the work ends.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.child,
  });

  final bool busy;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : CardsSizes.button * 3;
        return Center(
          child: AnimatedContainer(
            duration: still ? Duration.zero : CardsMotion.standard,
            curve: CardsMotion.curve,
            width: busy ? CardsSizes.button : wide,
            child: FilledButton(
              onPressed: busy ? null : onPressed,
              style: busy
                  ? FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size.square(CardsSizes.button),
                      disabledBackgroundColor: Theme.of(context)
                          .colorScheme
                          .primary,
                    )
                  : null,
              child: busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                  : child,
            ),
          ),
        );
      },
    );
  }
}
