import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';
import '../splash/splash_handoff.dart';
import '../attribution/heard_from_form.dart';
import 'onboarding_art.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../shared/cards_scope.dart';

/// The first run: three short steps, each a picture in the mark's style, a
/// title and a sentence, then the shelf. Skippable from the first step; no
/// sign-in. On a phone a fourth step offers notifications, the one question
/// the phone itself then asks; «ليس الآن» leaves it for after the first
/// card.
///
/// With [askHeardFrom], the last step is «من أين سمعت عنا؟»: the picture
/// shrinks and rises out of the way, the last words fade, and the question
/// builds itself in under it, one part after another. «تخطَّ» on any step
/// goes to it rather than past it; it is skippable too.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.onDone,
    this.askHeardFrom = false,
    this.startAsking = false,
  });

  /// Skipped or finished: either way it is not shown again.
  final VoidCallback onDone;

  /// End on «من أين سمعت عنا؟» (the first run, while never answered).
  final bool askHeardFrom;

  /// Open on the question (the preview harness).
  final bool startAsking;

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
  final _wordsKey = GlobalKey();

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

  /// The step into «من أين سمعت عنا؟»: 0 the steps, 1 the question.
  late final _toQuestion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _asking = false;
  bool _questionReady = false;
  final _question = GlobalKey<HeardFromFormState>();

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
    if (widget.askHeardFrom && widget.startAsking) {
      _asking = true;
      _toQuestion.value = 1;
    }
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
    _toQuestion.dispose();
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
      _onward(skipped: false);
    }
  }

  /// Past the steps: to the question when it is asked, else done.
  void _onward({required bool skipped}) {
    if (widget.askHeardFrom && !_asking) {
      _ask();
    } else {
      _finish(skipped: skipped);
    }
  }

  void _ask() {
    Haptics.select();
    _ring
      ..stop()
      ..value = 0;
    setState(() => _asking = true);
    if (MediaQuery.disableAnimationsOf(context)) {
      _toQuestion.value = 1;
    } else {
      _toQuestion.forward();
    }
  }

  void _finish({required bool skipped}) {
    CardsScope.of(context).analytics
        .onboardingFinished(skipped: skipped, step: _index + 1);
    widget.onDone();
  }

  void _next(int count) {
    if (_asking) {
      Haptics.success();
      _question.currentState?.submit();
      return;
    }
    if (_index >= count - 1) {
      Haptics.success();
      _onward(skipped: false);
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

  /// Where the swipe is, in steps. For the frame in which the layout turns
  /// (a phone rotated, a browser's bar sliding away), the old and the new
  /// page view are both attached, and the controller's `position` would
  /// throw ("Too many elements"): the step the pages rest on stands in.
  double get _page {
    if (_pages.positions.length != 1 || !_pages.position.haveDimensions) {
      return _index.toDouble();
    }
    return _pages.page ?? _index.toDouble();
  }

  /// One picture that stays where it is and morphs from step to step as the
  /// pages move, and the steps' words, which are what the swipe pages
  /// through. Beside each other where the screen is wider than it is tall
  /// (a tablet, the iPhone Duo open), the picture above otherwise.
  Widget _stage(List<_Step> steps) {
    final moving = Listenable.merge([_pages, _intro, _ring, _toQuestion]);
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
              // Turning into the question's own picture as it rises.
              heard: const Interval(0.05, 0.75).transform(_toQuestion.value),
            ),
          ),
        ),
      ),
    );
    final words = PageView.builder(
      // One page view, wherever the layout puts it: turning the screen moves
      // it, swipe and all, instead of building a second one.
      key: _wordsKey,
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
    if (_asking) {
      return _questionStage(steps, art);
    }
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

  /// The steps' stage turning into the question. On a phone held upright
  /// the picture, as it was, glides up and shrinks to a small one above the
  /// question; side by side (landscape, a tablet) it stays in its own
  /// column, settling a little smaller, and the question builds in the
  /// words' column. Either way the picture turns into the question's own
  /// and the last step's words sink and fade where the question appears.
  Widget _questionStage(List<_Step> steps, Widget art) {
    final glide = CurvedAnimation(
      parent: _toQuestion,
      curve: const Interval(0, 0.7, curve: CardsMotion.curve),
    );
    final leave = CurvedAnimation(
      parent: _toQuestion,
      curve: const Interval(0, 0.3, curve: Curves.easeIn),
    );
    Widget form({bool compact = false}) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: HeardFromForm(
        key: _question,
        actions: false,
        centered: true,
        compact: compact,
        entrance: _toQuestion,
        onReady: (ready) => setState(() => _questionReady = ready),
        onDone: () => _finish(skipped: false),
      ),
    );
    // The last step's words, leaving. On their way out they may stand
    // taller than a short landscape stage: clipped, never squeezed.
    Widget leaving() => IgnorePointer(
      child: ClipRect(
        child: OverflowBox(
          maxHeight: double.infinity,
          child: Opacity(
            opacity: 1 - leave.value,
            child: Transform.translate(
              offset: Offset(0, leave.value * CardsSpace.xl),
              child: _Words(step: steps[_index], offset: 0, arrived: 1),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (width > height && width >= 560) {
          return _questionBeside(
            art,
            // A phone on its side has room for the title and the answers,
            // not the line between them.
            form(compact: height < 320),
            leaving,
            glide,
            leave,
            height,
          );
        }
        // Where the picture stood among the steps (as [_stage] lays it).
        final wordsHeight = MediaQuery.textScalerOf(context).scale(200);
        final fromSide = [
          340.0,
          width - CardsSpace.gutter * 2,
          height - wordsHeight - CardsSpace.xl,
        ].reduce((a, b) => a < b ? a : b).clamp(0.0, 340.0);
        final fromCenter = Offset(
          width / 2,
          (height - wordsHeight - CardsSpace.xl) / 2,
        );
        const toSide = 132.0;
        final toCenter = Offset(width / 2, toSide / 2);
        return AnimatedBuilder(
          animation: _toQuestion,
          builder: (context, _) {
            final t = glide.value;
            final side = fromSide + (toSide - fromSide) * t;
            final center = Offset.lerp(fromCenter, toCenter, t)!;
            return Stack(
              children: [
                if (leave.value < 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: height - wordsHeight,
                    bottom: 0,
                    child: leaving(),
                  ),
                Positioned.fill(
                  top: toSide + CardsSpace.lg,
                  child: _FadingScroll(
                    padding: const EdgeInsets.fromLTRB(
                      CardsSpace.gutter,
                      0,
                      CardsSpace.gutter,
                      CardsSpace.lg,
                    ),
                    child: Align(alignment: Alignment.topCenter, child: form()),
                  ),
                ),
                Positioned(
                  left: center.dx - side / 2,
                  top: center.dy - side / 2,
                  width: side,
                  height: side,
                  child: IgnorePointer(child: art),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Landscape and tablets: the steps' two columns, kept. The picture's
  /// column keeps its width (nothing beside it moves) while the picture
  /// settles a fifth smaller; the words' column trades the last step's
  /// words for the question, centred, scrolling on a short screen.
  Widget _questionBeside(
    Widget art,
    Widget form,
    Widget Function() leaving,
    Animation<double> glide,
    Animation<double> leave,
    double height,
  ) {
    // As [_stage] sizes the picture beside the words.
    final side = (height - CardsSpace.xl * 2).clamp(0.0, 360.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CardsSpace.huge),
      child: Row(
        // The question's column takes the stage's whole height to scroll in.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: side,
            child: Center(
              child: AnimatedBuilder(
                animation: glide,
                builder: (context, child) => SizedBox.square(
                  dimension: side * (1 - 0.2 * glide.value),
                  child: child,
                ),
                child: IgnorePointer(child: art),
              ),
            ),
          ),
          const SizedBox(width: CardsSpace.huge),
          Expanded(
            child: Stack(
              children: [
                AnimatedBuilder(
                  animation: leave,
                  builder: (context, _) => leave.value < 1
                      ? Positioned.fill(child: leaving())
                      : const SizedBox.shrink(),
                ),
                Positioned.fill(
                  child: _FadingScroll(
                    padding: const EdgeInsets.symmetric(
                      vertical: CardsSpace.md,
                    ),
                    center: true,
                    child: form,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final steps = _steps(l10n);
    final total = steps.length + (widget.askHeardFrom ? 1 : 0);
    final current = _asking ? steps.length : _index;
    // The last step finishes: the onboarding's own, or the question.
    final last = current == total - 1;
    // Asks only while they are off; otherwise it is a plain last step.
    final notify = !_asking && steps[_index].notify && !_alreadyOn;
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
                    opacity: last && !_asking ? 0 : 1,
                    child: TextButton(
                      onPressed: last && !_asking
                          ? null
                          : _asking
                          ? () => _question.currentState?.skip()
                          : () => _onward(skipped: true),
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
                    count: total,
                    index: current,
                    label: l10n.onboardingStep(current + 1, total),
                  ),
                  const SizedBox(height: CardsSpace.xl),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: FilledButton(
                      onPressed: notify
                          ? _allowNotifications
                          : _asking && !_questionReady
                          ? null
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
                              : _asking
                              ? l10n.continueAction
                              : (last
                                    ? l10n.onboardingStart
                                    : l10n.onboardingNext),
                          key: ValueKey((last, notify, _asking)),
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
                              ? () => _onward(skipped: false)
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

/// The question's room: it scrolls when the screen is too short for it,
/// its edges fading rather than cutting the answers off. With [center],
/// centred when it fits.
class _FadingScroll extends StatelessWidget {
  const _FadingScroll({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.center = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool center;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final edge = (CardsSpace.md / bounds.height).clamp(0.0, 0.5);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [
              Color(0x00000000),
              Color(0xFF000000),
              Color(0xFF000000),
              Color(0x00000000),
            ],
            stops: [0, edge, 1 - edge, 1],
          ).createShader(bounds);
        },
        child: SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: center
                  ? (constraints.maxHeight - padding.vertical).clamp(
                      0.0,
                      double.infinity,
                    )
                  : 0,
            ),
            child: center ? Center(child: child) : child,
          ),
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
