import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'runner_biome.dart';
import 'runner_hazards.dart';

/// The runners to choose from (Kenney's aliens), and the best score that
/// unlocks each: something to play for beyond the number.
enum RunnerCharacter {
  green(0, ui.Color(0xFF5DD4AA)),
  beige(300, ui.Color(0xFFE2C3AB)),
  pink(800, ui.Color(0xFFFF8AAE)),
  purple(1500, ui.Color(0xFFC7B6FF)),
  yellow(2500, ui.Color(0xFFFABA2D));

  const RunnerCharacter(this.unlock, this.skin);

  final int unlock;

  /// Its arms and legs, as the rig draws them (sampled from Kenney's art).
  final ui.Color skin;

  static RunnerCharacter byName(String? name) =>
      values.where((c) => c.name == name).firstOrNull ?? green;
}

/// Every picture the game draws (`assets/runner/`, from Kenney's CC0 New
/// Platformer Pack), decoded once and kept for as long as the app runs: the
/// waiting page comes and goes, the pictures stay ready.
class RunnerSprites {
  RunnerSprites._(this._images);

  final Map<String, ui.Image> _images;

  ui.Image operator [](String name) => _images[name]!;

  static Future<RunnerSprites>? _loading;

  /// The pictures once loaded: the next waiting page draws them on its first
  /// frame, with no loading frame between.
  static RunnerSprites? loaded;

  /// The pictures, loaded on first use; a failed load is tried again next
  /// time rather than remembered.
  static Future<RunnerSprites> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle).then(
        (sprites) => loaded = sprites,
        onError: (Object error) {
          _loading = null;
          throw error;
        },
      );

  static Future<RunnerSprites> _load(AssetBundle bundle) async {
    final names = <String>{
      for (final character in RunnerCharacter.values)
        for (final pose in const ['helmet', 'hit', 'idle'])
          '${character.name}_$pose',
      for (final kind in HazardKind.values) ...HazardSpec.of(kind).frames,
      for (final biome in RunnerBiome.values) ...[
        'color_${biome.backdrop}',
        'fade_${biome.backdrop}',
        'ground_${biome.ground}_top',
        'ground_${biome.ground}_fill',
      ],
      for (var digit = 0; digit < 10; digit++) 'digit_$digit',
      'clouds',
      'coin_gold',
      'coin_gold_side',
      'hud_coin',
      'grass',
      'mushroom_red',
      'mushroom_brown',
    };
    final entries = await Future.wait(
      names.map((name) async {
        final data = await bundle.load('assets/runner/$name.png');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        codec.dispose();
        return MapEntry(name, frame.image);
      }),
    );
    return RunnerSprites._(Map.fromEntries(entries));
  }
}
