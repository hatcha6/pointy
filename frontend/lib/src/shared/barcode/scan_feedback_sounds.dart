import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Audible outcome of a barcode action, mirroring [BarcodeScanStatus]-style
/// resolution results wherever a scan is resolved:
/// - [success]: the code resolved to a product and it was added.
/// - [notFound]: the lookup worked but no product carries this code.
/// - [error]: the code could not be looked up at all (unreadable/rejected
///   code or a failed request) — neither an add nor a clean miss.
enum ScanFeedback { success, notFound, error }

/// Signature the view models take so tests can record feedback without audio.
typedef ScanFeedbackPlayer = void Function(ScanFeedback feedback);

/// Plays the short feedback chimes for barcode actions on the POS and
/// purchasing screens.
///
/// Sound is reinforcement, never a gate: every failure here is swallowed so a
/// till without audio (missing codecs, no output device, muted web tab) still
/// scans exactly as before.
class ScanFeedbackSounds {
  ScanFeedbackSounds._();

  static final ScanFeedbackSounds instance = ScanFeedbackSounds._();

  static const Map<ScanFeedback, String> _assets = {
    ScanFeedback.success: 'sounds/success.mp3',
    ScanFeedback.notFound: 'sounds/not-found.mp3',
    ScanFeedback.error: 'sounds/error.mp3',
  };

  // Futures, not players: two scans racing the first play must share one
  // creation instead of leaking a second native player.
  final Map<ScanFeedback, Future<AudioPlayer>> _players = {};

  /// True under `flutter test`, where no audio backend exists — playing would
  /// only spray MissingPluginException noise into unrelated tests.
  static bool get _isUnderTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  /// Fire-and-forget: never awaited by scan flows and never throws.
  void play(ScanFeedback feedback) {
    if (_isUnderTest) {
      return;
    }
    unawaited(_play(feedback));
  }

  Future<void> _play(ScanFeedback feedback) async {
    try {
      final player = await (_players[feedback] ??= _createPlayer(feedback));
      // Rapid rescans retrigger the same chime from the top; distinct
      // outcomes may briefly overlap, keeping each scan audible.
      await player.stop();
      await player.resume();
    } catch (error) {
      // Retry from scratch next scan — the failure may be transient (e.g.
      // audio device not ready yet at first play).
      _players.remove(feedback);
      debugPrint('scan feedback sound failed: $error');
    }
  }

  Future<AudioPlayer> _createPlayer(ScanFeedback feedback) async {
    final player = AudioPlayer();
    // Keep the source loaded across plays; stop() then resume() replays it.
    await player.setReleaseMode(ReleaseMode.stop);
    if (!kIsWeb && Platform.isAndroid) {
      // SoundPool-backed playback: no decode latency between trigger and
      // beep, which is the whole point of a scan chime.
      await player.setPlayerMode(PlayerMode.lowLatency);
    }
    await player.setSource(AssetSource(_assets[feedback]!));
    return player;
  }
}
