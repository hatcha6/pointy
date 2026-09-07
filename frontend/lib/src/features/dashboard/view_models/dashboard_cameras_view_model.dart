import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../../data/services/device_settings_storage_service.dart';
import '../../../data/services/surveillance_api_client.dart';

/// The live cameras strip on the dashboard.
///
/// Two decisions carry this feature.
///
/// **It shows something without being configured.** A dashboard that starts
/// empty and waits to be set up is a dashboard nobody sets up, so with no
/// choice stored it picks for you: the cameras the shop flagged as covering a
/// checkout first — those are the ones a till's dashboard is for — then the
/// rest in the order the shop arranged them.
///
/// **It refreshes stills; it does not stream.** The dashboard is a screen
/// people leave open all day. Running an H.264 decode per camera on a shop
/// mini-PC for hours so an unwatched corner of a screen can be smooth is the
/// wrong trade — it is the same reason Home Assistant's picture cards default
/// to refreshing snapshots rather than live video. A couple of frames a second
/// through the recorder's own snapshot endpoint costs no transcoding at all,
/// still reads as alive for a shop scene, and the full-screen player is one tap
/// away when somebody actually wants to watch.
class DashboardCamerasViewModel extends ChangeNotifier {
  DashboardCamerasViewModel(
    this._repository, {
    DeviceSettingsStorageService storage = const DeviceSettingsStorageService(),
  }) : _storage = storage;

  final SurveillanceRepository _repository;
  final DeviceSettingsStorageService _storage;

  /// Frames a second per tile. Enough that a person crossing the frame is
  /// obviously moving, few enough that a recorder serving four dashboards
  /// never notices.
  static const int framesPerSecond = 2;

  /// How many the dashboard picks for itself. More than this and the band stops
  /// being a glance and starts being the camera wall, which already exists.
  static const int autoSelectionLimit = 3;

  List<Camera> _cameras = const [];
  SurveillanceStatus _status = const SurveillanceStatus();

  /// Null until loaded, and null *after* loading means "never chosen" — which
  /// is not the same as "chose none". See [DeviceSettingsStorageService].
  List<int>? _selectedIds;
  bool _isLoading = false;
  bool _hasLoaded = false;

  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  List<Camera> get cameras => _cameras;
  SurveillanceStatus get status => _status;

  /// True when the user has expressed a choice, so the UI can offer to put it
  /// back on automatic.
  bool get hasExplicitSelection => _selectedIds != null;

  /// The cameras to draw, in order.
  List<Camera> get visibleCameras {
    final chosen = _selectedIds;
    if (chosen == null) {
      return _autoSelection();
    }
    // Resolved against the live list every time rather than trusting the stored
    // ids: a camera that was removed, disabled, or belongs to a recorder that
    // has been unplugged must drop out of the band instead of leaving a hole
    // that streams nothing forever.
    final byId = {for (final camera in _cameras) camera.id: camera};
    return [
      for (final id in chosen)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Whether the band appears at all. Empty is a legitimate, deliberate answer.
  bool get isVisible => visibleCameras.isNotEmpty;

  List<Camera> _autoSelection() {
    final ranked = [..._cameras];
    ranked.sort((a, b) {
      // A camera pointed at the counter is what a shop's dashboard is for.
      if (a.coversCheckout != b.coversCheckout) {
        return a.coversCheckout ? -1 : 1;
      }
      final byOrder = a.displayOrder.compareTo(b.displayOrder);
      return byOrder != 0 ? byOrder : a.channel.compareTo(b.channel);
    });
    return ranked.take(autoSelectionLimit).toList(growable: false);
  }

  Future<void> load() async {
    if (_isLoading) {
      return;
    }
    _isLoading = true;
    notifyListeners();

    _selectedIds = await _storage.loadDashboardCameraIds();
    final statusResult = await _repository.loadStatus();
    if (statusResult case Ok<SurveillanceStatus>()) {
      _status = statusResult.value;
    }
    final camerasResult = await _repository.loadCameras(enabledOnly: true);
    if (camerasResult case Ok<List<Camera>>()) {
      _cameras = camerasResult.value;
    }

    _isLoading = false;
    _hasLoaded = true;
    notifyListeners();
  }

  Future<void> select(List<int> cameraIds) async {
    _selectedIds = List<int>.unmodifiable(cameraIds);
    notifyListeners();
    await _storage.saveDashboardCameraIds(cameraIds);
  }

  /// Back to letting the dashboard choose.
  Future<void> resetSelection() async {
    _selectedIds = null;
    notifyListeners();
    await _storage.clearDashboardCameraIds();
  }

  final Map<int, Uint8List> _thumbnails = {};

  /// A still from [camera], cached for the life of this view model.
  ///
  /// Cached because the picker is opened, closed and reopened while somebody
  /// makes up their mind, and re-fetching every thumbnail each time would make
  /// choosing cameras more expensive than watching them.
  Future<Uint8List?> thumbnail(Camera camera) async {
    final cached = _thumbnails[camera.id];
    if (cached != null) {
      return cached;
    }
    final result = await _repository.loadSnapshot(camera.id);
    if (result case Ok<Uint8List>()) {
      _thumbnails[camera.id] = result.value;
      return result.value;
    }
    return null;
  }

  /// Frames for one dashboard tile.
  ///
  /// `smooth: false` is the whole point — it pins this to the recorder's
  /// snapshot endpoint, so a dashboard left open overnight costs the server no
  /// transcoding. [tileWidth] lets the server scale the JPEG to the tile, which
  /// is most of the bandwidth saved.
  Stream<CameraFrame> frames(Camera camera, {int tileWidth = 0}) {
    return _repository.liveFrames(
      camera.id,
      fps: framesPerSecond,
      quality: CameraQuality.sub,
      smooth: false,
      width: tileWidth,
    );
  }
}
