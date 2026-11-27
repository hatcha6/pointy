import 'package:flutter/animation.dart';

/// The game's entrance, the moment the wait turns long enough to offer it:
/// a porthole opens on the sky, the far hills, the near hills and the ground
/// rise into place one after another, and the runner drops in, lands with a
/// puff of dust, and the score and the «اضغط للقفز» hint pop up last.
///
/// [t] is seconds since the entrance began (negative while it waits for
/// the page around it to settle). Each part reads its own stretch of the
/// timeline, so they overlap like a staged animation, not one fade.
class RunnerIntro {
  const RunnerIntro(this.t);

  final double t;

  /// The whole entrance, from the first frame to the hint.
  static const double duration = 1.75;

  /// Waits this long first: the page's own fade to the waiting room ends.
  static const double delay = 0.25;

  /// When the runner's feet touch the ground.
  static const double landing = 1.28;

  bool get done => t >= duration;

  double _span(double from, double to, [Curve curve = Curves.linear]) =>
      curve.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

  /// The porthole, 0 shut to 1 open past the corners.
  double get portal => _span(0, 0.5, Curves.easeOutCubic);

  /// How far below its place each layer still is, in world units.
  double get far => (1 - _span(0.18, 0.7, Curves.easeOutCubic)) * 70;
  double get near => (1 - _span(0.3, 0.82, Curves.easeOutCubic)) * 90;
  double get ground => (1 - _span(0.42, 0.95, Curves.easeOutBack)) * 60;

  /// The runner's height above the ground while it drops in, or null once
  /// it has landed.
  double? get drop {
    if (t >= landing) {
      return null;
    }
    // Falling, as gravity would have it: slow at first, fast at the end.
    final fall = _span(0.85, landing, Curves.easeInQuad);
    // From well above the top edge, so it arrives rather than appears.
    return 230 * (1 - fall);
  }

  /// Seconds since the landing, for the squash.
  double get sinceLanding => t - landing;

  /// The score and the hint, 0 hidden to 1 shown.
  double get chrome => _span(1.3, duration, Curves.easeOutBack);
}
