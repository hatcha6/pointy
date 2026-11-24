import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';
import 'container_route.dart';

/// The app's motion, in one place, built on Material's motion system (the
/// `animations` package): each kind of change moves one way everywhere.
///
/// - A page that opens from another (a brand, a destination): the shared
///   Z axis, the new page coming forward. See [CardsPageTransitionsBuilder].
/// - Places side by side (the tabs): fade through. See [FadeThroughStack].
/// - Steps of one task (phone, then its code): the shared X axis.
/// - A value that goes up or down (a quantity, a total): the shared Y axis.
/// - What stands over the page for a moment (a question): fade and scale.
///   See [showCardsDialog].
///
/// Everything here stands still when the system asks for reduced motion.

/// How one thing takes another's place inside a page.
enum SwitchKind {
  /// Unrelated content: the old fades out, then the new fades in.
  fadeThrough,

  /// The next or previous step: both slide along the reading direction.
  steps,

  /// A higher or lower value: both slide up or down.
  value,
}

/// Swaps [child] for the one before it (told apart by their keys) the way
/// its [kind] moves.
class CardsSwitcher extends StatelessWidget {
  const CardsSwitcher({
    super.key,
    required this.child,
    this.kind = SwitchKind.fadeThrough,
    this.back = false,
    this.duration = const Duration(milliseconds: 300),
    this.alignment = Alignment.center,
  });

  final Widget child;
  final SwitchKind kind;

  /// The step before, or a lower value: the same move the other way.
  final bool back;
  final Duration duration;

  /// Where the two stand while both show, when their sizes differ.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    // The shared X axis moves forward to the left, as in a left-to-right
    // page: a right-to-left one is the other way round.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final reverse = kind == SwitchKind.steps ? back != rtl : back;
    return PageTransitionSwitcher(
      duration: still ? Duration.zero : duration,
      reverse: reverse,
      layoutBuilder: (entries) =>
          Stack(alignment: alignment, children: entries),
      transitionBuilder: (child, animation, secondaryAnimation) =>
          switch (kind) {
            SwitchKind.fadeThrough => FadeThroughTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              fillColor: Colors.transparent,
              child: child,
            ),
            SwitchKind.steps => SharedAxisTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              transitionType: SharedAxisTransitionType.horizontal,
              fillColor: Colors.transparent,
              child: child,
            ),
            SwitchKind.value => SharedAxisTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              transitionType: SharedAxisTransitionType.vertical,
              fillColor: Colors.transparent,
              child: child,
            ),
          },
      child: child,
    );
  }
}

/// A figure that goes up or down: the new one comes in from below when it
/// is higher, and from above when it is lower.
class ValueSwitcher<T extends Comparable<T>> extends StatefulWidget {
  const ValueSwitcher({
    super.key,
    required this.value,
    required this.child,
    this.alignment = Alignment.center,
  });

  final T value;

  /// Shows [value]; the switcher keys it.
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  State<ValueSwitcher<T>> createState() => _ValueSwitcherState<T>();
}

class _ValueSwitcherState<T extends Comparable<T>>
    extends State<ValueSwitcher<T>> {
  bool _down = false;

  @override
  void didUpdateWidget(ValueSwitcher<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final change = widget.value.compareTo(oldWidget.value);
    if (change != 0) {
      _down = change < 0;
    }
  }

  @override
  Widget build(BuildContext context) => CardsSwitcher(
    kind: SwitchKind.value,
    back: _down,
    duration: const Duration(milliseconds: 220),
    alignment: widget.alignment,
    child: KeyedSubtree(key: ValueKey(widget.value), child: widget.child),
  );
}

/// The tabs' pages, all kept alive as an [IndexedStack] keeps them, with a
/// fade through from the one left to the one opened.
///
/// The page left is shown as it was until it has faded, even when the caller
/// has already put something else in its place.
class FadeThroughStack extends StatefulWidget {
  const FadeThroughStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  static const duration = Duration(milliseconds: 300);

  @override
  State<FadeThroughStack> createState() => _FadeThroughStackState();
}

class _FadeThroughStackState extends State<FadeThroughStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FadeThroughStack.duration,
    value: 1,
  );

  /// The page being left, and what it showed, while it fades.
  int? _leaving;
  Widget? _left;

  @override
  void didUpdateWidget(FadeThroughStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _leaving = _left = null;
      _controller.value = 1;
      return;
    }
    _leaving = oldWidget.index;
    _left = oldWidget.children[oldWidget.index];
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && _controller.isCompleted) {
        setState(() => _leaving = _left = null);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leaving = _leaving == widget.index ? null : _leaving;
    Widget page(int i) {
      final current = i == widget.index;
      final left = i == leaving;
      return Offstage(
        key: ValueKey(i),
        offstage: !current && !left,
        child: TickerMode(
          enabled: current,
          child: IgnorePointer(
            ignoring: !current,
            child: FadeThroughTransition(
              animation: current ? _controller : kAlwaysCompleteAnimation,
              secondaryAnimation: left
                  ? _controller
                  : kAlwaysDismissedAnimation,
              fillColor: Colors.transparent,
              child: left ? _left : widget.children[i],
            ),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // The page opened is painted over the one left.
        for (var i = 0; i < widget.children.length; i++)
          if (i != widget.index) page(i),
        page(widget.index),
      ],
    );
  }
}

/// A dialog that fades and scales in over the page, and out the same way
/// however it is closed: a button, a tap outside, or the system's back.
Future<T?> showCardsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showModal<T>(
  context: context,
  configuration: FadeScaleTransitionConfiguration(
    barrierDismissible: barrierDismissible,
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : CardsMotion.standard,
    reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : CardsMotion.fast,
  ),
  builder: builder,
);

/// How one page opens over another where the system has no slide of its own
/// (Android, and the web and desktop builds): the shared Z axis, and the
/// shared Y axis for a page that opens as a sheet over the whole screen.
///
/// A back button or a `pop` plays the same move backwards. On Android a back
/// swipe is the system's own predictive back, which shows the page beneath
/// while the finger is still down: [predictiveBack] hands the gesture to it.
///
/// iOS keeps the system's slide, which follows the finger on a swipe back.
/// The system's iOS slide, which follows the finger on a swipe back. On the
/// web (Safari on an iPhone) both pages slide as images drawn once, rather
/// than drawn again at every frame (see [TransitionSnapshot]).
class CardsCupertinoPageTransitionsBuilder extends PageTransitionsBuilder {
  const CardsCupertinoPageTransitionsBuilder();

  static const _system = CupertinoPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _system.transitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _system.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _system.buildTransitions<T>(
    route,
    context,
    animation,
    secondaryAnimation,
    kIsWeb
        ? TransitionSnapshot(
            animation: animation,
            secondary: secondaryAnimation,
            child: child,
          )
        : child,
  );
}

class CardsPageTransitionsBuilder extends PageTransitionsBuilder {
  const CardsPageTransitionsBuilder({this.predictiveBack = false});

  final bool predictiveBack;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return _PageTransition<T>(
      route: route,
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      predictiveBack: predictiveBack,
      child: child,
    );
  }
}

class _PageTransition<T> extends StatefulWidget {
  const _PageTransition({
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.predictiveBack,
    required this.child,
  });

  final PageRoute<T> route;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final bool predictiveBack;
  final Widget child;

  @override
  State<_PageTransition<T>> createState() => _PageTransitionState<T>();
}

class _PageTransitionState<T> extends State<_PageTransition<T>> {
  ValueNotifier<bool>? _gesture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A back gesture starting or ending changes who draws the page.
    final gesture = widget.route.navigator?.userGestureInProgressNotifier;
    if (gesture != _gesture) {
      _gesture?.removeListener(_changed);
      _gesture = gesture?..addListener(_changed);
    }
  }

  @override
  void dispose() {
    _gesture?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // While a finger drags the page back, the system's predictive back draws
    // it and ours stands still; the rest of the time it is the other way.
    final dragged = widget.predictiveBack && widget.route.popGestureInProgress;
    final page = SharedAxisTransition(
      animation: dragged ? kAlwaysCompleteAnimation : widget.animation,
      secondaryAnimation: dragged
          ? kAlwaysDismissedAnimation
          : widget.secondaryAnimation,
      transitionType: widget.route.fullscreenDialog
          ? SharedAxisTransitionType.vertical
          : SharedAxisTransitionType.scaled,
      fillColor: Theme.of(context).scaffoldBackgroundColor,
      // On the web the page scales and fades as an image, drawn once, not
      // drawn again at every frame (see [TransitionSnapshot]).
      child: kIsWeb
          ? TransitionSnapshot(
              animation: widget.animation,
              secondary: widget.secondaryAnimation,
              child: widget.child,
            )
          : widget.child,
    );
    if (!widget.predictiveBack) {
      return page;
    }
    return const PredictiveBackPageTransitionsBuilder().buildTransitions<T>(
      widget.route,
      context,
      dragged ? widget.animation : kAlwaysCompleteAnimation,
      dragged ? widget.secondaryAnimation : kAlwaysDismissedAnimation,
      page,
    );
  }
}
