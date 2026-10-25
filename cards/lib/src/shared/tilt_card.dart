import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// A card that answers the phone's tilt, the way a real card catches the
/// light in your hand: it leans a few degrees with the phone and a soft
/// highlight slides across its face.
///
/// "Level" is however the customer happens to hold the phone: the resting
/// angle follows the hand over a second or two, so only the movement counts,
/// and lying in bed or standing at a counter both start flat.
///
/// [strength] scales it in and out (0 flat, 1 full): the brand page keeps
/// it flat until the card has landed. Phones only, and never under the
/// system's reduce-motion setting.
class TiltCard extends StatefulWidget {
  const TiltCard({
    super.key,
    required this.child,
    required this.radius,
    this.strength,
  });

  final Widget child;
  final double radius;
  final Animation<double>? strength;

  /// The furthest the card leans, either way: vanilla-tilt's default, the
  /// web's reference for this effect.
  static const double maxAngle = 15 * math.pi / 180;

  /// The card holds still in space while the phone turns around it, one to
  /// one, the way a hologram or a parallax wallpaper does: the movement the
  /// eye expects from a real object. Toward [maxAngle] it eases off rather
  /// than stopping dead.
  static const double _gain = 1;

  /// Tremor below about this is eaten softly (no step where it starts).
  static const double _deadZone = 1 * math.pi / 180;

  /// The card's spring: it follows the hand in about a third of a second
  /// and settles with a whisper of overshoot, so it feels like it has
  /// weight. Response 0.35 s, damping ratio 0.72.
  static const double _stiffness = 322;
  static const double _damping = 25.9;

  /// Where the readings come from: the accelerometer on a phone, nothing
  /// elsewhere. Tests swap in their own.
  @visibleForTesting
  static Stream<(double, double, double)>? Function() source = _phoneSensor;

  static Stream<(double, double, double)>? _phoneSensor() {
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) {
      return null;
    }
    return accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
        .map((e) => (e.x, e.y, e.z));
  }

  @override
  State<TiltCard> createState() => _TiltCardState();
}

class _TiltCardState extends State<TiltCard>
    with SingleTickerProviderStateMixin {
  StreamSubscription<(double, double, double)>? _readings;
  late final Ticker _ticker = createTicker(_step);
  Duration? _lastTick;

  /// The card's lean, as a share of [TiltCard.maxAngle] on each axis.
  final _tilt = ValueNotifier(Offset.zero);
  Offset _velocity = Offset.zero;
  Offset _target = Offset.zero;
  Offset? _level;
  Offset _smooth = Offset.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      _stop();
    } else {
      _readings ??= TiltCard.source()?.listen(
        _onReading,
        onError: (Object _) => _stop(),
        cancelOnError: true,
      );
    }
  }

  @override
  void dispose() {
    _stop();
    _ticker.dispose();
    _tilt.dispose();
    super.dispose();
  }

  void _stop() {
    _readings?.cancel();
    _readings = null;
    _ticker.stop();
    _lastTick = null;
    _velocity = Offset.zero;
    _target = Offset.zero;
    _tilt.value = Offset.zero;
  }

  /// Gravity along the phone's three axes, in m/s², turned into the two
  /// angles a hand moves the phone through: rolled side to side, and pitched
  /// forwards and back. Angles, not raw gravity: held upright, pitching the
  /// phone barely changes gravity along its length (it moves into its
  /// depth), so raw readings only ever felt sideways tilts.
  ///
  /// The level drifts toward the hand's resting angle over a few seconds, so
  /// a held tilt slowly settles flat and any way of holding the phone starts
  /// level.
  void _onReading((double, double, double) reading) {
    final (x, y, z) = reading;
    final raw = Offset(
      math.atan2(x, math.sqrt(y * y + z * z)),
      math.atan2(z, y),
    );
    // The first reading is where the hand is: start flat there, not with
    // a lurch from zero.
    final level = _level;
    if (level == null) {
      _smooth = raw;
      _level = raw;
      return;
    }
    // A light filter for sensor noise only; the spring does the gliding.
    _smooth = Offset.lerp(_smooth, raw, 0.35)!;
    _level = Offset.lerp(level, _smooth, 0.005)!;
    final delta = _smooth - _level!;

    double lean(double turn) {
      // Soft dead zone: flat near level, then the full one-to-one turn.
      final past = turn - TiltCard._deadZone * _tanh(turn / TiltCard._deadZone);
      return _tanh(TiltCard._gain * past / TiltCard.maxAngle);
    }

    // The card stays facing the customer as the phone turns under it: tip
    // an edge away and that edge of the card comes back toward the eye.
    _target = Offset(-lean(delta.dx), lean(delta.dy));
    if (!_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  static double _tanh(double v) {
    final e = math.exp(2 * v.clamp(-20.0, 20.0));
    return (e - 1) / (e + 1);
  }

  /// One frame of the spring toward the hand, in small steps so a dropped
  /// frame never makes it jump.
  void _step(Duration now) {
    final last = _lastTick;
    _lastTick = now;
    if (last == null) {
      return;
    }
    var dt = math.min((now - last).inMicroseconds / 1e6, 1 / 20);
    var position = _tilt.value;
    var velocity = _velocity;
    while (dt > 0) {
      final h = math.min(dt, 1 / 240);
      final pull =
          (_target - position) * TiltCard._stiffness -
          velocity * TiltCard._damping;
      velocity += pull * h;
      position += velocity * h;
      dt -= h;
    }
    _velocity = velocity;
    final settled =
        (position - _target).distance < 1e-4 && velocity.distance < 1e-3;
    _tilt.value = settled ? _target : position;
    if (settled) {
      _velocity = Offset.zero;
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strength = widget.strength ?? kAlwaysCompleteAnimation;
    return AnimatedBuilder(
      animation: Listenable.merge([_tilt, strength]),
      child: widget.child,
      builder: (context, child) {
        // The same tree flat as tilted, so the card underneath (and the
        // Hero in it) is never rebuilt as the phone passes through level.
        final tilt = _tilt.value * strength.value;
        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(-tilt.dx * TiltCard.maxAngle)
          ..rotateX(-tilt.dy * TiltCard.maxAngle);
        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: Stack(
            children: [
              child!,
              // The light: a soft band of white that slides the opposite way
              // to the tilt, the way a reflection moves across a card.
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.radius),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          // It travels further than the card turns, so a
                          // small lean still sweeps the light visibly across.
                          begin: Alignment(
                            -1 + tilt.dx * 1.6,
                            -1 + tilt.dy * 1.6,
                          ),
                          end: Alignment(1 + tilt.dx * 1.6, 1 + tilt.dy * 1.6),
                          stops: const [0.3, 0.5, 0.7],
                          colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(
                              alpha: 0.3 * tilt.distance.clamp(0.0, 1.0),
                            ),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
