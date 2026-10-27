import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';
import '../splash/splash_handoff.dart';
import 'onboarding_art.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../shared/cards_scope.dart';

/// The first run: three short steps, each a picture in the mark's style, a
/// title and a sentence, then the shelf. Skippable from the first step; no
/// sign-in. On a phone a fourth step offers notifications, the one question
/// the phone itself then asks; «ليس الآن» leaves it for after the first
/// card.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onDone});

  /// Skipped or finished: either way it is not shown again.
  final VoidCallback onDone;

  /// Replays the steps from «عن التطبيق»; closing goes back.
  static Future<void> replay(BuildContext context) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: screenSettings('onboarding'),
          fullscreenDialog: true,
          builder: (context) =>
              OnboardingPage(onDone: () => Navigator.of(context).pop()),
        ),
      );

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _Step {
  const _Step(this.title, this.body, {this.notify = false});

  final String title;
  final String body;

  /// The notifications step: its button asks the phone.
  final bool notify;
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  final _pages = PageController();

  /// The first picture's own entrance; the others settle as they are swiped
  /// in.
  late final _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  int _index = 0;

  /// The bell's ring, over and over while the notifications step shows.
  late final _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  /// Whether the phone can take notifications at all; the step shows
  /// whenever it can, a replay from the settings included.
  late final bool _offerNotifications;

  /// Already on when the steps first showed: the step says so and its
  /// button only finishes. Fixed then, so turning them on here does not
  /// change the step under the finger.
  late final bool _alreadyOn;

  /// The first picture's box: the opening's tile lands on it.
  final _artKey = GlobalKey();
  SplashHandoff? _handoff;
  bool _started = false;

  /// The opening is still on: the first picture waits for its tile, hidden
  /// so the two are never seen at once.
  bool _waiting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    final push = CardsScope.of(context).push;
    _offerNotifications = push.available;
    _alreadyOn = push.enabled;
    final handoff = SplashHandoffScope.maybeOf(context);
    if (handoff != null &&
        !handoff.landed &&
        !MediaQuery.disableAnimationsOf(context)) {
      _handoff = handoff;
      _waiting = true;
      handoff
        ..claim(_artKey, () => OnboardingArtPainter(position: 0, intro: 0))
        ..addListener(_landed);
    } else {
      _play();
    }
  }

  void _landed() {
    if (!mounted || !_waiting) {
      return;
    }
    setState(() => _waiting = false);
    _play();
  }

  void _play() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
    } else {
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _handoff
      ?..removeListener(_landed)
      ..release(_artKey);
    _pages.dispose();
    _intro.dispose();
    _ring.dispose();
    super.dispose();
  }

  /// In the art's scene order (`OnboardingScene`).
  List<_Step> _steps(AppLocalizations l10n) => [
    _Step(l10n.onboardingShelfTitle, l10n.onboardingShelfBody),
    _Step(l10n.onboardingInstantTitle, l10n.onboardingInstantBody),
    _Step(l10n.onboardingVaultTitle, l10n.onboardingVaultBody),
    if (_offerNotifications)
      _Step(
        l10n.onboardingNotifyTitle,
        _alreadyOn ? l10n.onboardingNotifyOnBody : l10n.onboardingNotifyBody,
        notify: true,
      ),
  ];

  /// The bell rings only while its step is the one shown.
  void _ringFor(_Step step) {
    if (step.notify && !MediaQuery.disableAnimationsOf(context)) {
      _ring.repeat();
    } else {
      _ring
        ..stop()
        ..value = 0;
    }
  }

  Future<void> _allowNotifications() async {
    Haptics.select();
    await CardsScope.of(context).push.setEnabled(true);
    if (mounted) {
      _finish(skipped: false);
    }
  }

  void _finish({required bool skipped}) {
    CardsScope.of(context).analytics
        .onboardingFinished(skipped: skipped, step: _index + 1);
    widget.onDone();
  }

  void _next(int count) {
    if (_index >= count - 1) {
      Haptics.success();
      _finish(skipped: false);
      return;
    }
    Haptics.select();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(_index + 1);
    } else {
      _pages.nextPage(
        duration: CardsMotion.emphasized,
        curve: CardsMotion.curve,
      );
    }
  }

  double get _page => _pages.hasClients && _pages.position.haveDimensions
      ? _pages.page ?? _index.toDouble()
      : _index.toDouble();

  /// One picture that stays where it is and morphs from step to step as the
  /// pages move, and the steps' words, which are what the swipe pages
  /// through. Beside each other where the screen is wider than it is tall
  /// (a tablet, the iPhone Duo open), the picture above otherwise.
  Widget _stage(List<_Step> steps) {
    final moving = Listenable.merge([_pages, _intro, _ring]);
    final art = Semantics(
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: moving,
        builder: (context, _) => Opacity(
          // The opening's tile is still on its way: never both at once.
          opacity: _waiting ? 0 : 1,
          child: CustomPaint(
            key: _artKey,
            painter: OnboardingArtPainter(
              position: _page,
              intro: _intro.value,
              ring: _ring.value,
            ),
          ),
        ),
      ),
    );
    final words = PageView.builder(
      controller: _pages,
      itemCount: steps.length,
      onPageChanged: (index) {
        Haptics.select();
        setState(() => _index = index);
        _ringFor(steps[index]);
      },
      itemBuilder: (context, index) => AnimatedBuilder(
        animation: moving,
        builder: (context, _) => _Words(
          step: steps[index],
          offset: _page - index,
          // The first step's words follow the opening in.
          arrived: index == 0
              ? Curves.easeOut.transform(
                  ((_intro.value - 0.25) / 0.75).clamp(0.0, 1.0),
                )
              : 1,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth > constraints.maxHeight &&
            constraints.maxWidth >= 560;
        if (wide) {
          final side = (constraints.maxHeight - CardsSpace.xl * 2).clamp(
            0.0,
            360.0,
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: CardsSpace.huge),
            child: Row(
              children: [
                SizedBox.square(dimension: side, child: art),
                const SizedBox(width: CardsSpace.huge),
                Expanded(child: words),
              ],
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CardsSpace.gutter,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 340,
                      maxHeight: 340,
                    ),
                    child: AspectRatio(aspectRatio: 1, child: art),
                  ),
                ),
              ),
            ),
            const SizedBox(height: CardsSpace.xl),
            // Room for a title and three lines at the reader's text size.
            SizedBox(
              height: MediaQuery.textScalerOf(context).scale(200),
              child: words,
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final steps = _steps(l10n);
    final last = _index == steps.length - 1;
    // Asks only while they are off; otherwise it is a plain last step.
    final notify = steps[_index].notify && !_alreadyOn;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // In from the corner: a rounded screen (the iPhone Duo open)
            // would clip a button set right into it.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.md,
                CardsSpace.sm,
                CardsSpace.md,
                0,
              ),
              child: SizedBox(
                height: CardsSizes.touch,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: AnimatedOpacity(
                    duration: CardsMotion.fast,
                    opacity: last ? 0 : 1,
                    child: TextButton(
                      onPressed: last ? null : () => _finish(skipped: true),
                      child: Text(l10n.onboardingSkip),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: _stage(steps)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.gutter,
                CardsSpace.lg,
                CardsSpace.gutter,
                CardsSpace.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dots(
                    count: steps.length,
                    index: _index,
                    label: l10n.onboardingStep(_index + 1, steps.length),
                  ),
                  const SizedBox(height: CardsSpace.xl),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: FilledButton(
                      onPressed: notify
                          ? _allowNotifications
                          : () => _next(steps.length),
                      child: AnimatedSwitcher(
                        duration: CardsMotion.standard,
                        switchInCurve: CardsMotion.curve,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, 0.35),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: Text(
                          notify
                              ? l10n.onboardingNotifyAllow
                              : (last
                                    ? l10n.onboardingStart
                                    : l10n.onboardingNext),
                          key: ValueKey((last, notify)),
                        ),
                      ),
                    ),
                  ),
                  // «ليس الآن» under the notifications step's button; the
                  // same room kept empty elsewhere, so nothing jumps.
                  if (_offerNotifications && !_alreadyOn)
                    SizedBox(
                      height: CardsSizes.touch,
                      child: AnimatedOpacity(
                        duration: CardsMotion.fast,
                        opacity: notify ? 1 : 0,
                        child: TextButton(
                          onPressed: notify
                              ? () => _finish(skipped: false)
                              : null,
                          child: Text(l10n.onboardingNotifyLater),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One step's words. They page with the swipe and fade as they leave, while
/// the picture above them stays put and changes.
class _Words extends StatelessWidget {
  const _Words({
    required this.step,
    required this.offset,
    required this.arrived,
  });

  final _Step step;

  /// How far the pages have moved past this one (−1 to 1).
  final double offset;

  /// 0 to 1: the first step's words rising in after the opening.
  final double arrived;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final near = Curves.easeOut.transform(
      (1 - offset.abs() * 1.4).clamp(0.0, 1.0),
    );
    return Opacity(
      opacity: near * arrived,
      child: Transform.translate(
        offset: Offset(0, (1 - arrived) * CardsSpace.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
          child: Align(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    step.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: CardsSpace.md),
                  Text(
                    step.body,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the customer is: the current step a capsule, the others dots.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index, required this.label});

  final int count;
  final int index;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: CardsMotion.standard,
              curve: CardsMotion.curve,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: i == index ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == index ? scheme.primary : scheme.outline,
                borderRadius: BorderRadius.circular(CardsRadii.pill),
              ),
            ),
        ],
      ),
    );
  }
}
