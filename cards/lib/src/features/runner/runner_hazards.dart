import 'dart:ui';

import 'runner_biome.dart';
import 'runner_physics.dart';

/// Everything that can be in the runner's way. Each is drawn in a square of
/// [HazardSpec.size] units whose bottom sits [HazardSpec.altitude] above the
/// ground; [HazardSpec.hit] is the part of that square that hurts.
enum HazardKind {
  spikes,
  rock,
  crate,
  crates,
  slime,
  cactus,
  snail,
  ladybug,
  spikeSlime,
  saw,
  lowFly,
  mouse,
  bee,
}

class HazardSpec {
  const HazardSpec({
    required this.frames,
    required this.hit,
    required this.unlock,
    this.size = 30,
    this.copies = 1,
    this.altitude = 0,
    this.speed = 0,
    this.bob = 0,
    this.spin = false,
    this.green = false,
    this.desertOnly = false,
  });

  /// The sprite's frames (`assets/runner/<name>.png`), played in turn.
  final List<String> frames;

  /// The hurting part of one square, from its top-left corner, y down.
  final Rect hit;

  /// The score from which it may appear.
  final int unlock;

  final double size;

  /// Side by side (a row of crates), drawn as one obstacle.
  final int copies;

  /// How far the square's bottom is above the ground: a flier's height, or
  /// below zero for a saw half sunk into the earth.
  final double altitude;

  /// Its own speed toward the runner, on top of the runner's.
  final double speed;

  /// How far a flier drifts up and down.
  final double bob;

  /// Rolls (the saw).
  final bool spin;

  /// Drawn in green: kept out of the green landscapes, where it would be
  /// hard to see.
  final bool green;

  /// Belongs in the desert (the cactus), and nowhere else.
  final bool desertOnly;

  /// Width of everything drawn.
  double get width => size * copies;

  /// The hurting part of the whole obstacle.
  Rect get hitBox => Rect.fromLTRB(
    hit.left,
    hit.top,
    hit.right + size * (copies - 1),
    hit.bottom,
  );

  /// Height of the top of its hit box above the ground, at rest.
  double get top => altitude + size - hit.top;

  /// Height of the bottom of its hit box above the ground, at rest.
  double get bottom => altitude + size - hit.bottom;

  /// Too high to hit a runner who stays on the ground: the one thing the
  /// player clears by not jumping.
  bool get overhead =>
      bottom - bob > RunnerPhysics.runnerSize - RunnerPhysics.hitTop + 4;

  /// Whether it may appear in [biome].
  bool belongsIn(RunnerBiome biome) =>
      (!desertOnly || biome == RunnerBiome.desert) && !(green && biome.green);

  static HazardSpec of(HazardKind kind) => _specs[kind]!;

  static const Map<HazardKind, HazardSpec> _specs = {
    HazardKind.spikes: HazardSpec(
      frames: ['spikes'],
      hit: Rect.fromLTRB(4, 19, 26, 30),
      unlock: 0,
    ),
    HazardKind.rock: HazardSpec(
      frames: ['rock'],
      hit: Rect.fromLTRB(4, 13, 26, 30),
      unlock: 0,
    ),
    HazardKind.crate: HazardSpec(
      frames: ['block_planks'],
      size: 26,
      hit: Rect.fromLTRB(3, 3, 23, 26),
      unlock: 0,
    ),
    HazardKind.slime: HazardSpec(
      frames: ['slime_normal_walk_a', 'slime_normal_walk_b'],
      hit: Rect.fromLTRB(5, 14, 26, 30),
      speed: 22,
      unlock: 0,
    ),
    HazardKind.cactus: HazardSpec(
      frames: ['cactus'],
      size: 32,
      hit: Rect.fromLTRB(9, 4, 23, 32),
      green: true,
      desertOnly: true,
      unlock: 120,
    ),
    HazardKind.snail: HazardSpec(
      frames: ['snail_walk_a', 'snail_walk_b'],
      hit: Rect.fromLTRB(4, 10, 27, 30),
      speed: 10,
      unlock: 120,
    ),
    HazardKind.crates: HazardSpec(
      frames: ['block_planks'],
      size: 26,
      copies: 2,
      hit: Rect.fromLTRB(3, 3, 23, 26),
      unlock: 250,
    ),
    HazardKind.ladybug: HazardSpec(
      frames: ['ladybug_walk_a', 'ladybug_walk_b'],
      hit: Rect.fromLTRB(4, 11, 27, 30),
      speed: 38,
      unlock: 250,
    ),
    HazardKind.spikeSlime: HazardSpec(
      frames: ['slime_spike_walk_a', 'slime_spike_walk_b'],
      hit: Rect.fromLTRB(5, 9, 26, 30),
      speed: 18,
      green: true,
      unlock: 400,
    ),
    HazardKind.saw: HazardSpec(
      frames: ['saw_a', 'saw_b'],
      size: 30,
      altitude: -7,
      hit: Rect.fromLTRB(5, 5, 25, 25),
      speed: 30,
      spin: true,
      unlock: 400,
    ),
    HazardKind.lowFly: HazardSpec(
      frames: ['fly_a', 'fly_b'],
      size: 26,
      altitude: 5,
      bob: 3,
      hit: Rect.fromLTRB(5, 4, 22, 22),
      unlock: 550,
    ),
    HazardKind.mouse: HazardSpec(
      frames: ['mouse_walk_a', 'mouse_walk_b'],
      hit: Rect.fromLTRB(4, 12, 27, 30),
      speed: 60,
      unlock: 700,
    ),
    HazardKind.bee: HazardSpec(
      frames: ['bee_a', 'bee_b'],
      size: 28,
      altitude: 40,
      bob: 4,
      hit: Rect.fromLTRB(5, 5, 24, 23),
      unlock: 700,
    ),
  };
}

/// One obstacle on the course. [x] is its square's left edge in world
/// distance; walkers move it toward the runner as they go.
class Hazard {
  Hazard(this.kind, this.x, {this.phase = 0});

  final HazardKind kind;
  double x;

  /// Where in its bob and walk cycle it started, so a row of them does not
  /// move in step.
  final double phase;

  /// The runner has passed it (scored, and no longer checked).
  bool passed = false;

  HazardSpec get spec => HazardSpec.of(kind);

  Hazard copy() => Hazard(kind, x, phase: phase)..passed = passed;
}

/// A coin, its centre in world distance and height above the ground.
class Coin {
  Coin(this.x, this.height);

  final double x;
  final double height;

  /// When it was picked up (world time), for its sparkle; null while it is
  /// still there.
  double? takenAt;

  Coin copy() => Coin(x, height)..takenAt = takenAt;

  static const double radius = 8;
}
