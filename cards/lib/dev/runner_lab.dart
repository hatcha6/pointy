// Dev-only (safe to delete): the waiting game's landscape changes, watched
// without playing to them. The runner flies over an empty course from just
// before a border, round and round; `?screen=runner-biomes&border=1..4`.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../src/features/runner/runner_painter.dart';
import '../src/features/runner/runner_physics.dart';
import '../src/features/runner/runner_sprites.dart';
import '../src/features/runner/runner_world.dart';

class RunnerBiomeLab extends StatefulWidget {
  const RunnerBiomeLab({super.key, this.border = 1});

  /// Which landscape border to start before (1 is hills to desert).
  final int border;

  @override
  State<RunnerBiomeLab> createState() => _RunnerBiomeLabState();
}

class _RunnerBiomeLabState extends State<RunnerBiomeLab>
    with SingleTickerProviderStateMixin {
  final _world = RunnerWorld(seed: 1);
  final _repaint = ValueNotifier(0);
  late final Ticker _ticker;
  RunnerSprites? _sprites;
  Duration _last = Duration.zero;

  double get _start =>
      widget.border * RunnerPhysics.biomeLength - RunnerPhysics.width - 150;

  @override
  void initState() {
    super.initState();
    _world.press();
    _world.release();
    _world.distance = _start;
    RunnerSprites.load().then((s) => setState(() => _sprites = s));
    _ticker = createTicker((now) {
      final dt = _last == Duration.zero ? Duration.zero : now - _last;
      _last = now;
      _world.advance(dt.inMicroseconds / 1e6);
      // Nothing in the way: this is a view, not a run.
      _world.hazards.clear();
      // Round again once the far hills have changed too.
      if (_world.distance > _start + 4200) {
        _world.distance = _start;
      }
      _repaint.value++;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sprites = _sprites;
    return Scaffold(
      body: Center(
        child: sprites == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: RunnerPhysics.width / RunnerPhysics.height,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: CustomPaint(
                      painter: RunnerPainter(
                        world: _world,
                        sprites: sprites,
                        character: RunnerCharacter.green,
                        mirrored:
                            Directionality.of(context) == TextDirection.rtl,
                        calm: false,
                        repaint: _repaint,
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
