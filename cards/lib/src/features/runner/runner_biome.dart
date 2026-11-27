import 'dart:ui';

import 'runner_physics.dart';

/// The landscapes the run passes through, in turn: a background set and the
/// ground under it.
enum RunnerBiome {
  hills('hills', 'grass', Color(0xFFAFD8FF), Color(0xFFEEF7FF), green: true),
  desert('desert', 'sand', Color(0xFFB9D7F2), Color(0xFFFFF0DC)),
  mushrooms('mushrooms', 'dirt', Color(0xFFC2C7F2), Color(0xFFF7EEFA)),
  trees('trees', 'grass', Color(0xFFA9DCEC), Color(0xFFEAF8F1), green: true);

  const RunnerBiome(
    this.backdrop,
    this.ground,
    this.skyTop,
    this.skyBottom, {
    this.green = false,
  });

  final String backdrop;
  final String ground;

  /// Its sky, top to horizon: a desert's warmer, the mushrooms' dusk.
  final Color skyTop;
  final Color skyBottom;

  /// Green hills behind: a green obstacle would vanish into them.
  final bool green;

  static RunnerBiome at(int index) => values[index % values.length];

  /// The landscape at world distance [x].
  static RunnerBiome atX(double x) =>
      at((x / RunnerPhysics.biomeLength).floor());
}
