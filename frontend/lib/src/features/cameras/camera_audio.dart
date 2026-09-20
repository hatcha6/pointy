/// Listening to a camera.
///
/// Sound arrives as its own HTTP stream, separate from the MJPEG video, and is
/// played by the platform's audio player rather than decoded here. The server
/// sends a bare self-framing byte stream (ADTS AAC, or MP3) with no container
/// index and no length — the same shape as an internet radio station, which is
/// the one live-audio shape every platform's player already knows.
///
/// The two are **not synchronised**. Video is a chain of JPEGs and sound is a
/// separate socket; they drift by whatever the two pipelines differ by. For a
/// shop camera nobody lip-reads that is the right trade, and it is what keeps
/// the till from needing a video codec at all.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../data/services/surveillance_api_client.dart' show CameraHasNoAudio;

/// A seam over the audio plugin, so the player screen can be widget-tested
/// without a sound device — there is none in the test VM, and a real HTTP
/// stream would never complete under `flutter test`'s fake async. Tests inject
/// a fake; nothing here needs to know it is being tested.
abstract class CameraAudioSink {
  /// Begin playing the stream at [source]. Completes once playback has been
  /// asked for, not once sound is audible.
  Future<void> play(Uri source);

  /// Stop, and release the socket — which is what makes the server kill its
  /// ffmpeg and hand the recorder back its session.
  Future<void> stop();

  Future<void> dispose();
}

/// [CameraAudioSink] backed by the `audioplayers` plugin.
///
/// One caveat worth knowing before blaming the DVR: the Windows tills are the
/// least-proven platform for a *live, endless* HTTP stream here. Android
/// (ExoPlayer), iOS/macOS (AVPlayer) and Linux (GStreamer) all treat one as an
/// internet radio station and are fine. If Windows turns out not to, the fix
/// belongs behind this seam and nowhere else.
class AudioPlayersCameraAudioSink implements CameraAudioSink {
  AudioPlayersCameraAudioSink([AudioPlayer? player])
    : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  bool _configured = false;

  @override
  Future<void> play(Uri source) async {
    if (!_configured) {
      // A live stream has no end to loop back to, and releasing the player on
      // completion would throw away the instance mid-listen on any firmware
      // that briefly reports one.
      await _player.setReleaseMode(ReleaseMode.stop);
      _configured = true;
    }
    await _player.stop();
    await _player.play(UrlSource(source.toString()));
  }

  @override
  Future<void> stop() async {
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
  }
}

/// What the listen button is currently doing.
enum CameraListenState {
  /// Not listening. The resting state, and where a camera starts: sound is
  /// never opened by default, because it is a second session on the recorder.
  off,

  /// A ticket has been asked for, or the player is opening the stream.
  connecting,

  /// Playing.
  on,

  /// Measured and silent — this channel has no microphone. Terminal for this
  /// camera: the button stops being offered rather than failing again.
  unavailable,

  /// Something went wrong that trying again might fix.
  failed,
}

/// Drives one camera's sound for the full-screen player.
///
/// Deliberately small and independent of the video: turning sound on or off
/// must never interrupt the picture, so this owns nothing the MJPEG path
/// touches.
class CameraListenController extends ChangeNotifier {
  CameraListenController({
    required Future<Uri> Function() resolveSource,
    required CameraAudioSink sink,
  }) : _resolveSource = resolveSource,
       _sink = sink;

  final Future<Uri> Function() _resolveSource;
  final CameraAudioSink _sink;

  /// How long to let a just-started stream refuse before calling it playing.
  /// Long enough for a rejected ticket to come back, short enough that the
  /// button does not feel like it ignored the tap.
  static const Duration _playGrace = Duration(milliseconds: 400);

  CameraListenState _state = CameraListenState.off;
  String _message = '';
  // Guards against a second tap while the first is still resolving a ticket,
  // which would open two pipelines and charge the recorder two sessions.
  int _attempt = 0;
  bool _disposed = false;

  CameraListenState get state => _state;
  String get message => _message;
  bool get isOn => _state == CameraListenState.on;
  bool get isBusy => _state == CameraListenState.connecting;

  /// Whether the button should still be offered at all.
  bool get isOffered => _state != CameraListenState.unavailable;

  Future<void> toggle() async {
    if (_state == CameraListenState.on ||
        _state == CameraListenState.connecting) {
      await stop();
      return;
    }
    await start();
  }

  Future<void> start() async {
    if (_state == CameraListenState.unavailable) {
      return;
    }
    final attempt = ++_attempt;
    _set(CameraListenState.connecting);
    try {
      final source = await _resolveSource();
      if (_disposed || attempt != _attempt) {
        return;
      }
      // NOT awaited, and that is the whole point. A live stream never ends,
      // and a platform player's `play()` future may not complete until it
      // does — on web it does not complete at all. Waiting for it leaves the
      // button spinning for the entire session while sound is already coming
      // out of the speakers. Measured against the real endpoint, not guessed.
      //
      // So: start it, give it just long enough for an immediate refusal (an
      // expired ticket, a format the platform will not take) to come back,
      // then believe it. A failure that arrives later still lands, because
      // the handler below is attached for the life of the attempt.
      unawaited(
        _sink.play(source).catchError((Object error) {
          if (_disposed || attempt != _attempt) {
            return;
          }
          _set(CameraListenState.failed, message: _describe(error));
        }),
      );
      await Future<void>.delayed(_playGrace);
      if (_disposed || attempt != _attempt) {
        // Stopped while the player was opening: do not leave it running.
        await _sink.stop();
        return;
      }
      if (_state == CameraListenState.failed) {
        return;
      }
      _set(CameraListenState.on);
    } on CameraHasNoAudio catch (error) {
      if (_disposed || attempt != _attempt) {
        return;
      }
      _set(CameraListenState.unavailable, message: error.message);
    } catch (error) {
      if (_disposed || attempt != _attempt) {
        return;
      }
      _set(CameraListenState.failed, message: _describe(error));
    }
  }

  Future<void> stop() async {
    // Bumping the attempt is what makes an in-flight start abandon itself.
    _attempt++;
    if (_state != CameraListenState.unavailable) {
      _set(CameraListenState.off);
    }
    try {
      await _sink.stop();
    } catch (_) {
      // Stopping is best-effort: the socket closing is what actually matters,
      // and a plugin that complains on the way out must not surface as an
      // error on a camera the user has already stopped listening to.
    }
  }

  void _set(CameraListenState state, {String message = ''}) {
    if (_disposed) {
      return;
    }
    _state = state;
    _message = message;
    notifyListeners();
  }

  static String _describe(Object error) {
    final text = error.toString();
    return text.isEmpty ? 'الصوت غير متاح الآن.' : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _attempt++;
    unawaited(_sink.dispose());
    super.dispose();
  }
}
