import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import 'runner_world.dart';

/// The words over the game: how to play, the result, a pause, the order
/// that arrived. Taps pass through everything but the order's buttons, so
/// the game itself always hears the tap.
class RunnerOverlay extends StatelessWidget {
  const RunnerOverlay({
    super.key,
    required this.phase,
    required this.paused,
    this.entering = false,
    required this.offering,
    required this.orderReady,
    required this.score,
    required this.best,
    required this.newBest,
    required this.unlocked,
    required this.onShowOrder,
    required this.onKeepPlaying,
  });

  final RunnerPhase phase;
  final bool paused;

  /// The game is still making its entrance: nothing over it yet.
  final bool entering;
  final bool offering;
  final bool orderReady;
  final int score;
  final int best;
  final bool newBest;
  final bool unlocked;
  final VoidCallback onShowOrder;
  final VoidCallback onKeepPlaying;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final Widget? child;
    var interactive = false;
    if (offering) {
      interactive = true;
      child = _Panel(
        children: [
          _Title(l10n.runnerArrived, big: true),
          const SizedBox(height: CardsSpace.md),
          FilledButton(
            style: _button,
            onPressed: onShowOrder,
            child: Text(l10n.runnerShowOrder),
          ),
          TextButton(
            onPressed: onKeepPlaying,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(180, 40),
            ),
            child: Text(l10n.runnerKeepPlaying),
          ),
        ],
      );
    } else if (paused) {
      child = _Chip(text: l10n.runnerPaused, icon: Icons.play_arrow_rounded);
    } else if (entering) {
      child = null;
    } else if (phase == RunnerPhase.ready) {
      child = _Hint(title: l10n.runnerTapToJump, hint: l10n.runnerHoldHint);
    } else if (phase == RunnerPhase.over) {
      interactive = orderReady;
      child = _Panel(
        children: [
          _Title(l10n.runnerOver),
          _Score(score),
          if (newBest)
            _Badge(text: l10n.runnerNewBest)
          else
            _Caption(l10n.runnerBest('$best')),
          if (unlocked) ...[
            const SizedBox(height: CardsSpace.xs),
            _Badge(text: l10n.runnerUnlocked),
          ],
          const SizedBox(height: CardsSpace.sm),
          if (orderReady)
            FilledButton(
              style: _button,
              onPressed: onShowOrder,
              child: Text(l10n.runnerShowOrder),
            )
          else
            _Caption(l10n.runnerTapAgain, delay: true),
        ],
      );
    } else {
      child = null;
    }
    return IgnorePointer(
      ignoring: !interactive,
      child: AnimatedSwitcher(
        duration: CardsMotion.standard,
        switchInCurve: CardsMotion.curve,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.94, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        child: child == null
            ? const SizedBox.expand()
            : Center(
                key: ValueKey('$phase$paused$offering$orderReady'),
                child: Padding(
                  padding: const EdgeInsets.all(CardsSpace.sm),
                  child: FittedBox(fit: BoxFit.scaleDown, child: child),
                ),
              ),
      ),
    );
  }
}

const _ink = Color(0xE61B2433);

/// The app's buttons stretch to the page's width; inside the game they
/// size to their words.
final _button = FilledButton.styleFrom(minimumSize: const Size(180, 44));

class _Panel extends StatelessWidget {
  const _Panel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 200),
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.xl,
        vertical: CardsSpace.md,
      ),
      decoration: BoxDecoration(
        color: _ink,
        borderRadius: BorderRadius.circular(CardsRadii.tile),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text, {this.big = false});

  final String text;
  final bool big;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style:
        (big
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.labelLarge)
            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
  );
}

class _Score extends StatelessWidget {
  const _Score(this.score);

  final int score;

  @override
  Widget build(BuildContext context) => Text(
    '$score',
    textDirection: TextDirection.ltr,
    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w800,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.1,
    ),
  );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text, {this.delay = false});

  final String text;

  /// Fades in a beat late, as the game starts listening for the retry.
  final bool delay;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Colors.white.withValues(alpha: 0.82)),
    );
    if (!delay) {
      return label;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: const Interval(0.6, 1),
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: label,
    );
  }
}

/// A gold pill for a record or an unlock.
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.5, end: 1),
      duration: CardsMotion.emphasized,
      curve: CardsMotion.spring,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.md,
          vertical: CardsSpace.xs,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFFFC83D),
          borderRadius: BorderRadius.circular(CardsRadii.pill),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: const Color(0xFF3A2A00),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.lg,
        vertical: CardsSpace.sm,
      ),
      decoration: BoxDecoration(
        color: _ink,
        borderRadius: BorderRadius.circular(CardsRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: CardsSpace.xs),
          Text(
            text,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// «اضغط للقفز», breathing gently so the eye finds it.
class _Hint extends StatefulWidget {
  const _Hint({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_Hint> createState() => _HintState();
}

class _HintState extends State<_Hint> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _breath.value = 0.5;
      _breath.stop();
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ScaleTransition(
      scale: Tween(
        begin: 0.97,
        end: 1.03,
      ).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut)),
      child: _Panel(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.touch_app_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: CardsSpace.xs),
              Text(
                widget.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            widget.hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

/// The game's frame while its pictures load: the sky it will open on.
class RunnerLoading extends StatelessWidget {
  const RunnerLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFAFD8FF), Color(0xFFEEF7FF)],
        ),
      ),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    );
  }
}
