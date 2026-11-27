import 'dart:math' as math;

import 'package:flutter_soloud/flutter_soloud.dart';

import 'mixer/mixer_script_stub.dart'
    if (dart.library.js_interop) 'mixer/mixer_script_web.dart';

/// The game's sounds (`assets/runner/*.wav`, Kenney's CC0 packs).
enum RunnerSound {
  start,
  jump,

  /// Feet back on the ground after a jump: a firmer footstep.
  land,

  /// One foot coming down while running.
  step,
  coin,
  milestone,
  hit,
  record,
  arrived,

  /// The game's entrance: the porthole opening.
  reveal;

  /// Its files. A footstep has five recorded takes for each ground.
  List<String> get files => switch (this) {
    step || land => [
      for (final ground in grounds)
        for (var take = 0; take < takes; take++) 'step_${ground}_$take',
    ],
    _ => [name],
  };

  /// The grounds with their own footsteps (RunnerBiome.ground).
  static const grounds = ['grass', 'sand', 'dirt'];
  static const takes = 5;
}

/// Plays the game's sounds. Silent in tests and previews ([NoRunnerAudio]).
abstract class RunnerAudio {
  /// Loads the sounds ahead of the first play, so the first jump is not late.
  Future<void> warm();

  /// Plays [sound]; a footstep sounds like the [ground] it lands on.
  void play(RunnerSound sound, {String ground = 'grass'});
}

class NoRunnerAudio implements RunnerAudio {
  @override
  Future<void> warm() async {}

  @override
  void play(RunnerSound sound, {String ground = 'grass'}) {}
}

/// The sounds through one software mixer (SoLoud), the way a game engine
/// plays them: every sound is decoded in memory and mixed sample by sample,
/// so two at once blend instead of fighting over the speaker, and a limiter
/// on the output keeps a pile-up from ever clipping.
///
/// On top of the mixer each sound has manners: a new jump cuts the last one
/// short (with a fade, never a click), coins picked up in a row rise in
/// pitch and never stack more than three deep, and a crash ducks everything
/// else so it lands clean.
///
/// On iPhone the mixer uses the ambient audio session: it mixes with the
/// customer's own music and follows the silent switch.
class MixedRunnerAudio implements RunnerAudio {
  final Map<String, AudioSource> _sources = {};

  /// The footstep take played last, never played twice in a row.
  int _lastTake = -1;
  final _random = math.Random();
  Future<void>? _warming;

  /// Coins picked up close together, for the rising pitch.
  int _streak = 0;
  DateTime _lastCoin = DateTime(0);

  static const Map<RunnerSound, double> _volume = {
    RunnerSound.jump: 0.8,
    RunnerSound.coin: 0.75,
    RunnerSound.milestone: 0.8,
    // Under everything else: felt more than heard.
    RunnerSound.step: 0.45,
    RunnerSound.land: 0.75,
  };

  static const _cut = Duration(milliseconds: 25);

  @override
  Future<void> warm() => _warming ??= _warm().catchError((Object _) {
    // No sound this time (no audio device, the mixer would not start): the
    // game plays on silently, and the next page tries again.
    _warming = null;
  });

  Future<void> _warm() async {
    await loadMixerScript();
    final soloud = SoLoud.instance;
    if (!soloud.isInitialized) {
      // A small buffer: a jump is heard on the frame it is made.
      await soloud.init(bufferSize: 1024);
    }
    soloud.setMaxActiveVoiceCount(12);
    final limiter = soloud.filters.limiterFilter;
    if (!limiter.isActive) {
      limiter.activate();
    }
    limiter.threshold.value = -6;
    limiter.outputCeiling.value = -1;
    for (final file in {for (final s in RunnerSound.values) ...s.files}) {
      _sources[file] ??= await soloud.loadAsset('assets/runner/$file.wav');
    }
  }

  @override
  void play(RunnerSound sound, {String ground = 'grass'}) {
    final source = _sources[_file(sound, ground)];
    final soloud = SoLoud.instance;
    if (source == null || !soloud.isInitialized) {
      return;
    }
    try {
      var speed = 1.0;
      var volume = _volume[sound] ?? 1;
      switch (sound) {
        case RunnerSound.coin:
          final now = DateTime.now();
          _streak =
              now.difference(_lastCoin) < const Duration(milliseconds: 600)
              ? _streak + 1
              : 0;
          _lastCoin = now;
          // A semitone up for each coin in a row, up to a fifth.
          speed = _semitones(_streak.clamp(0, 7));
          _keepAtMost(source, 2);
        case RunnerSound.step:
          // No two steps quite alike: a different take, a touch higher or
          // lower, a little louder or softer.
          speed = 0.95 + _random.nextDouble() * 0.11;
          volume *= 0.82 + _random.nextDouble() * 0.18;
          _keepAtMost(source, 1);
        case RunnerSound.land:
          // Heavier than a step: a little lower.
          speed = 0.88 + _random.nextDouble() * 0.06;
          _keepAtMost(source, 1);
        case RunnerSound.hit:
          for (final other in _sources.values) {
            _fadeOut(other, const Duration(milliseconds: 80));
          }
        default:
          // One of each at a time: a new jump cuts the last one short.
          _keepAtMost(source, 0);
      }
      final handle = soloud.play(source, volume: volume);
      if (speed != 1) {
        soloud.setRelativePlaySpeed(handle, speed);
      }
    } on Object {
      // A missed sound is never worth a missed frame.
    }
  }

  /// The file [sound] plays: for a footstep, one of the [ground]'s takes,
  /// never the one just played.
  String _file(RunnerSound sound, String ground) {
    if (sound != RunnerSound.step && sound != RunnerSound.land) {
      return sound.name;
    }
    final known = RunnerSound.grounds.contains(ground) ? ground : 'grass';
    var take = _random.nextInt(RunnerSound.takes - 1);
    if (take >= _lastTake && _lastTake >= 0) {
      take++;
    }
    _lastTake = take;
    return 'step_${known}_$take';
  }

  /// Fades out all but the newest [keep] of [source]'s voices.
  void _keepAtMost(AudioSource source, int keep) {
    final handles = source.handles.toList();
    for (final handle in handles.take(math.max(0, handles.length - keep))) {
      _fade(handle, _cut);
    }
  }

  void _fadeOut(AudioSource source, Duration time) {
    for (final handle in source.handles.toList()) {
      _fade(handle, time);
    }
  }

  static void _fade(SoundHandle handle, Duration time) {
    SoLoud.instance
      ..fadeVolume(handle, 0, time)
      ..scheduleStop(handle, time);
  }

  static double _semitones(int n) {
    var speed = 1.0;
    for (var i = 0; i < n; i++) {
      speed *= 1.0594630943592953;
    }
    return speed;
  }
}
