import 'package:flutter/material.dart';

import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../attribution/reward_sheet.dart';
import 'onboarding_page.dart';

/// The onboarding in front of [child] the first time the app opens, once,
/// ending on «من أين سمعت عنا؟». Not for someone already signed in (they know the
/// app), nor for someone arriving on a link (an ad for a brand opens that
/// brand; a new customer is asked at sign-in instead). Every reward a
/// campaign gives shows over [child].
class FirstRun extends StatefulWidget {
  const FirstRun({super.key, required this.child});

  final Widget child;

  @override
  State<FirstRun> createState() => _FirstRunState();
}

enum _Step { onboarding, app }

class _FirstRunState extends State<FirstRun> {
  _Step? _step;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = CardsScope.of(context);
    _step ??=
        !dependencies.settings.onboarded &&
            !dependencies.auth.isSignedIn &&
            dependencies.links.pending == null
        ? _Step.onboarding
        : _Step.app;
  }

  void _onboarded() {
    CardsScope.of(context).settings.markOnboarded();
    setState(() => _step = _Step.app);
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
      child: switch (_step!) {
        _Step.onboarding => OnboardingPage(
          key: const ValueKey('onboarding'),
          // Its last step, while this phone never answered it.
          askHeardFrom: !CardsScope.of(context).attribution.asked,
          onDone: _onboarded,
        ),
        _Step.app => KeyedSubtree(
          key: const ValueKey('app'),
          child: RewardListener(child: widget.child),
        ),
      },
    );
  }
}
