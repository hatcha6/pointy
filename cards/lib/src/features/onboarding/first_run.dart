import 'package:flutter/material.dart';

import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import 'onboarding_page.dart';

/// The onboarding in front of [child] the first time the app opens, once.
/// Not for someone already signed in (they know the app), nor for someone
/// arriving on a link (an ad for a brand opens that brand).
class FirstRun extends StatefulWidget {
  const FirstRun({super.key, required this.child});

  final Widget child;

  @override
  State<FirstRun> createState() => _FirstRunState();
}

class _FirstRunState extends State<FirstRun> {
  bool? _showing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = CardsScope.of(context);
    _showing ??=
        !dependencies.settings.onboarded &&
        !dependencies.auth.isSignedIn &&
        dependencies.links.pending == null;
  }

  void _done() {
    CardsScope.of(context).settings.markOnboarded();
    setState(() => _showing = false);
  }

  @override
  Widget build(BuildContext context) {
    // The steps step back and fade as the shelf rises into place.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 560),
      switchInCurve: CardsMotion.curve,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: _showing!
          ? OnboardingPage(key: const ValueKey('onboarding'), onDone: _done)
          : KeyedSubtree(key: const ValueKey('app'), child: widget.child),
    );
  }
}
