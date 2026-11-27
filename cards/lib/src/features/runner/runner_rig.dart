import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// The runner drawn as a puppet rather than flipped between two pictures:
/// Kenney's helmet (with the face in it) on top, and under it a body, two
/// arms and two legs drawn in the same style (a thick ink outline, flat
/// colour), moved by one continuous run cycle. Any number of in-between
/// poses, so the run is as smooth as the screen.
///
/// Measures are in the 256 px frame of Kenney's character sprites, with the
/// feet at the origin and +x the way the runner faces.
abstract final class RunnerRig {
  static const Color ink = Color(0xFF353541);
  static const double _outline = 9;

  // The helmet disc (assets/runner/<colour>_helmet.png): its centre above the
  // feet, and the size it was cut at.
  static const Offset _helmet = Offset(0, -112.5);
  static const double _helmetBox = 162;

  /// One frame of the run. [cycle] counts steps (a foot plants on each whole
  /// number), [airborne] is null on the ground, else the upward speed from 1
  /// (just jumped) to -1 (falling fast).
  static void paint(
    Canvas canvas, {
    required ui.Image helmet,
    required Color skin,
    required double size,
    required double cycle,
    double? airborne,
  }) {
    final pose = airborne == null
        ? _Pose.running(cycle)
        : _Pose.flying(airborne);
    canvas.save();
    canvas.scale(size / 256);
    // The lowest foot stands on the ground: the body rides up as the legs
    // pass under it and down as they stretch apart, never sinking.
    canvas.translate(0, -pose.groundGap);
    canvas.rotate(pose.lean);
    final shade = Color.lerp(skin, ink, 0.22)!;

    // The far side, in shadow and behind everything.
    _limbs(canvas, shade, [pose.farArm, pose.farLeg]);
    // Body, near leg and near arm as one silhouette: every outline first,
    // then every fill, so the parts join like Kenney's drawings do. The
    // arms hang from under the helmet's rim and swing out past it.
    const body = _Limb(Offset(0, -52), 0, 0, width: 76);
    _limbs(canvas, skin, [body, pose.nearArm, pose.nearLeg]);

    final helmetPaint = Paint()..filterQuality = FilterQuality.medium;
    canvas.save();
    canvas.translate(_helmet.dx, _helmet.dy - pose.headLag);
    canvas.rotate(pose.tilt);
    canvas.drawImageRect(
      helmet,
      Rect.fromLTWH(0, 0, helmet.width.toDouble(), helmet.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: _helmetBox,
        height: _helmetBox,
      ),
      helmetPaint,
    );
    canvas.restore();
    canvas.restore();
  }

  static void _limbs(Canvas canvas, Color fill, List<_Limb> limbs) {
    final outline = Paint()..color = ink;
    final paint = Paint()..color = fill;
    for (final limb in limbs) {
      limb.draw(canvas, outline, grow: _outline);
    }
    for (final limb in limbs) {
      limb.draw(canvas, paint);
    }
    // A soft highlight down the front of each limb, like Kenney's.
    final light = Paint()..color = const Color(0x22FFFFFF);
    for (final limb in limbs) {
      if (limb.length > 0) {
        limb.draw(canvas, light, inset: limb.width * 0.32);
      }
    }
  }
}

/// A rounded limb hanging from [pivot], turned [angle] radians forward from
/// straight down, [length] from pivot to the middle of its round end.
class _Limb {
  const _Limb(this.pivot, this.angle, this.length, {this.width = 30});

  final Offset pivot;
  final double angle;
  final double length;
  final double width;

  void draw(Canvas canvas, Paint paint, {double grow = 0, double inset = 0}) {
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    // Forward is +x: turning a hanging limb forward is anticlockwise.
    canvas.rotate(-angle);
    final w = width + grow * 2 - inset * 2;
    final half = w / 2;
    final rect = length == 0
        ? Rect.fromCenter(center: Offset.zero, width: w, height: w * 0.7)
        : Rect.fromLTRB(-half, -half, half, length + half);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        inset > 0 ? rect.translate(-inset * 0.4, 0) : rect,
        Radius.circular(half),
      ),
      paint,
    );
    canvas.restore();
  }
}

/// Where every part is at one moment.
class _Pose {
  _Pose({
    required this.nearLeg,
    required this.farLeg,
    required this.nearArm,
    required this.farArm,
    required this.lift,
    required this.lean,
    required this.headLag,
    required this.tilt,
  });

  final _Limb nearLeg;
  final _Limb farLeg;
  final _Limb nearArm;
  final _Limb farArm;

  /// Extra height off the ground (in the air).
  final double lift;
  final double lean;

  /// How far the lowest foot hangs below the frame's origin, less [lift].
  double get groundGap {
    double bottom(_Limb leg) =>
        leg.pivot.dy +
        leg.length * math.cos(leg.angle) +
        leg.width / 2 +
        RunnerRig._outline;
    return math.max(bottom(nearLeg), bottom(farLeg)) + lift;
  }

  final double headLag;
  final double tilt;

  static const _hip = Offset(4, -44);
  static const _farHip = Offset(-6, -46);
  static const _shoulder = Offset(10, -64);
  static const _farShoulder = Offset(-8, -66);
  static const _leg = 42.0;
  static const _arm = 46.0;

  /// On the ground. The legs scissor through a full stride every two steps;
  /// the one swinging forward bends (shortens) to clear the ground, the
  /// body is lowest as a foot plants and highest between, and the head
  /// trails the bounce a little.
  factory _Pose.running(double cycle) {
    final phase = cycle * math.pi;
    final swing = math.cos(phase);
    final lift = math.sin(phase);
    const reach = 0.78;
    double length(double recovering) =>
        _leg * (1 - 0.38 * math.max(0, recovering));
    return _Pose(
      nearLeg: _Limb(_hip, reach * swing, length(-lift)),
      farLeg: _Limb(_farHip, -reach * swing, length(lift)),
      nearArm: _Limb(_shoulder, -1.35 * swing, _arm, width: 24),
      farArm: _Limb(_farShoulder, 1.35 * swing, _arm, width: 24),
      lift: 0,
      lean: 0.1,
      headLag: 3 * math.sin(phase * 2 - 0.6),
      tilt: 0.025 * swing,
    );
  }

  /// In the air: knees up on the way up, legs reaching down to land on the
  /// way down, arms thrown up and settling.
  factory _Pose.flying(double rise) {
    final up = rise.clamp(-1.0, 1.0);
    final t = (up + 1) / 2; // 1 rising fast, 0 falling fast
    return _Pose(
      nearLeg: _Limb(_hip, 0.35 + 0.45 * t, _leg * (0.62 + 0.3 * (1 - t))),
      farLeg: _Limb(_farHip, -0.55 + 0.2 * t, _leg * (0.8 + 0.15 * (1 - t))),
      nearArm: _Limb(_shoulder, 1.5 + 1.0 * t, _arm, width: 24),
      farArm: _Limb(_farShoulder, -1.2 - 0.9 * t, _arm, width: 24),
      lift: 0,
      lean: 0.06 - 0.08 * up,
      headLag: -4 * up,
      tilt: -0.04 * up,
    );
  }
}
