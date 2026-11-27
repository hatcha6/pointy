import 'dart:math' as math;

/// The runner's numbers, in world units. The world is always [width] wide,
/// whatever the screen, so every phone sees the same distance ahead and the
/// game is exactly as hard on all of them.
abstract final class RunnerPhysics {
  /// What is visible, edge to edge.
  static const double width = 340;

  /// Sky to the bottom of the ground.
  static const double height = 190;

  /// The top of the ground, where feet land.
  static const double ground = 150;

  /// The runner's back edge, measured from the camera.
  static const double runnerX = 30;

  /// Distance per step at the starting speed. The stride lengthens as the
  /// pace rises, as a real runner's does, so the legs never blur.
  static const double stride = 22;

  /// The length of one step at [speed].
  static double strideAt(double speed) =>
      stride * math.pow(speed / startSpeed, 0.55).toDouble();

  /// The runner as drawn (its sprite's frame, which has air around it).
  static const double runnerSize = 46;

  /// The runner's hit box inside its frame: forgiving on purpose, a touch
  /// narrower and shorter than what is drawn, so a crash always looks fair.
  static const double hitLeft = 14;
  static const double hitRight = 32;
  static const double hitTop = 15;

  /// The fixed step the world moves by (120 Hz), so a jump is the same on a
  /// 60 Hz phone, a 120 Hz phone and after a slow frame.
  static const double step = 1 / 120;

  /// Speed at the start and the most it ever reaches, in units a second.
  static const double startSpeed = 155;
  static const double topSpeed = 300;

  /// How far (in units) it takes to get about two thirds of the way to
  /// [topSpeed].
  static const double rampDistance = 16000;

  /// Takeoff speed, upward.
  static const double jumpVelocity = 410;

  /// Gravity while the finger is still down and the runner rises: holding
  /// longer jumps higher, up to [maxHold].
  static const double holdGravity = 1000;
  static const double gravity = 1900;
  static const double maxHold = 0.22;

  /// Falling no faster than this keeps a long drop readable.
  static const double maxFall = 640;

  /// A tap this long before landing still jumps the moment the feet touch
  /// down, so a slightly early tap is never lost.
  static const double jumpBuffer = 0.13;

  /// Units of distance per point of score.
  static const double unitsPerPoint = 10;

  /// Points a coin adds.
  static const int coinPoints = 10;

  /// A chime every this many points.
  static const int milestone = 250;

  /// A new landscape every this many units.
  static const double biomeLength = 7000;

  /// The speed at [distance] units: a smooth ramp that never jumps.
  static double speedAt(double distance) {
    final t = 1 - math.exp(-distance / rampDistance);
    return startSpeed + (topSpeed - startSpeed) * t;
  }

  /// 0 at the start, 1 at top speed: how hard the course is.
  static double difficultyAt(double distance) =>
      (speedAt(distance) - startSpeed) / (topSpeed - startSpeed);
}

/// One jump's path, worked out by stepping the same physics the game runs.
/// The course is built from it, so it only ever asks for jumps that exist.
class JumpProfile {
  JumpProfile._(this.heights);

  /// Height of the feet above the ground after each [RunnerPhysics.step].
  final List<double> heights;

  double get airtime => heights.length * RunnerPhysics.step;
  double get apex => heights.reduce(math.max);

  /// How long the feet stay above [height], in seconds.
  double timeAbove(double height) =>
      heights.where((h) => h > height).length * RunnerPhysics.step;

  static final Map<double, JumpProfile> _cache = {};

  /// The path of a jump with the finger held for [hold] seconds.
  factory JumpProfile.of(double hold) => _cache.putIfAbsent(hold, () {
    final heights = <double>[];
    var y = 0.0;
    var v = RunnerPhysics.jumpVelocity;
    var t = 0.0;
    do {
      final holding = t < hold && t < RunnerPhysics.maxHold && v > 0;
      v -=
          (holding ? RunnerPhysics.holdGravity : RunnerPhysics.gravity) *
          RunnerPhysics.step;
      v = math.max(v, -RunnerPhysics.maxFall);
      y = math.max(0, y + v * RunnerPhysics.step);
      t += RunnerPhysics.step;
      heights.add(y);
    } while (y > 0);
    return JumpProfile._(heights);
  });

  /// A quick tap.
  static JumpProfile get short => JumpProfile.of(0);

  /// The finger held the whole way up.
  static JumpProfile get full => JumpProfile.of(RunnerPhysics.maxHold);
}
