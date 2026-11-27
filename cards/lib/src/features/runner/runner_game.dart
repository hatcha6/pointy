import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';
import 'runner_audio.dart';
import 'runner_biome.dart';
import 'runner_board.dart';
import 'runner_intro.dart';
import 'runner_overlays.dart';
import 'runner_painter.dart';
import 'runner_physics.dart';
import 'runner_records.dart';
import 'runner_sprites.dart';
import 'runner_world.dart';

/// What the game reports when a run ends, for the page's analytics.
typedef RunnerRunEnded = void Function(
  RunnerRun run, {
  required bool best,
  required Duration took,
});

/// The waiting room's endless runner: one tap to jump (hold to jump
/// higher), a course that speeds up, coins, and a score to beat. It pauses
/// whenever the app or the page is out of sight, and when the order arrives
/// mid-run it stops to say so rather than snatching the screen away.
class RunnerGame extends StatefulWidget {
  const RunnerGame({
    super.key,
    required this.records,
    required this.audio,
    this.board,
    this.reveal = false,
    this.orderReady = false,
    this.onShowOrder,
    this.onRunEnded,
    this.seed,
  });

  final RunnerRecords records;
  final RunnerAudio audio;

  /// The shared leaderboard each finished run is sent to; none in tests.
  final RunnerBoardRepository? board;

  /// Plays the entrance (runner_intro.dart) as the game first appears.
  final bool reveal;

  /// The order arrived while a run was on: the game pauses and offers it.
  final bool orderReady;

  /// Leaves the game for the arrived order.
  final VoidCallback? onShowOrder;
  final RunnerRunEnded? onRunEnded;

  /// A fixed course, for tests and previews.
  final int? seed;

  /// The world's width over its height: the same on every phone.
  static const double aspectRatio = RunnerPhysics.width / RunnerPhysics.height;

  @override
  State<RunnerGame> createState() => RunnerGameState();
}

class RunnerGameState extends State<RunnerGame>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final RunnerWorld _world = RunnerWorld(seed: widget.seed);
  late final Ticker _ticker = createTicker(_onTick);
  final _repaint = _Repaint();
  RunnerSprites? _sprites = RunnerSprites.loaded;
  final _focus = FocusNode(debugLabel: 'runner');

  Duration _last = Duration.zero;
  RunnerPhase _phase = RunnerPhase.ready;

  /// Stopped while the app or this page is out of sight.
  bool _paused = false;

  /// The order arrived mid-run and the game is waiting on the customer.
  bool _offering = false;

  /// When the run started, for the analytics.
  DateTime? _startedAt;

  /// World time when the run ended, for the retry delay.
  double? _overAt;

  /// The last run's result, for the overlay.
  bool _newBest = false;
  bool _unlocked = false;

  /// A run is under way: the page should not take the screen away.
  bool get inRun =>
      _phase == RunnerPhase.running || _phase == RunnerPhase.crashing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.records.load();
    widget.audio.warm();
    if (_sprites == null) {
      RunnerSprites.load().then(
        (sprites) {
          if (mounted) {
            setState(() => _sprites = sprites);
          }
        },
        onError: (Object _) {
          // No pictures, no game: the page around it still works.
        },
      );
    }
    _ticker.start();
  }

  /// Seconds into the entrance, or null when there is none (or it is over).
  /// A notifier, so the painter reads the current moment on every frame.
  final _introClock = ValueNotifier<double?>(null);
  double? get _intro => _introClock.value;
  set _intro(double? value) => _introClock.value = value;
  bool _introDecided = false;

  void _advanceIntro(double elapsed) {
    final before = _intro;
    if (before == null || _sprites == null) {
      return;
    }
    final now = before + elapsed;
    if (before < 0 && now >= 0 && !widget.records.muted) {
      widget.audio.play(RunnerSound.reveal);
    }
    if (before < RunnerIntro.landing && now >= RunnerIntro.landing) {
      _world.landFromAbove();
      Haptics.tap();
    }
    if (now >= RunnerIntro.duration) {
      setState(() => _intro = null);
    } else {
      _intro = now;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_introDecided) {
      _introDecided = true;
      // No entrance when the system asks for less motion.
      if (widget.reveal && !MediaQuery.disableAnimationsOf(context)) {
        _intro = -RunnerIntro.delay;
      }
    }
    // Another page over this one (the report sheet, the card form): stop,
    // and wait for a tap when it comes back.
    if (!TickerMode.valuesOf(context).enabled) {
      _pause();
    }
  }

  @override
  void didUpdateWidget(RunnerGame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.orderReady && !oldWidget.orderReady && inRun) {
      _offering = true;
      _world.release();
      widget.audio.play(RunnerSound.arrived);
      Haptics.success();
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _pause();
    }
  }

  @override
  void dispose() {
    // Leaving mid-run still counts the run.
    if (inRun) {
      _finish();
    }
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _repaint.dispose();
    _introClock.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Ends the run where it stands (the customer leaves for the order).
  void finishRun() {
    if (inRun) {
      _finish();
    }
  }

  void _pause() {
    if (_phase == RunnerPhase.running && !_paused) {
      _world.release();
      setState(() => _paused = true);
      _sync();
    }
  }

  /// Runs the clock only while there is something to move.
  void _sync() {
    final moving = !_paused && !_offering;
    if (moving && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!moving && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration now) {
    final elapsed = _last == Duration.zero ? Duration.zero : now - _last;
    _last = now;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _advanceIntro(seconds.clamp(0.0, 0.1));
    _world.advance(seconds);
    for (final event in _world.drainEvents()) {
      _feel(event);
    }
    if (_world.phase != _phase) {
      final from = _phase;
      _phase = _world.phase;
      if (_phase == RunnerPhase.running && from == RunnerPhase.ready) {
        _startedAt = DateTime.now();
      }
      if (_phase == RunnerPhase.over) {
        _finish();
      }
      setState(() {});
    }
    _repaint.changed();
    // The score has been read and the dust has settled: no need to keep
    // drawing the same picture 120 times a second.
    final over = _overAt;
    if (_phase == RunnerPhase.over &&
        over != null &&
        _world.time - over > 1.5) {
      _ticker.stop();
    }
  }

  void _feel(RunnerEvent event) {
    final audio = widget.records.muted ? null : widget.audio;
    // The ground under the runner's feet, for its footsteps.
    final ground = RunnerBiome.atX(
      _world.distance + RunnerPhysics.runnerX + RunnerPhysics.runnerSize / 2,
    ).ground;
    switch (event) {
      case RunnerEvent.start:
        audio?.play(RunnerSound.start);
      case RunnerEvent.jump:
        audio?.play(RunnerSound.jump);
      case RunnerEvent.land:
        audio?.play(RunnerSound.land, ground: ground);
      case RunnerEvent.step:
        audio?.play(RunnerSound.step, ground: ground);
      case RunnerEvent.coin:
        audio?.play(RunnerSound.coin);
      case RunnerEvent.milestone:
        audio?.play(RunnerSound.milestone);
        Haptics.select();
      case RunnerEvent.hit:
        audio?.play(RunnerSound.hit);
        HapticFeedback.heavyImpact();
    }
  }

  /// Counts the run: the table, a new best, a runner unlocked.
  void _finish() {
    final before = widget.records.best;
    final run = RunnerRun(
      score: _world.score,
      coins: _world.coinsTaken,
      at: DateTime.now(),
    );
    final place = widget.records.add(run);
    _newBest = place == 0 && run.score > before && before > 0;
    _unlocked = widget.records
        .unlockedBy(before, widget.records.best)
        .isNotEmpty;
    _overAt = _world.time;
    if (_newBest || _unlocked) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) {
          return;
        }
        if (!widget.records.muted) {
          widget.audio.play(RunnerSound.record);
        }
        Haptics.success();
      });
    }
    final took = DateTime.now().difference(_startedAt ?? DateTime.now());
    widget.board?.submit(run, took);
    widget.onRunEnded?.call(run, best: place == 0, took: took);
  }

  void _down(PointerDownEvent event) {
    _focus.requestFocus();
    _press();
  }

  void _press() {
    if (_offering) {
      return;
    }
    // A tap during the entrance skips to its end, and is not yet a jump.
    if (_intro != null) {
      setState(() => _intro = null);
      return;
    }
    if (_paused) {
      setState(() => _paused = false);
      _sync();
      return;
    }
    if (_phase == RunnerPhase.over) {
      // A beat after the crash, so a tap meant as a jump does not throw
      // the score away before it is read.
      final over = _overAt;
      if (over != null && _world.time - over < 0.55) {
        return;
      }
      _world.restart();
      _phase = RunnerPhase.ready;
      _newBest = false;
      _unlocked = false;
      setState(() {});
      _sync();
    }
    _world.press();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final jumps = {
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.enter,
    };
    if (!jumps.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _press();
    } else if (event is KeyUpEvent) {
      _world.release();
    }
    return KeyEventResult.handled;
  }

  void _keepPlaying() {
    setState(() => _offering = false);
    _sync();
  }

  void _showOrder() {
    finishRun();
    widget.onShowOrder?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mirrored = Directionality.of(context) == TextDirection.rtl;
    final calm = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: l10n.runnerGameLabel,
      value: l10n.runnerScore('${_world.score}'),
      button: true,
      child: AspectRatio(
        aspectRatio: RunnerGame.aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(CardsRadii.card),
          child: Builder(
            builder: (context) {
              final sprites = _sprites;
              if (sprites == null) {
                return const RunnerLoading();
              }
              return Focus(
                focusNode: _focus,
                onKeyEvent: _key,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _down,
                      onPointerUp: (_) => _world.release(),
                      onPointerCancel: (_) => _world.release(),
                      child: ListenableBuilder(
                        listenable: widget.records,
                        builder: (context, _) => CustomPaint(
                          painter: RunnerPainter(
                            world: _world,
                            sprites: sprites,
                            character: widget.records.character,
                            mirrored: mirrored,
                            calm: calm,
                            introClock: _introClock,
                            repaint: _repaint,
                          ),
                        ),
                      ),
                    ),
                    RunnerOverlay(
                      phase: _phase,
                      paused: _paused,
                      entering: _intro != null,
                      offering: _offering,
                      orderReady: widget.orderReady,
                      score: _world.score,
                      best: widget.records.best,
                      newBest: _newBest,
                      unlocked: _unlocked,
                      onShowOrder: _showOrder,
                      onKeepPlaying: _keepPlaying,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Repaint extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// Keeps a debug-only hook for tests to drive the world directly.
@visibleForTesting
extension RunnerGameTesting on RunnerGameState {
  RunnerWorld get world => _world;
}
