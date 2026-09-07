import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../../data/services/surveillance_api_client.dart';

/// How big the tiles are, which on a scrolling wall is the only thing a layout
/// choice can mean.
///
/// The count per row is not a setting: it falls out of the tile size and the
/// width available, so the same choice gives four across on a monitor and one
/// on a phone without anybody configuring anything.
enum CameraWallLayout {
  large(560),
  medium(380),
  small(260);

  const CameraWallLayout(this.targetTileWidth);

  /// The width a tile aims for. The grid fits as many as the viewport allows.
  final double targetTileWidth;

  int columnsFor(double width) {
    return (width / targetTileWidth).floor().clamp(1, 6);
  }
}

class CameraWallViewModel extends ChangeNotifier {
  CameraWallViewModel(this._repository);

  final SurveillanceRepository _repository;

  List<Camera> _cameras = const [];
  SurveillanceStatus _status = const SurveillanceStatus();
  CameraWallLayout _layout = CameraWallLayout.medium;
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isPaused = false;

  List<Camera> get cameras => _cameras;
  SurveillanceStatus get status => _status;
  CameraWallLayout get layout => _layout;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isPaused => _isPaused;
  bool get isEmpty => _cameras.isEmpty;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final statusResult = await _repository.loadStatus();
    switch (statusResult) {
      case Ok<SurveillanceStatus>():
        _status = statusResult.value;
      case Error<SurveillanceStatus>():
        _hasLoadError = true;
    }

    final camerasResult = await _repository.loadCameras(enabledOnly: true);
    switch (camerasResult) {
      case Ok<List<Camera>>():
        _cameras = camerasResult.value;
        _hasLoadError = false;
      case Error<List<Camera>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  void setLayout(CameraWallLayout layout) {
    if (_layout == layout) {
      return;
    }
    _layout = layout;
    notifyListeners();
  }

  void togglePaused() {
    _isPaused = !_isPaused;
    notifyListeners();
  }

  /// Frames for one tile, at the rate this server says it can actually carry.
  ///
  /// [tileWidth] is the tile's real width in pixels: the server scales the
  /// frames to it, so a wall of small tiles moves a fraction of the bytes a
  /// wall of large ones does and decodes proportionally cheaper. That is what
  /// makes nine at once cost what it costs.
  Stream<CameraFrame> liveFrames(Camera camera, {int tileWidth = 0}) {
    return _repository.liveFrames(
      camera.id,
      fps: _status.maxLiveFps.clamp(1, 30),
      quality: camera.liveQuality,
      smooth: _status.smoothLiveAvailable,
      width: tileWidth,
    );
  }

  Future<bool> rename(Camera camera, String name) async {
    final result = await _repository.updateCamera(camera.id, name: name.trim());
    switch (result) {
      case Ok<Camera>():
        _cameras = [
          for (final existing in _cameras)
            if (existing.id == camera.id) result.value else existing,
        ];
        notifyListeners();
        return true;
      case Error<Camera>():
        return false;
    }
  }
}
