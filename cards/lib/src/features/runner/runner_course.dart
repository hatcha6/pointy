import 'dart:math' as math;

import 'runner_biome.dart';
import 'runner_hazards.dart';
import 'runner_physics.dart';

/// What the course lays down next: one obstacle, maybe coins with it.
class CourseStep {
  CourseStep(this.hazard, this.coins);

  final Hazard hazard;
  final List<Coin> coins;
}

/// Lays the course out ahead of the runner. It plans in time, not distance:
/// each obstacle is placed so that the gap between the runner clearing one
/// and the next one reaching it is long enough to land and jump again, at
/// the speed both of them are moving. So every course it builds can be run
/// forever by a player who never misses (the tests run one).
class RunnerCourse {
  RunnerCourse(this.random);

  final CourseRandom random;

  /// World time at which the next obstacle appears at the far edge.
  double nextAt = 1.2;

  HazardKind? _last;

  RunnerCourse copy() => RunnerCourse(random.copy())
    ..nextAt = nextAt
    .._last = _last;

  /// Where obstacles appear: just past the far edge of the screen.
  static double spawnX(double camera) => camera + RunnerPhysics.width + 12;

  /// The obstacle due now, at [time], [travelled] units into the run, with
  /// the screen's near edge at [camera] (world distance), moving at [speed],
  /// [points] in.
  CourseStep spawn({
    required double time,
    required double camera,
    required double travelled,
    required double speed,
    required int points,
  }) {
    final difficulty = RunnerPhysics.difficultyAt(travelled);
    final kind = _pick(points, speed, RunnerBiome.atX(spawnX(camera)));
    final spec = HazardSpec.of(kind);
    final x = spawnX(camera);
    final hazard = Hazard(kind, x, phase: random.nextDouble());
    final closing = speed + spec.speed;

    // When its front reaches the runner's front, and when its back has
    // passed the runner's back.
    final front = camera + RunnerPhysics.runnerX + RunnerPhysics.hitRight;
    final arrives = time + (x + spec.hitBox.left - front) / closing;
    final passes =
        arrives +
        (spec.hitBox.width + RunnerPhysics.hitRight - RunnerPhysics.hitLeft) /
            closing;

    // The breather before the next one: shorter as the course speeds up,
    // never shorter than a landing and a fresh jump.
    final gap =
        _lerp(0.95, 0.48, difficulty) +
        random.nextDouble() * _lerp(1.05, 0.6, difficulty) +
        (spec.overhead ? 0.22 : 0);

    // The next obstacle is chosen when it appears, so its own speed is not
    // known yet: plan for the fastest one that could come, which only ever
    // makes the gap longer for a slower one.
    final fastest = speed + _fastestFrom(points);
    final lead = (spawnX(camera) - front) / fastest;
    nextAt = math.max(time + 0.05, passes + gap - lead);
    _last = kind;

    final coins = <Coin>[];
    if (spec.speed == 0 && !spec.overhead && random.nextDouble() < 0.4) {
      coins.addAll(_arc(hazard, speed));
    } else if (gap > 1.2 && random.nextDouble() < 0.45) {
      coins.addAll(_row(front, time, passes, speed));
    }
    return CourseStep(hazard, coins);
  }

  /// A kind the runner can clear at [speed], unlocked by [points], and not
  /// the same as the last one more often than chance.
  HazardKind _pick(int points, double speed, RunnerBiome biome) {
    final open = HazardKind.values
        .where((kind) => HazardSpec.of(kind).unlock <= points)
        .where((kind) => HazardSpec.of(kind).belongsIn(biome))
        .where((kind) => clearable(kind, speed))
        .toList();
    var kind = open[random.nextInt(open.length)];
    if (kind == _last && open.length > 1) {
      kind = open[random.nextInt(open.length)];
    }
    // No two fliers overhead in a row: one is a lesson, two is a trick.
    if (HazardSpec.of(kind).overhead &&
        _last != null &&
        HazardSpec.of(_last!).overhead) {
      kind = HazardKind.spikes;
    }
    return kind;
  }

  double _fastestFrom(int points) => HazardKind.values
      .map(HazardSpec.of)
      .where((spec) => spec.unlock <= points)
      .map((spec) => spec.speed)
      .reduce(math.max);

  /// Whether a full jump clears [kind] at [speed], with room to spare.
  static bool clearable(HazardKind kind, double speed) {
    final spec = HazardSpec.of(kind);
    if (spec.overhead) {
      return true;
    }
    final needed =
        spec.hitBox.width + RunnerPhysics.hitRight - RunnerPhysics.hitLeft + 14;
    final top = spec.top + spec.bob;
    return JumpProfile.full.timeAbove(top) * (speed + spec.speed) >= needed;
  }

  /// Coins along the path of a good jump over [hazard], so they teach the
  /// timing and reward it.
  List<Coin> _arc(Hazard hazard, double speed) {
    final spec = hazard.spec;
    final profile = JumpProfile.of(0.12);
    final apex = profile.heights.indexOf(profile.apex);
    final centre = hazard.x + spec.hitBox.center.dx;
    final body = (RunnerPhysics.runnerSize - RunnerPhysics.hitTop) / 2;
    return [
      for (final f in const [0.18, 0.34, 0.5, 0.66, 0.82])
        () {
          final i = (profile.heights.length * f).round();
          return Coin(
            centre + (i - apex) * RunnerPhysics.step * speed,
            profile.heights[i] + body,
          );
        }(),
    ];
  }

  /// A short run of coins along the ground in a long gap.
  List<Coin> _row(double front, double time, double passes, double speed) {
    final count = 3 + random.nextInt(3);
    // The runner's front at the moment the obstacle has passed, then a beat.
    final start = front + (passes - time) * speed + 0.25 * speed;
    return [for (var i = 0; i < count; i++) Coin(start + i * 20, 15)];
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// A small random generator whose state can be copied (dart:math's cannot),
/// so a copy of a world builds the very same course ahead (xorshift32).
class CourseRandom {
  CourseRandom(int seed) {
    // Spread neighbouring seeds apart (xorshift needs a non-zero state).
    var x = (seed * 0x9E3779B1 + 0x7F4A7C15) & 0xffffffff;
    x ^= x >> 16;
    x = (x * 0x85EBCA6B) & 0xffffffff;
    x ^= x >> 13;
    _state = x == 0 ? 1 : x;
  }

  late int _state;

  CourseRandom copy() => CourseRandom(0).._state = _state;

  int _next() {
    var x = _state;
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    return _state = x & 0xffffffff;
  }

  /// In [0, 1).
  double nextDouble() => _next() / 4294967296.0;

  /// In [0, max).
  int nextInt(int max) => (nextDouble() * max).floor();
}
