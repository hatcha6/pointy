import 'dart:math' as math;
import 'dart:ui';

import 'runner_course.dart';
import 'runner_hazards.dart';
import 'runner_physics.dart';

enum RunnerPhase {
  /// Waiting for the first tap, the runner idling.
  ready,
  running,

  /// Just hit something: the world slows and shakes for a beat before the
  /// score is shown, so the crash reads.
  crashing,
  over,
}

/// Something the screen plays a sound or a haptic for.
enum RunnerEvent { start, jump, land, step, coin, milestone, hit }

/// A puff of dust or a spark, in world distance and height.
class Particle {
  Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.size,
    required this.kind,
  });

  double x;
  double y;
  double vx;
  double vy;
  final double life;
  final double size;
  final ParticleKind kind;
  double age = 0;

  double get t => (age / life).clamp(0, 1);
}

enum ParticleKind { dust, spark }

/// The whole game, with no Flutter in it: one tap control ([press] and
/// [release]), a fixed step, and a seeded course, so a run can be replayed
/// and tested exactly.
class RunnerWorld {
  RunnerWorld({int? seed})
    : _random = math.Random(seed),
      _seed = seed ?? math.Random().nextInt(1 << 31) {
    course = RunnerCourse(CourseRandom(_seed));
  }

  /// Dust and sparks only; the course has its own [CourseRandom], so a
  /// copy of the world lays down exactly the same course.
  final math.Random _random;
  final int _seed;
  late RunnerCourse course;

  /// Runs restarted so far, so each one gets a different course.
  int _runs = 0;

  RunnerPhase phase = RunnerPhase.ready;

  /// World time in seconds, slowed while crashing.
  double time = 0;

  /// How far the camera has moved: the screen's near edge, in world units.
  double distance = 0;

  /// Where the camera stood when the run began: the idle drift before the
  /// first tap scores nothing.
  double _origin = 0;

  /// How far this run has gone.
  double get travelled => phase == RunnerPhase.ready ? 0 : distance - _origin;
  double speed = RunnerPhysics.startSpeed;

  /// The runner's feet above the ground, and its upward speed.
  double height = 0;
  double velocity = 0;
  bool get grounded => height <= 0 && velocity <= 0;

  bool _holding = false;
  double _held = 0;
  double _buffer = 0;

  /// Time since the feet last touched down, for the landing squash.
  double landedAgo = 10;

  /// Time since takeoff, for the stretch.
  double jumpedAgo = 10;

  /// The run cycle, in steps: it moves on only while a foot is on the
  /// ground. The rig draws the legs from it, and a foot plants (and its
  /// footstep sounds) as it passes each whole number, so what is heard is
  /// what is seen.
  double strides = 0;
  int get footfall => strides.floor();
  int _lastFootfall = 0;

  /// Seconds since the crash, for the shake and the slow motion.
  double crashedAgo = 0;

  int coinsTaken = 0;
  int _lastMilestone = 0;

  /// Seconds since the score last passed a milestone.
  double milestoneAgo = 10;

  final List<Hazard> hazards = [];
  final List<Coin> coins = [];
  final List<Particle> particles = [];

  /// What happened since the screen last looked ([drainEvents]).
  final List<RunnerEvent> _events = [];

  double _carry = 0;

  int get distancePoints => (travelled / RunnerPhysics.unitsPerPoint).floor();
  int get score => distancePoints + coinsTaken * RunnerPhysics.coinPoints;

  /// Which landscape the world is in at [x], counting up forever.
  static int biomeAt(double x) => (x / RunnerPhysics.biomeLength).floor();

  List<RunnerEvent> drainEvents() {
    final events = List.of(_events);
    _events.clear();
    return events;
  }

  /// The finger touches the screen.
  void press() {
    _holding = true;
    switch (phase) {
      case RunnerPhase.ready:
        phase = RunnerPhase.running;
        _origin = distance;
        course.nextAt = time + 1.1;
        _events.add(RunnerEvent.start);
        _jump();
      case RunnerPhase.running:
        if (grounded) {
          _jump();
        } else {
          _buffer = RunnerPhysics.jumpBuffer;
        }
      case RunnerPhase.crashing || RunnerPhase.over:
        break;
    }
  }

  /// The runner's entrance ends with its feet on the ground: dust, and a
  /// footstep to hear it by.
  void landFromAbove() {
    _events.add(RunnerEvent.land);
    // Not the running dust, thrown behind at speed: standing still, the
    // puff spreads out both ways from the feet and settles with the squash.
    final feet =
        distance + RunnerPhysics.runnerX + RunnerPhysics.runnerSize / 2;
    for (var i = 0; i < 8; i++) {
      final side = i.isEven ? 1.0 : -1.0;
      particles.add(
        Particle(
          x: feet + side * (9 + _random.nextDouble() * 5),
          y: 1 + _random.nextDouble() * 2,
          vx: side * (30 + _random.nextDouble() * 30),
          vy: 8 + _random.nextDouble() * 14,
          life: 0.42 + _random.nextDouble() * 0.18,
          size: 3 + _random.nextDouble() * 3,
          kind: ParticleKind.dust,
        ),
      );
    }
  }

  /// The finger leaves the screen: the jump stops rising harder.
  void release() => _holding = false;

  /// A fresh run on a fresh course, keeping nothing.
  void restart() {
    phase = RunnerPhase.ready;
    time = 0;
    distance = 0;
    _origin = 0;
    speed = RunnerPhysics.startSpeed;
    height = 0;
    velocity = 0;
    _holding = false;
    _held = 0;
    _buffer = 0;
    landedAgo = 10;
    jumpedAgo = 10;
    crashedAgo = 0;
    coinsTaken = 0;
    _lastMilestone = 0;
    _lastFootfall = 0;
    strides = 0;
    milestoneAgo = 10;
    hazards.clear();
    coins.clear();
    particles.clear();
    _events.clear();
    _carry = 0;
    _runs++;
    course = RunnerCourse(CourseRandom(_seed + _runs * 7919));
  }

  /// Moves the world on by [elapsed] real seconds, in fixed steps.
  void advance(double elapsed) {
    // A long pause (the app in the background) is not a long step.
    _carry += math.min(elapsed, 0.1);
    while (_carry >= RunnerPhysics.step) {
      _carry -= RunnerPhysics.step;
      tick();
    }
  }

  /// One fixed step.
  void tick() {
    const dt = RunnerPhysics.step;
    switch (phase) {
      case RunnerPhase.ready:
        // The landscape drifts by behind the idling runner.
        time += dt;
        distance += 18 * dt;
        _ageParticles(dt);
      case RunnerPhase.running:
        _run(dt);
      case RunnerPhase.crashing:
        crashedAgo += dt;
        // Slow motion that eases back as the score comes up.
        final slow = 0.15 + 0.85 * math.min(1, crashedAgo / 0.9);
        time += dt * slow;
        _fall(dt * slow);
        _ageParticles(dt * slow);
        if (crashedAgo >= 0.75) {
          phase = RunnerPhase.over;
        }
      case RunnerPhase.over:
        time += dt;
        _fall(dt);
        _ageParticles(dt);
    }
  }

  void _run(double dt) {
    time += dt;
    speed = RunnerPhysics.speedAt(travelled);
    distance += speed * dt;
    landedAgo += dt;
    jumpedAgo += dt;
    milestoneAgo += dt;
    _buffer = math.max(0, _buffer - dt);

    // The body.
    if (!grounded) {
      final rising = velocity > 0;
      final holding = _holding && rising && _held < RunnerPhysics.maxHold;
      if (holding) {
        _held += dt;
      }
      velocity -=
          (holding ? RunnerPhysics.holdGravity : RunnerPhysics.gravity) * dt;
      velocity = math.max(velocity, -RunnerPhysics.maxFall);
      height += velocity * dt;
      if (height <= 0) {
        height = 0;
        velocity = 0;
        landedAgo = 0;
        _events.add(RunnerEvent.land);
        _dust(4);
        if (_buffer > 0) {
          _buffer = 0;
          _jump();
        }
      }
    }

    // A foot comes down: the same tick the rig plants it.
    if (grounded) {
      strides += speed * dt / RunnerPhysics.strideAt(speed);
    }
    final foot = footfall;
    if (foot != _lastFootfall) {
      _lastFootfall = foot;
      if (grounded && landedAgo > 0.08) {
        _events.add(RunnerEvent.step);
      }
    }

    // The course.
    while (time >= course.nextAt) {
      final step = course.spawn(
        time: time,
        camera: distance,
        travelled: travelled,
        speed: speed,
        points: distancePoints,
      );
      hazards.add(step.hazard);
      coins.addAll(step.coins);
    }
    for (final hazard in hazards) {
      hazard.x -= hazard.spec.speed * dt;
    }
    hazards.removeWhere((h) => h.x + h.spec.width < distance - 40);
    coins.removeWhere(
      (c) =>
          c.x < distance - 40 && (c.takenAt == null || time - c.takenAt! > 1),
    );

    // What the runner touches.
    final body = runnerBox;
    for (final coin in coins) {
      if (coin.takenAt == null && _touches(body, coin)) {
        coin.takenAt = time;
        coinsTaken++;
        _events.add(RunnerEvent.coin);
        _sparks(coin);
      }
    }
    for (final hazard in hazards) {
      if (hazardBox(hazard).overlaps(body)) {
        _crash();
        return;
      }
    }

    final milestone = distancePoints ~/ RunnerPhysics.milestone;
    if (milestone > _lastMilestone) {
      _lastMilestone = milestone;
      milestoneAgo = 0;
      _events.add(RunnerEvent.milestone);
    }
    _ageParticles(dt);
  }

  void _jump() {
    velocity = RunnerPhysics.jumpVelocity;
    height = 0.01;
    _held = 0;
    jumpedAgo = 0;
    _events.add(RunnerEvent.jump);
    _dust(3);
  }

  void _crash() {
    phase = RunnerPhase.crashing;
    crashedAgo = 0;
    _holding = false;
    // A small hop as it is knocked back.
    velocity = math.max(velocity, 160);
    height = math.max(height, 0.01);
    _events.add(RunnerEvent.hit);
  }

  /// After a crash the runner drops back to the ground.
  void _fall(double dt) {
    if (height <= 0) {
      return;
    }
    velocity -= RunnerPhysics.gravity * dt;
    height = math.max(0, height + velocity * dt);
    if (height == 0) {
      velocity = 0;
    }
  }

  /// The runner's hit box: x in world distance, y downward from the ground
  /// (so the head is at minus its height), as [Rect.overlaps] expects.
  Rect get runnerBox {
    final left = distance + RunnerPhysics.runnerX + RunnerPhysics.hitLeft;
    return Rect.fromLTRB(
      left,
      -(height + RunnerPhysics.runnerSize - RunnerPhysics.hitTop),
      left + RunnerPhysics.hitRight - RunnerPhysics.hitLeft,
      -height,
    );
  }

  /// A hazard's hit box, in the same terms as [runnerBox].
  Rect hazardBox(Hazard hazard) {
    final spec = hazard.spec;
    final hit = spec.hitBox;
    final base = spec.altitude + hazardBob(hazard);
    return Rect.fromLTRB(
      hazard.x + hit.left,
      -(base + spec.size - hit.top),
      hazard.x + hit.right,
      -(base + spec.size - hit.bottom),
    );
  }

  /// A flier's drift, at this moment.
  double hazardBob(Hazard hazard) {
    final bob = hazard.spec.bob;
    return bob == 0 ? 0 : bob * math.sin((time + hazard.phase * 3) * 4.2);
  }

  static bool _touches(Rect body, Coin coin) {
    final x = coin.x.clamp(body.left, body.right);
    final y = (-coin.height).clamp(body.top, body.bottom);
    final dx = coin.x - x;
    final dy = -coin.height - y;
    return dx * dx + dy * dy <= Coin.radius * Coin.radius;
  }

  void _dust(int count) {
    final feet =
        distance + RunnerPhysics.runnerX + RunnerPhysics.runnerSize / 2;
    for (var i = 0; i < count; i++) {
      particles.add(
        Particle(
          x: feet + (_random.nextDouble() - 0.5) * 14,
          y: 1,
          vx: -speed * 0.25 - _random.nextDouble() * 30,
          vy: 10 + _random.nextDouble() * 22,
          life: 0.35 + _random.nextDouble() * 0.2,
          size: 3 + _random.nextDouble() * 3,
          kind: ParticleKind.dust,
        ),
      );
    }
  }

  void _sparks(Coin coin) {
    for (var i = 0; i < 6; i++) {
      final angle = i / 6 * math.pi * 2 + _random.nextDouble() * 0.5;
      particles.add(
        Particle(
          x: coin.x,
          y: coin.height,
          vx: math.cos(angle) * 70,
          vy: math.sin(angle) * 70,
          life: 0.35,
          size: 2.5,
          kind: ParticleKind.spark,
        ),
      );
    }
  }

  void _ageParticles(double dt) {
    for (final p in particles) {
      p.age += dt;
      p.x += p.vx * dt;
      p.y = math.max(0, p.y + p.vy * dt);
      if (p.kind == ParticleKind.dust) {
        // Air slows a puff: a burst, then a drift as it fades.
        final drag = math.max(0.0, 1 - 5 * dt);
        p.vx *= drag;
        p.vy *= drag;
      }
    }
    particles.removeWhere((p) => p.age >= p.life);
  }

  /// An exact copy, for a test's player to look ahead with.
  RunnerWorld copy() {
    final other = RunnerWorld(seed: _seed)
      ..phase = phase
      ..time = time
      ..distance = distance
      ..speed = speed
      ..height = height
      ..velocity = velocity
      ..landedAgo = landedAgo
      ..jumpedAgo = jumpedAgo
      ..crashedAgo = crashedAgo
      ..coinsTaken = coinsTaken;
    other
      .._runs = _runs
      .._lastFootfall = _lastFootfall
      ..strides = strides
      .._origin = _origin
      .._holding = _holding
      .._held = _held
      .._buffer = _buffer
      .._lastMilestone = _lastMilestone
      .._carry = _carry
      ..course = course.copy();
    other.hazards.addAll(hazards.map((h) => h.copy()));
    other.coins.addAll(coins.map((c) => c.copy()));
    return other;
  }
}
