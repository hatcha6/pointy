import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../app.dart';
import '../../../data/services/local_scoped_json_storage.dart';
import '../../../data/services/pos_api_service.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../engine/lesson.dart';
import '../engine/lesson_runner.dart';
import '../sandbox/sandbox_client.dart';
import '../sandbox/sandbox_shop.dart';
import '../sandbox/seeds/seeds.dart';
import 'coach_panel.dart';

/// Runs one lesson: the real app, over a sandbox shop, with a coach panel.
///
/// The app inside is a second [PointyApp] with its own navigator, so every tap
/// the learner makes stays in the practice shop. Injecting an API service also
/// disables LAN discovery, so this app cannot go looking for — or find — the
/// real backend.
class LessonRunnerScreen extends StatefulWidget {
  const LessonRunnerScreen({super.key, required this.lesson});

  final TutorLesson lesson;

  @override
  State<LessonRunnerScreen> createState() => _LessonRunnerScreenState();
}

class _LessonRunnerScreenState extends State<LessonRunnerScreen> {
  late TutorRegistry _registry;
  late SandboxShop _shop;
  late LessonRunner _runner;
  late PosApiService _service;

  /// Bumped on restart so the hosted app is rebuilt from scratch rather than
  /// reusing a tree that still holds the finished sale.
  int _generation = 0;

  /// Ticks the runner so steps completed by typing — or by the sandbox moving
  /// underneath — are noticed. Cheap: a handful of comparisons.
  Timer? _tick;
  static const _tickInterval = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Sweep keys left by builds that predate the diversion in
    // [PracticeStorageScopes]: an abandoned lesson used to leave its cart
    // snapshot on the device forever, because only a *completed* sale clears
    // it. Cheap, and there is no better moment than opening a lesson.
    unawaited(PracticeStorageScopes.purgeFromDevice());
    _build();
  }

  void _build() {
    _registry = TutorRegistry();
    _shop = buildSandboxShop(widget.lesson.seed);
    _service = PosApiService(client: SandboxClient(_shop));
    _runner = LessonRunner(
      lesson: widget.lesson,
      shop: _shop,
      registry: _registry,
    )..addListener(_onRunnerChanged);
    _tick = Timer.periodic(_tickInterval, (_) => _runner.reevaluate());
  }

  void _teardown() {
    _tick?.cancel();
    _tick = null;
    _runner
      ..removeListener(_onRunnerChanged)
      ..dispose();
    _registry.dispose();
  }

  void _onRunnerChanged() {
    // The learner did the thing: advance for them. `tryAdvance` only moves when
    // the step's expectation is actually satisfied, so this can never skip
    // ahead of what they did.
    _runner.tryAdvance();
  }

  void _restart() {
    setState(() {
      _teardown();
      _generation++;
      _build();
    });
  }

  Future<void> _exit() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed =
        _runner.isFinished ||
        await showDialog<bool>(
              context: context,
              builder: (_) => PointyConfirmationDialog(
                icon: Icons.exit_to_app,
                title: l10n.lessonExitConfirmTitle,
                message: l10n.lessonExitConfirmMessage,
                confirmLabel: l10n.lessonExitButton,
              ),
            ) ==
            true;
    if (confirmed && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _exit();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const _TrainingBanner(),
              // The coach sits *under* the practice shop, never beside it.
              //
              // A side column looked better and was wrong: it took ~360px off
              // the POS, dropping it under its two-pane breakpoint, so the
              // learner was taught "add an item and watch the cart" on a layout
              // that hides the cart behind a button. It also made the lesson
              // behave differently here than in CI, which hosts the app at full
              // width — the one divergence this whole design exists to prevent.
              Expanded(
                child: _SandboxedApp(
                  key: ValueKey('sandbox_$_generation'),
                  registry: _registry,
                  service: _service,
                  runner: _runner,
                ),
              ),
              Padding(
                padding: EdgeInsetsDirectional.only(top: spacing.xs),
                child: CoachPanel(
                  runner: _runner,
                  onExit: _exit,
                  onRestart: _restart,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The practice shop plus the ring drawn round the step's control.
class _SandboxedApp extends StatelessWidget {
  const _SandboxedApp({
    super.key,
    required this.registry,
    required this.service,
    required this.runner,
  });

  final TutorRegistry registry;
  final PosApiService service;
  final LessonRunner runner;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return DecoratedBox(
      // The frame is part of §9's "unmistakable": the practice shop is visibly
      // boxed off from the app around it, from across the counter.
      decoration: BoxDecoration(
        border: Border.all(color: colors.warning, width: 2),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: TutorScope(
              registry: registry,
              child: PointyApp(apiService: service),
            ),
          ),
          Positioned.fill(
            child: TutorSpotlight(registry: registry, runner: runner),
          ),
        ],
      ),
    );
  }
}

/// Full width, always visible, never dismissible.
///
/// This is a safety requirement, not decoration (§9): a trainee who believes a
/// practice sale took real money hands over goods, and a cashier who believes a
/// real sale is practice hands over goods without ringing it.
class _TrainingBanner extends StatelessWidget {
  const _TrainingBanner();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return Container(
      width: double.infinity,
      color: colors.warning,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.school_outlined, color: colors.surface),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.trainingModeBannerTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.surface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  l10n.trainingModeBannerMessage,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.surface),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
