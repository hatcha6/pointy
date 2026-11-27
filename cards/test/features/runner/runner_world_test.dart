import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/features/runner/runner_biome.dart';
import 'package:pointy_cards/src/features/runner/runner_course.dart';
import 'package:pointy_cards/src/features/runner/runner_hazards.dart';
import 'package:pointy_cards/src/features/runner/runner_physics.dart';
import 'package:pointy_cards/src/features/runner/runner_world.dart';

/// A player who never misses: before each obstacle it looks ahead on an
/// exact copy of the world and jumps at the last moment that clears it and
/// still leaves a way past the obstacle after it. If the course ever asks
/// for a jump that does not exist, this player crashes and the test fails.
class PerfectPlayer {
  PerfectPlayer(this.world);

  final RunnerWorld world;

  /// The jump planned: press in this many ticks, hold for that many.
  int? _pressIn;
  int _holdFor = 0;
  int _holding = 0;

  static const _holds = [0, 10, 27];
  static const _horizon = 150;

  void tick() {
    if (_holding > 0 && --_holding == 0) {
      world.release();
    }
    if (_pressIn == null && world.grounded) {
      final plan = _plan(world, 1);
      if (plan != null) {
        _pressIn = plan.$1;
        _holdFor = plan.$2;
      }
    }
    if (_pressIn != null && _pressIn! <= 0 && world.grounded) {
      world.press();
      _pressIn = null;
      _holding = _holdFor;
      if (_holding == 0) {
        world.release();
      }
    } else if (_pressIn != null) {
      _pressIn = _pressIn! - 1;
    }
    world.tick();
  }

  /// When to jump and how long to hold, or null when running on is safe.
  static (int, int)? _plan(RunnerWorld world, int depth) {
    final crashAt = _crashTick(world.copy());
    if (crashAt == null) {
      return null;
    }
    for (var delay = crashAt - 1; delay >= 0; delay -= 2) {
      for (final hold in _holds) {
        final probe = world.copy();
        for (var i = 0; i < delay; i++) {
          probe.tick();
        }
        if (probe.phase != RunnerPhase.running) {
          break;
        }
        probe.press();
        if (hold == 0) {
          probe.release();
        }
        var ticks = 0;
        while (!probe.grounded || ticks == 0) {
          if (ticks == hold) {
            probe.release();
          }
          probe.tick();
          ticks++;
          if (probe.phase != RunnerPhase.running) {
            break;
          }
        }
        if (probe.phase != RunnerPhase.running) {
          continue;
        }
        if (depth > 0 && _plan(probe, depth - 1) == (-1, -1)) {
          continue;
        }
        return (delay, hold);
      }
    }
    return (-1, -1);
  }

  /// The tick at which running on without jumping crashes, if it does
  /// within the horizon.
  static int? _crashTick(RunnerWorld world) {
    for (var i = 0; i < _horizon; i++) {
      world.tick();
      if (world.phase != RunnerPhase.running) {
        return i;
      }
    }
    return null;
  }
}

void main() {
  test('a jump clears every obstacle the course can lay down', () {
    for (final kind in HazardKind.values) {
      final spec = HazardSpec.of(kind);
      // From the speed at which it first appears, to the top.
      final unlocked = RunnerPhysics.speedAt(
        spec.unlock * RunnerPhysics.unitsPerPoint,
      );
      for (final speed in [unlocked, RunnerPhysics.topSpeed]) {
        if (spec.overhead) {
          // Cleared by staying down: it must be above a standing runner.
          expect(
            spec.bottom - spec.bob,
            greaterThan(RunnerPhysics.runnerSize - RunnerPhysics.hitTop),
            reason: '$kind',
          );
        } else {
          expect(RunnerCourse.clearable(kind, speed), isTrue, reason: '$kind');
          // And never so high that only a pixel-perfect jump clears it.
          expect(
            spec.top + spec.bob,
            lessThan(JumpProfile.full.apex - 20),
            reason: '$kind',
          );
        }
      }
    }
  });

  test('holding the tap jumps higher than a quick tap', () {
    expect(JumpProfile.full.apex, greaterThan(JumpProfile.short.apex + 20));
  });

  test('a player who never misses outruns every course', () {
    // Long enough to reach top speed and every kind of obstacle.
    const goal = 5200 * RunnerPhysics.unitsPerPoint;
    for (var seed = 1; seed <= 12; seed++) {
      final world = RunnerWorld(seed: seed)..press();
      world.release();
      final player = PerfectPlayer(world);
      final seen = <HazardKind>{};
      final placed = <Hazard>{};
      while (world.distance < goal) {
        player.tick();
        seen.addAll(world.hazards.map((h) => h.kind));
        // Each obstacle stands in a landscape it belongs to: the cactus in
        // the desert only, nothing green against green hills.
        for (final hazard in world.hazards.where(placed.add)) {
          final biome = RunnerBiome.atX(hazard.x);
          expect(
            hazard.spec.belongsIn(biome),
            isTrue,
            reason: '${hazard.kind} in $biome',
          );
          if (hazard.kind == HazardKind.cactus) {
            expect(biome, RunnerBiome.desert);
          }
          if (biome.green) {
            expect(hazard.spec.green, isFalse, reason: '${hazard.kind}');
          }
        }
        expect(
          world.phase,
          RunnerPhase.running,
          reason:
              'seed $seed crashed at ${world.distancePoints} points into '
              '${world.hazards.where((h) => world.hazardBox(h).overlaps(world.runnerBox)).map((h) => h.kind)}',
        );
      }
      expect(seen, containsAll(HazardKind.values), reason: 'seed $seed');
      expect(world.speed, closeTo(RunnerPhysics.topSpeed, 40));
    }
  });

  test('running on without jumping crashes into the first obstacle', () {
    final world = RunnerWorld(seed: 3)..press();
    world.release();
    for (var i = 0; i < 120 * 20 && world.phase == RunnerPhase.running; i++) {
      world.tick();
    }
    expect(world.phase, isNot(RunnerPhase.running));
    expect(world.drainEvents(), contains(RunnerEvent.hit));
  });

  test('a tap just before landing jumps again on touchdown', () {
    final world = RunnerWorld(seed: 4)..press();
    world.release();
    while (world.velocity > -200) {
      world.tick();
    }
    world.press();
    world.release();
    // Down, and straight back up without another tap.
    var landed = false;
    for (var i = 0; i < 60; i++) {
      world.tick();
      if (world.landedAgo == 0) {
        landed = true;
      }
    }
    expect(landed, isTrue);
    expect(
      world.drainEvents().where((e) => e == RunnerEvent.jump),
      hasLength(2),
    );
  });

  test('the same seed lays down the same course', () {
    List<String> course(int seed) {
      final world = RunnerWorld(seed: seed)..press();
      world.release();
      final player = PerfectPlayer(world);
      while (world.distance < 8000) {
        player.tick();
      }
      return [
        for (final h in world.hazards) '${h.kind}@${h.x.toStringAsFixed(1)}',
      ];
    }

    expect(course(11), course(11));
    expect(course(11), isNot(course(12)));
  });

  test('a footstep sounds on the tick the walk swaps feet, never mid-air', () {
    final world = RunnerWorld(seed: 8)..press();
    world.release();
    final player = PerfectPlayer(world);
    var steps = 0;
    var lastFoot = world.footfall;
    while (world.distance < 6000) {
      player.tick();
      final events = world.drainEvents();
      final swapped = world.footfall != lastFoot;
      lastFoot = world.footfall;
      if (events.contains(RunnerEvent.step)) {
        steps++;
        expect(swapped, isTrue);
        expect(world.grounded, isTrue);
      }
    }
    // Most strides on the ground are heard.
    expect(steps, greaterThan(6000 / RunnerPhysics.stride * 0.4));
  });

  test('idling before the first tap scores nothing', () {
    final world = RunnerWorld(seed: 6);
    for (var i = 0; i < 120 * 5; i++) {
      world.tick();
    }
    expect(world.score, 0);
    world.press();
    expect(world.score, 0);
  });

  test('restart clears the run', () {
    final world = RunnerWorld(seed: 5)..press();
    for (var i = 0; i < 600; i++) {
      world.tick();
    }
    world.restart();
    expect(world.phase, RunnerPhase.ready);
    expect(world.score, 0);
    expect(world.hazards, isEmpty);
  });
}
