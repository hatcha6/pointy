import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../../data/services/surveillance_api_client.dart';

enum CameraPlayerMode { live, playback }

/// One camera, full screen: live, or scrubbing its recordings.
///
/// Seeking is a *restart*, not a scrub. The recorder is asked for a new
/// time-bounded stream, which is the only thing a DVR actually offers;
/// pretending otherwise — buffering hours of footage so the bar feels
/// instant — is exactly what makes the stock NVR software slow to open.
class CameraPlayerViewModel extends ChangeNotifier {
  CameraPlayerViewModel(
    this._repository, {
    required this.camera,
    required this.mode,
    DateTime? start,
    Duration window = const Duration(minutes: 10),
    this.status = const SurveillanceStatus(),
  }) : _windowStart = start ?? DateTime.now().subtract(window),
       _window = window {
    _position = _windowStart;
  }

  final SurveillanceRepository _repository;
  final Camera camera;
  final SurveillanceStatus status;

  CameraPlayerMode mode;

  DateTime _windowStart;
  Duration _window;
  late DateTime _position;
  double _speed = 1.0;
  bool _isPlaying = true;
  bool _hasEnded = false;
  String _error = '';
  int _generation = 0;

  // Export mode: the bar becomes a range selector and playback loops inside it.
  bool _isSelecting = false;
  DateTime? _selectionStart;
  DateTime? _selectionEnd;
  bool _isExporting = false;

  RecordingIndex _recordings = const RecordingIndex();
  bool _isLoadingRecordings = false;

  bool get isLive => mode == CameraPlayerMode.live;

  /// Whether to offer the listen button. Optimistic when the channel has never
  /// been measured — the first tap is what measures it — and false only once
  /// the server has looked and found no microphone.
  ///
  /// Sound is live-only: there is no audio track in the MJPEG playback path,
  /// and the recorder's own playback stream is not pulled for it.
  bool get canOfferAudio => isLive && camera.mightHaveAudio;

  /// A short-lived URL for this camera's sound. Throws [CameraHasNoAudio] if
  /// the channel turns out to be silent.
  Future<Uri> audioStreamUri() => _repository.audioStreamUri(camera.id);
  DateTime get windowStart => _windowStart;
  DateTime get windowEnd => _windowStart.add(_window);
  Duration get window => _window;
  DateTime get position => _position;
  double get speed => _speed;
  bool get isPlaying => _isPlaying;
  bool get hasEnded => _hasEnded;
  String get error => _error;
  int get generation => _generation;
  bool get isExporting => _isExporting;
  bool get isSelecting => _isSelecting;
  RecordingIndex get recordings => _recordings;
  bool get isLoadingRecordings => _isLoadingRecordings;

  bool get playbackAvailable => status.playbackAvailable;
  bool get exportAvailable => status.exportAvailable;
  bool get variableSpeedAvailable => status.variableSpeedAvailable;

  /// The live frame rate to ask for: whatever this server says it can carry,
  /// so a recorder that streams 30 arrives at 30 instead of at some number we
  /// picked years ago. Capped at 30 because past that a wall costs more than it
  /// shows.
  int get liveFps => status.maxLiveFps.clamp(1, 30);
  int get playbackFps =>
      status.maxPlaybackFps <= 0 ? 25 : status.maxPlaybackFps.clamp(1, 30);

  DateTime? get selectionStart => _selectionStart;
  DateTime? get selectionEnd => _selectionEnd;

  bool get hasSelection =>
      _selectionStart != null &&
      _selectionEnd != null &&
      _selectionEnd!.isAfter(_selectionStart!);

  Duration get selectionDuration => hasSelection
      ? _selectionEnd!.difference(_selectionStart!)
      : Duration.zero;

  /// 0..1 through the current window — where the bar's handle sits.
  double get progress {
    final total = _window.inMilliseconds;
    if (total <= 0) {
      return 0;
    }
    final elapsed = _position.difference(_windowStart).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  double fractionOf(DateTime moment) {
    final total = _window.inMilliseconds;
    if (total <= 0) {
      return 0;
    }
    return (moment.difference(_windowStart).inMilliseconds / total).clamp(
      0.0,
      1.0,
    );
  }

  DateTime momentAt(double fraction) {
    return _windowStart.add(
      Duration(milliseconds: (_window.inMilliseconds * fraction).round()),
    );
  }

  Stream<CameraFrame> frames() {
    if (isLive) {
      return _repository.liveFrames(
        camera.id,
        fps: liveFps,
        // Full screen is one stream, so it takes the main track — the same
        // split every VMS makes, and the reason `live_quality` defaults to the
        // sub-stream in the first place: that default exists to keep a wall of
        // tiles off a DVR's main encoders, not to cap the one camera somebody
        // is actually looking at. Deriving it from the context rather than
        // asking the shop to configure two qualities per camera.
        quality: CameraQuality.main,
        smooth: true,
      );
    }
    // In export mode the stream is bounded by the selection, so what plays is
    // exactly what will be exported. That is the whole point of the mode: the
    // clip is previewed, not described.
    final start = _isSelecting && hasSelection
        ? _selectionStart!
        : _windowStart;
    final end = _isSelecting && hasSelection ? _selectionEnd! : windowEnd;
    return _repository.playbackFrames(
      camera.id,
      start: start,
      end: end,
      speed: _speed,
      fps: playbackFps,
      quality: camera.playbackQuality,
    );
  }

  /// Called for every frame the player paints, so the clock and the bar track
  /// the footage rather than the wall clock.
  void reportFrameTime(DateTime moment) {
    _position = moment;
    if (_error.isNotEmpty || _hasEnded) {
      _error = '';
      _hasEnded = false;
      notifyListeners();
    }
  }

  void reportError(Object error) {
    _error = error.toString();
    notifyListeners();
  }

  void reportEnded() {
    if (isLive) {
      return;
    }
    // Looping is what makes a selection reviewable: you watch the clip you are
    // about to export, over and over, and adjust the handles until it is right.
    if (_isSelecting && hasSelection) {
      _restartFrom(_selectionStart!);
      return;
    }
    _hasEnded = true;
    _isPlaying = false;
    notifyListeners();
  }

  void togglePlaying() {
    if (_hasEnded) {
      // "Play" at the end means replay the window, not resume a finished one.
      _restartFrom(_windowStart);
      return;
    }
    _isPlaying = !_isPlaying;
    notifyListeners();
  }

  void setSpeed(double speed) {
    if (!variableSpeedAvailable || speed == _speed || isLive) {
      return;
    }
    _speed = speed;
    // Speed is part of the stream the recorder is serving, so changing it
    // restarts from where we are rather than from the top.
    _restartFrom(_position);
  }

  void seekTo(DateTime moment) {
    if (isLive) {
      return;
    }
    _restartFrom(moment);
  }

  void skip(Duration offset) => seekTo(_position.add(offset));

  /// Moves the window itself — the "jump to a date and time" action.
  void openWindowAt(DateTime moment, {Duration? window}) {
    _window = window ?? _window;
    _selectionStart = null;
    _selectionEnd = null;
    _restartFrom(moment);
    unawaitedLoadRecordings();
  }

  void setWindowLength(Duration window) {
    if (window == _window) {
      return;
    }
    // Keep the current moment in view rather than jumping to the top: the
    // reviewer is zooming around what they are looking at.
    final anchor = _position;
    _window = window;
    _windowStart = anchor.subtract(
      Duration(milliseconds: window.inMilliseconds ~/ 2),
    );
    _generation++;
    notifyListeners();
    unawaitedLoadRecordings();
  }

  void _restartFrom(DateTime moment) {
    _windowStart = _isSelecting ? _windowStart : moment;
    _position = moment;
    _hasEnded = false;
    _error = '';
    _isPlaying = true;
    _generation++;
    notifyListeners();
  }

  // -- export mode ---------------------------------------------------------
  /// Enters range selection, seeding a sensible clip around where the reviewer
  /// already is rather than making them place both handles from nothing.
  void beginSelection() {
    if (_isSelecting) {
      return;
    }
    _isSelecting = true;
    final half = Duration(
      milliseconds: (_window.inMilliseconds * 0.1).round().clamp(5000, 60000),
    );
    var start = _position.subtract(half);
    var end = _position.add(half);
    if (start.isBefore(_windowStart)) {
      start = _windowStart;
    }
    if (end.isAfter(windowEnd)) {
      end = windowEnd;
    }
    _selectionStart = start;
    _selectionEnd = end;
    _generation++;
    _isPlaying = true;
    notifyListeners();
  }

  void cancelSelection() {
    if (!_isSelecting) {
      return;
    }
    _isSelecting = false;
    _selectionStart = null;
    _selectionEnd = null;
    _generation++;
    notifyListeners();
  }

  /// Drags a handle. [restart] is false while the finger is down and true on
  /// release, so the clip is re-cut once rather than on every pixel.
  void setSelection(DateTime start, DateTime end, {bool restart = false}) {
    if (!end.isAfter(start)) {
      return;
    }
    _selectionStart = start;
    _selectionEnd = end;
    if (restart) {
      _position = start;
      _hasEnded = false;
      _generation++;
      _isPlaying = true;
    }
    notifyListeners();
  }

  Future<Result<void>> export({
    required Future<void> Function(Stream<List<int>> bytes) onBytes,
  }) async {
    _isExporting = true;
    notifyListeners();
    final start = hasSelection ? _selectionStart! : _windowStart;
    final end = hasSelection ? _selectionEnd! : windowEnd;
    final result = await _repository.exportClip(
      camera.id,
      start: start,
      end: end,
      quality: camera.playbackQuality,
      onBytes: onBytes,
    );
    _isExporting = false;
    notifyListeners();
    return result;
  }

  Future<Result<Uint8List>> captureStill() {
    return _repository.loadStill(camera.id, at: _position);
  }

  // -- recordings ----------------------------------------------------------
  void unawaitedLoadRecordings() {
    if (isLive || !playbackAvailable) {
      return;
    }
    loadRecordings();
  }

  Future<void> loadRecordings() async {
    if (_isLoadingRecordings) {
      return;
    }
    _isLoadingRecordings = true;
    notifyListeners();
    final result = await _repository.loadRecordings(
      camera.id,
      start: _windowStart,
      end: windowEnd,
    );
    if (result case Ok<RecordingIndex>()) {
      _recordings = result.value;
    }
    _isLoadingRecordings = false;
    notifyListeners();
  }

  /// Switches an open player between watching now and reviewing history,
  /// without leaving the screen — the two are the same camera.
  void switchTo(CameraPlayerMode next, {DateTime? at}) {
    if (mode == next) {
      return;
    }
    mode = next;
    cancelSelection();
    if (next == CameraPlayerMode.playback) {
      _windowStart = (at ?? DateTime.now()).subtract(_window);
      _position = _windowStart;
      unawaitedLoadRecordings();
    }
    _hasEnded = false;
    _error = '';
    _isPlaying = true;
    _generation++;
    notifyListeners();
  }
}
