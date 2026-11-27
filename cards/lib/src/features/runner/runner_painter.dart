import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'runner_biome.dart';
import 'runner_intro.dart';
import 'runner_physics.dart';
import 'runner_rig.dart';
import 'runner_sprites.dart';
import 'runner_world.dart';

/// Draws the world: sky, three layers of hills sliding at their own pace,
/// the ground, coins, obstacles, the runner and its dust, and the score in
/// Kenney's own digits. In a right-to-left app the world is mirrored, so the
/// runner heads the way an Arabic reader's eye travels.
class RunnerPainter extends CustomPainter {
  RunnerPainter({
    required this.world,
    required this.sprites,
    required this.character,
    required this.mirrored,
    required this.calm,
    this.introClock,
    required super.repaint,
  });

  final RunnerWorld world;
  final RunnerSprites sprites;
  final RunnerCharacter character;
  final bool mirrored;

  /// The system's reduce motion: no shake, no flash.
  final bool calm;

  /// Seconds into the entrance, read on every frame (the painter is not
  /// rebuilt while it plays, only repainted); null once it has played, or
  /// when there is none.
  final ValueListenable<double?>? introClock;

  RunnerIntro? get _entering {
    final t = introClock?.value;
    if (t == null) {
      return null;
    }
    final intro = RunnerIntro(t);
    return intro.done ? null : intro;
  }

  static final Paint _sprite = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / RunnerPhysics.width;
    final entering = _entering;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (entering != null) {
      // A pale window waits; the porthole opens in its middle.
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFFE4F1FF),
      );
      final portal = entering.portal;
      if (portal <= 0) {
        canvas.restore();
        return;
      }
      canvas.clipPath(Path()..addOval(_porthole(size, portal)));
    }
    canvas.scale(scale);
    if (mirrored) {
      canvas.translate(RunnerPhysics.width, 0);
      canvas.scale(-1, 1);
    }
    final shake = _shake();
    canvas.translate(shake.dx, shake.dy);

    _sky(canvas);
    _backdrops(canvas);
    // Everything on the ground rises with it as the game enters.
    canvas.save();
    canvas.translate(0, entering?.ground ?? 0);
    _ground(canvas);
    _coins(canvas);
    _hazards(canvas);
    _shadow(canvas);
    _runner(canvas);
    // Dust in front of the feet, so a landing's puff is seen.
    _particles(canvas);
    canvas.restore();
    canvas.restore();

    if (entering != null && entering.portal < 1) {
      // The porthole's rim, a bright edge that fades as it opens out.
      canvas.drawOval(
        _porthole(size, entering.portal),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Color.fromRGBO(255, 255, 255, 0.9 * (1 - entering.portal)),
      );
    }

    // Screen space, never mirrored: the score and the crash's flash.
    final chrome = entering?.chrome ?? 1;
    if (chrome > 0) {
      canvas.save();
      canvas.scale(scale);
      if (chrome < 1) {
        canvas.saveLayer(
          null,
          Paint()..color = Color.fromRGBO(0, 0, 0, chrome.clamp(0.0, 1.0)),
        );
      }
      _score(canvas);
      if (chrome < 1) {
        canvas.restore();
      }
      _flash(canvas);
      canvas.restore();
    }
  }

  /// The opening porthole: a circle from the middle that grows past the
  /// corners by the time [open] reaches 1.
  static Rect _porthole(Size size, double open) {
    final reach = size.longestSide * 0.6 * open;
    return Rect.fromCircle(center: size.center(Offset.zero), radius: reach);
  }

  /// The runner's feet above the ground: its drop while entering.
  double get _height => _entering?.drop ?? world.height;

  // The world's x on screen, in world units.
  double _x(double worldX) => worldX - world.distance;

  // A height above the ground, as y on screen.
  static double _y(double height) => RunnerPhysics.ground - height;

  Offset _shake() {
    if (calm || world.phase != RunnerPhase.crashing) {
      return Offset.zero;
    }
    final fade = math.max(0.0, 1 - world.crashedAgo / 0.35);
    return Offset(
      math.sin(world.crashedAgo * 95) * 3.2 * fade,
      math.cos(world.crashedAgo * 71) * 2.2 * fade,
    );
  }

  /// The sky, easing into the next landscape's colours as its ground
  /// passes under the runner.
  void _sky(Canvas canvas) {
    final here = RunnerWorld.biomeAt(world.distance);
    final border = (here + 1) * RunnerPhysics.biomeLength;
    final t = Curves.easeInOut.transform(
      ((world.distance + RunnerPhysics.width - border) /
              (RunnerPhysics.width * 2.5))
          .clamp(0.0, 1.0),
    );
    final from = RunnerBiome.at(here);
    final to = RunnerBiome.at(here + 1);
    canvas.drawRect(
      Rect.fromLTWH(-8, -8, RunnerPhysics.width + 16, 220),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(0, RunnerPhysics.ground),
          [
            Color.lerp(from.skyTop, to.skyTop, t)!,
            Color.lerp(from.skyBottom, to.skyBottom, t)!,
          ],
        ),
    );
  }

  /// The hills, far and near. Each layer has its own border between two
  /// landscapes, sliding in at the layer's own pace: the next landscape
  /// arrives the way it would out of a train window, the near hills first,
  /// the far ones long after, each edge soft.
  void _backdrops(Canvas canvas) {
    // Clouds drift a little on their own, even while the runner idles.
    final entering = _entering;
    _tile(
      canvas,
      sprites['clouds'],
      size: 200,
      top: -96 + (entering?.far ?? 0) * 0.4,
      offset: world.distance * 0.05 + world.time * 3,
    );
    canvas.save();
    canvas.translate(0, entering?.far ?? 0);
    _band(
      canvas,
      factor: 0.14,
      feather: 110,
      draw: (biome) => _tile(
        canvas,
        sprites['fade_${biome.backdrop}'],
        size: 210,
        top: -36,
        offset: world.distance * 0.14,
      ),
    );
    canvas.restore();
    canvas.save();
    canvas.translate(0, entering?.near ?? 0);
    _band(
      canvas,
      factor: 0.32,
      feather: 80,
      draw: (biome) => _tile(
        canvas,
        sprites['color_${biome.backdrop}'],
        size: 190,
        top: 2,
        offset: world.distance * 0.32,
      ),
    );
    canvas.restore();
  }

  /// Draws one layer moving at [factor] of the runner's pace: the landscape
  /// it is in, and past its border the next one, blended across [feather]
  /// units either side so no seam shows.
  ///
  /// A layer's border is placed so that it comes into view together with
  /// the ground's, and then travels at the layer's own speed.
  void _band(
    Canvas canvas, {
    required double factor,
    required double feather,
    required void Function(RunnerBiome biome) draw,
  }) {
    const width = RunnerPhysics.width;
    const length = RunnerPhysics.biomeLength;
    final camera = world.distance * factor;
    // The landscape at the layer's near edge, and its border with the next.
    // (Before the first border everything is the first landscape.)
    final here = math.max(
      0,
      (((camera - width) / factor + width) / length).floor(),
    );
    final seam = width + ((here + 1) * length - width) * factor - camera;
    final from = RunnerBiome.at(here);
    if (seam - feather >= width) {
      draw(from);
      return;
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(-8, -8, seam + feather, 230));
    draw(from);
    canvas.restore();

    final blend = Rect.fromLTRB(
      math.max(-8, seam - feather),
      -8,
      width + 8,
      230,
    );
    canvas.saveLayer(blend, Paint());
    draw(RunnerBiome.at(here + 1));
    canvas.drawRect(
      blend,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          Offset(seam - feather, 0),
          Offset(seam + feather, 0),
          const [Color(0x00000000), Color(0xFF000000)],
          const [0, 1],
        ),
    );
    canvas.restore();
  }

  /// [image] repeated across the screen, [size] units square, sliding by
  /// [offset].
  void _tile(
    Canvas canvas,
    ui.Image image, {
    required double size,
    required double top,
    required double offset,
  }) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    // A hair of overlap hides the seam between neighbours.
    final start = -(offset % size);
    for (var x = start; x < RunnerPhysics.width; x += size - 0.5) {
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(x, top, size, size),
        _sprite,
      );
    }
  }

  static const double _tileSize = 24;

  /// The ground blends from one earth into the next over a couple of
  /// tiles, right where the landscape changes.
  void _ground(Canvas canvas) {
    _band(
      canvas,
      factor: 1,
      feather: 34,
      draw: (biome) {
        final first = (world.distance / _tileSize).floor();
        final last = ((world.distance + RunnerPhysics.width) / _tileSize)
            .ceil();
        for (var k = first; k <= last; k++) {
          final x = _x(k * _tileSize);
          _image(
            canvas,
            sprites['ground_${biome.ground}_top'],
            Rect.fromLTWH(
              x - 0.25,
              RunnerPhysics.ground,
              _tileSize + 0.5,
              _tileSize,
            ),
          );
          _image(
            canvas,
            sprites['ground_${biome.ground}_fill'],
            Rect.fromLTWH(
              x - 0.25,
              RunnerPhysics.ground + _tileSize - 0.5,
              _tileSize + 0.5,
              _tileSize,
            ),
          );
        }
      },
    );
    _tufts(canvas);
  }

  /// A tuft here and there along the back of the ground, of the landscape
  /// it grows in: never in the way, never confused with what is. None in
  /// the blend between two earths.
  void _tufts(Canvas canvas) {
    final first = (world.distance / _tileSize).floor();
    final last = ((world.distance + RunnerPhysics.width) / _tileSize).ceil();
    for (var k = first; k <= last; k++) {
      final worldX = k * _tileSize;
      final hash = (k * 2654435761) & 0xffff;
      final edge = worldX % RunnerPhysics.biomeLength;
      if (hash % 7 != 0 || edge < 48 || edge > RunnerPhysics.biomeLength - 48) {
        continue;
      }
      final biome = RunnerBiome.at(RunnerWorld.biomeAt(worldX));
      final name = switch (biome) {
        RunnerBiome.mushrooms =>
          hash.isEven ? 'mushroom_red' : 'mushroom_brown',
        RunnerBiome.desert => null,
        _ => 'grass',
      };
      if (name != null) {
        _image(
          canvas,
          sprites[name],
          Rect.fromLTWH(
            _x(worldX) + (hash % 11),
            RunnerPhysics.ground - 13,
            15,
            15,
          ),
        );
      }
    }
  }

  void _coins(Canvas canvas) {
    for (final coin in world.coins) {
      final x = _x(coin.x);
      if (x < -20 || x > RunnerPhysics.width + 20) {
        continue;
      }
      final takenAt = coin.takenAt;
      var y = _y(coin.height);
      var opacity = 1.0;
      var size = 17.0;
      if (takenAt != null) {
        // Up and away.
        final t = ((world.time - takenAt) / 0.3).clamp(0.0, 1.0);
        if (t >= 1) {
          continue;
        }
        y -= 18 * Curves.easeOut.transform(t);
        opacity = 1 - t;
        size *= 1 + 0.3 * t;
      }
      // Turning in the light.
      final turn = math.cos(world.time * 5 + coin.x * 0.05).abs();
      final width = math.max(0.25, turn) * size;
      final image = turn < 0.3
          ? sprites['coin_gold_side']
          : sprites['coin_gold'];
      _image(
        canvas,
        image,
        Rect.fromCenter(center: Offset(x, y), width: width, height: size),
        opacity: opacity,
      );
    }
  }

  void _hazards(Canvas canvas) {
    for (final hazard in world.hazards) {
      final spec = hazard.spec;
      final x = _x(hazard.x);
      if (x > RunnerPhysics.width + 4 || x + spec.width < -4) {
        continue;
      }
      final fps = spec.bob > 0 ? 14 : 6;
      final frame =
          spec.frames[((world.time + hazard.phase) * fps).floor() %
              spec.frames.length];
      final bottom = _y(spec.altitude + world.hazardBob(hazard));
      for (var i = 0; i < spec.copies; i++) {
        final rect = Rect.fromLTWH(
          x + i * spec.size,
          bottom - spec.size,
          spec.size,
          spec.size,
        );
        if (spec.spin) {
          canvas.save();
          canvas.translate(rect.center.dx, rect.center.dy);
          canvas.rotate(-world.time * 9);
          _image(canvas, sprites[frame], rect.shift(-rect.center));
          canvas.restore();
        } else {
          _image(canvas, sprites[frame], rect);
        }
      }
    }
  }

  /// A soft shadow under the runner that shrinks as it leaves the ground.
  void _shadow(Canvas canvas) {
    final lift = (_height / 70).clamp(0.0, 1.0);
    final centre = Offset(
      RunnerPhysics.runnerX + RunnerPhysics.runnerSize / 2,
      RunnerPhysics.ground + 1,
    );
    canvas.drawOval(
      Rect.fromCenter(center: centre, width: 22 * (1 - 0.5 * lift), height: 4),
      Paint()..color = Color.fromRGBO(30, 40, 60, 0.18 * (1 - 0.6 * lift)),
    );
  }

  void _particles(Canvas canvas) {
    for (final p in world.particles) {
      final t = p.t;
      final centre = Offset(_x(p.x), _y(p.y));
      switch (p.kind) {
        case ParticleKind.dust:
          canvas.drawCircle(
            centre,
            p.size * (0.6 + t),
            Paint()..color = Color.fromRGBO(250, 244, 232, 0.9 * (1 - t * t)),
          );
        case ParticleKind.spark:
          canvas.drawCircle(
            centre,
            p.size * (1 - t),
            Paint()..color = Color.fromRGBO(255, 214, 64, 1 - t),
          );
      }
    }
  }

  void _runner(Canvas canvas) {
    // Kenney's own pictures for standing and for the crash; while running
    // and jumping the rig moves the limbs (runner_rig.dart).
    final dropping = _entering?.drop != null;
    final pose = switch (world.phase) {
      // Dropping in: the rig, falling, legs reaching for the ground.
      RunnerPhase.ready when dropping => null,
      RunnerPhase.ready => 'idle',
      RunnerPhase.crashing || RunnerPhase.over => 'hit',
      RunnerPhase.running => null,
    };
    // Squash on landing, stretch on takeoff: the feel of weight.
    var sx = 1.0;
    var sy = 1.0;
    if (world.phase == RunnerPhase.running) {
      if (world.landedAgo < 0.14) {
        final k = math.sin(world.landedAgo / 0.14 * math.pi);
        sx += 0.14 * k;
        sy -= 0.14 * k;
      } else if (world.jumpedAgo < 0.16) {
        final k = math.sin(world.jumpedAgo / 0.16 * math.pi);
        sx -= 0.08 * k;
        sy += 0.1 * k;
      }
    }
    // The landing at the end of the entrance.
    final landed = _entering?.sinceLanding;
    if (landed != null && landed >= 0 && landed < 0.2) {
      final k = math.sin(landed / 0.2 * math.pi);
      sx += 0.2 * k;
      sy -= 0.2 * k;
    }
    final idleBob = world.phase == RunnerPhase.ready && !dropping
        ? math.sin(world.time * 3) * 1.2
        : 0.0;
    const size = RunnerPhysics.runnerSize;
    final feet = Offset(
      RunnerPhysics.runnerX + size / 2,
      _y(_height) + idleBob,
    );
    canvas.save();
    canvas.translate(feet.dx, feet.dy);
    if (world.phase == RunnerPhase.crashing ||
        world.phase == RunnerPhase.over) {
      canvas.rotate(-0.12);
    }
    canvas.scale(sx, sy);
    if (pose == null) {
      RunnerRig.paint(
        canvas,
        helmet: sprites['${character.name}_helmet'],
        skin: character.skin,
        size: size,
        cycle: world.strides,
        airborne: dropping
            ? -0.7
            : world.grounded
            ? null
            : world.velocity / RunnerPhysics.jumpVelocity,
      );
    } else {
      _image(
        canvas,
        sprites['${character.name}_$pose'],
        // The sprite's frame has a little air under the feet.
        Rect.fromLTWH(-size / 2, -size + 0.6, size, size),
      );
    }
    canvas.restore();
  }

  void _score(Canvas canvas) {
    final digits = world.score.toString().padLeft(5, '0');
    // The score swells for a moment as it passes a milestone.
    final pulse = calm ? 0.0 : math.max(0.0, 1 - world.milestoneAgo / 0.45);
    final size = 15.0 * (1 + 0.22 * Curves.easeOut.transform(pulse));
    const gap = 0.62;
    final width = digits.length * size * gap;
    // On the side the obstacles come from, out of the runner's way.
    final right = mirrored ? 10 + width : RunnerPhysics.width - 10;
    for (var i = 0; i < digits.length; i++) {
      _image(
        canvas,
        sprites['digit_${digits[i]}'],
        Rect.fromLTWH(
          right - width + i * size * gap - size * 0.19,
          8 - (size - 15) / 2,
          size,
          size,
        ),
      );
    }
    if (world.coinsTaken > 0) {
      final count = world.coinsTaken.toString();
      const small = 12.0;
      final left = mirrored
          ? RunnerPhysics.width - 10 - small - count.length * small * gap
          : 10.0;
      _image(
        canvas,
        sprites['hud_coin'],
        Rect.fromLTWH(left, 9.5, small, small),
      );
      for (var i = 0; i < count.length; i++) {
        _image(
          canvas,
          sprites['digit_${count[i]}'],
          Rect.fromLTWH(
            left + small + i * small * gap - small * 0.12,
            9.5,
            small,
            small,
          ),
        );
      }
    }
  }

  void _flash(Canvas canvas) {
    if (calm ||
        world.phase != RunnerPhase.crashing ||
        world.crashedAgo > 0.18) {
      return;
    }
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, RunnerPhysics.width, RunnerPhysics.height),
      Paint()
        ..color = Color.fromRGBO(
          255,
          255,
          255,
          0.5 * (1 - world.crashedAgo / 0.18),
        ),
    );
  }

  static void _image(
    Canvas canvas,
    ui.Image image,
    Rect dst, {
    double opacity = 1,
  }) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      opacity >= 1
          ? _sprite
          : (Paint()
              ..filterQuality = FilterQuality.medium
              ..color = Color.fromRGBO(0, 0, 0, opacity)),
    );
  }

  @override
  bool shouldRepaint(RunnerPainter old) =>
      old.world != world ||
      old.sprites != sprites ||
      old.character != character ||
      old.mirrored != mirrored ||
      old.calm != calm ||
      old.introClock != introClock;
}
