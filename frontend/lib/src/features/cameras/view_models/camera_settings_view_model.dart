import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../../data/services/recorder_discovery.dart';

/// Recorder setup and per-camera configuration.
///
/// The connection test is a first-class state here rather than a fire-and-
/// forget call: the difference between a confident install and a support call
/// is showing "Hikvision DS-7216, 16 cameras" before anyone presses save.
/// How the LAN is swept for recorders. Injectable so the preview harness and
/// tests can stand in for a network they do not have.
typedef RecorderSweep = Future<List<DiscoveredRecorder>> Function();

class CameraSettingsViewModel extends ChangeNotifier {
  CameraSettingsViewModel(this._repository, {RecorderSweep? sweep})
    : _sweep = sweep ?? discoverRecorders;

  final SurveillanceRepository _repository;
  final RecorderSweep _sweep;

  List<Recorder> _recorders = const [];
  List<Camera> _cameras = const [];
  SurveillanceStatus _status = const SurveillanceStatus();
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  RecorderTestResult? _testResult;
  bool _isTesting = false;

  List<DiscoveredRecorder> _discovered = const [];
  bool _isScanning = false;
  bool _hasScanned = false;

  List<Recorder> get recorders => _recorders;
  List<Camera> get cameras => _cameras;
  SurveillanceStatus get status => _status;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  RecorderTestResult? get testResult => _testResult;
  bool get isTesting => _isTesting;

  /// Recorders this device found on the shop's network.
  List<DiscoveredRecorder> get discovered => _discovered;
  bool get isScanning => _isScanning;
  bool get hasScanned => _hasScanned;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final statusResult = await _repository.loadStatus();
    if (statusResult case Ok<SurveillanceStatus>()) {
      _status = statusResult.value;
    }
    final recordersResult = await _repository.loadRecorders();
    switch (recordersResult) {
      case Ok<List<Recorder>>():
        _recorders = recordersResult.value;
      case Error<List<Recorder>>():
        _hasLoadError = true;
    }
    final camerasResult = await _repository.loadCameras();
    switch (camerasResult) {
      case Ok<List<Camera>>():
        _cameras = camerasResult.value;
      case Error<List<Camera>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Sweeps the LAN for recorders, from this device.
  ///
  /// Client-side on purpose: the backend runs in a container with no route onto
  /// the shop's broadcast domain — the same wall UDP backend discovery hit —
  /// while the till is already on the network the cameras are on.
  Future<void> scanForRecorders() async {
    if (_isScanning) {
      return;
    }
    _isScanning = true;
    notifyListeners();
    try {
      _discovered = await _sweep();
    } on Object {
      // A sweep that cannot run (no LAN interface, a platform without raw
      // sockets) is not an error worth a banner: the manual fields are right
      // there, and that is what the empty state says.
      _discovered = const [];
    }
    _isScanning = false;
    _hasScanned = true;
    notifyListeners();
  }

  void clearDiscovered() {
    _discovered = const [];
    _hasScanned = false;
    _isScanning = false;
  }

  void clearTestResult() {
    if (_testResult == null) {
      return;
    }
    _testResult = null;
    notifyListeners();
  }

  Future<RecorderTestResult?> testRecorder(RecorderDraft draft) async {
    _isTesting = true;
    _testResult = null;
    notifyListeners();
    final result = await _repository.testRecorder(draft);
    switch (result) {
      case Ok<RecorderTestResult>():
        _testResult = result.value;
      case Error<RecorderTestResult>():
        _testResult = const RecorderTestResult(ok: false);
    }
    _isTesting = false;
    notifyListeners();
    return _testResult;
  }

  Future<bool> saveRecorder(RecorderDraft draft) {
    return _mutate(() async {
      final result = await _repository.saveRecorder(draft);
      return result is Ok<Recorder>;
    });
  }

  Future<bool> deleteRecorder(int id) {
    return _mutate(() async {
      final result = await _repository.deleteRecorder(id);
      return result is Ok<void>;
    });
  }

  Future<bool> syncRecorder(int id) {
    return _mutate(() async {
      final result = await _repository.syncRecorder(id);
      return result is Ok<Recorder>;
    });
  }

  Future<bool> updateCamera(
    Camera camera, {
    String? name,
    bool? isEnabled,
    bool? coversCheckout,
    CameraQuality? liveQuality,
    CameraQuality? playbackQuality,
  }) async {
    // Applied locally first: a switch that waits for a round trip before it
    // moves reads as a broken switch, and the reload below is the correction.
    _cameras = [
      for (final existing in _cameras)
        if (existing.id == camera.id)
          existing.copyWith(
            name: name,
            isEnabled: isEnabled,
            coversCheckout: coversCheckout,
            liveQuality: liveQuality,
            playbackQuality: playbackQuality,
          )
        else
          existing,
    ];
    notifyListeners();

    final result = await _repository.updateCamera(
      camera.id,
      name: name,
      isEnabled: isEnabled,
      coversCheckout: coversCheckout,
      liveQuality: liveQuality,
      playbackQuality: playbackQuality,
    );
    switch (result) {
      case Ok<Camera>():
        _cameras = [
          for (final existing in _cameras)
            if (existing.id == camera.id) result.value else existing,
        ];
        notifyListeners();
        return true;
      case Error<Camera>():
        await load();
        return false;
    }
  }

  List<Camera> camerasFor(Recorder recorder) {
    return _cameras
        .where((camera) => camera.recorderId == recorder.id)
        .toList(growable: false);
  }

  Future<bool> _mutate(Future<bool> Function() action) async {
    _isMutating = true;
    notifyListeners();
    final ok = await action();
    _isMutating = false;
    if (ok) {
      await load();
    } else {
      notifyListeners();
    }
    return ok;
  }
}
