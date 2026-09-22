/// Where a camera wedge's readings come from.
///
/// The seam exists because **no single Flutter camera API spans the platforms
/// Pointy ships on**, and the one that is missing is the one that matters. Read
/// out of the packages rather than recalled:
///
/// | package | platforms |
/// |---|---|
/// | `mobile_scanner` (used here) | android, ios, macos, web |
/// | `camera` | android, ios, web |
/// | `camera_windows` | windows — but `startImageStream` throws `UnimplementedError` |
/// | `flutter_webrtc` | everything, but `captureFrame()` round-trips a PNG through disk |
///
/// The tills are Windows. So the *policy* — how many agreeing looks a
/// symbology needs, how long to hold off a re-read — is platform-agnostic pure
/// Dart in [CameraWedgePolicy], and only the plumbing behind this interface
/// differs. A platform with no source reports [CameraWedgeBackend.none] and the
/// feature is offered nowhere, rather than throwing when someone taps it (the
/// `MissingPluginException` every Windows till used to log when the old camera
/// sheet was opened — see `camera_scanning_support.dart`).
library;

import 'camera_wedge_policy.dart';

/// A camera the wedge could run on. `id` is whatever the backend uses to
/// address it and is never shown; `label` is what the shop sees.
class CameraWedgeDevice {
  const CameraWedgeDevice({required this.id, required this.label});

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is CameraWedgeDevice && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Which implementation this platform would use, if any.
enum CameraWedgeBackend {
  /// `mobile_scanner`: the platform's own detector (ML Kit, Apple Vision,
  /// ZXing on the web). It decodes in native code and hands over values, so
  /// the wedge never sees pixels here. 1-D and 2-D.
  platformScanner,

  /// Stills through `camera_windows`, decoded with pure-Dart `zxing2`. The
  /// Windows till's path, because there is no image stream there. **2-D
  /// only** — zxing2 ships no 1-D readers — so a till here keeps using the
  /// counter wedge for EAN-13 and gains the receipt QR codes it never could
  /// read.
  snapshot,

  /// Nothing available. The feature is hidden rather than broken.
  none,
}

/// A running camera, reporting what it thinks it sees.
///
/// Implementations report EVERY decode, including repeats — the policy needs
/// them to reach agreement, and a source that de-duplicates internally would
/// silently make every 1-D scan impossible. That is a real trap: it is the
/// default in `mobile_scanner` (`DetectionSpeed.noDuplicates`).
abstract class CameraWedgeSource {
  /// Every decode, unfiltered and un-deduplicated.
  Stream<CameraWedgeReading> get readings;

  /// Cameras this backend can see. May be empty before [start] on platforms
  /// that only reveal device labels once permission is granted.
  Future<List<CameraWedgeDevice>> devices();

  /// Begin watching. Safe to call when already started.
  Future<void> start({String? deviceId});

  /// Stop watching and release the camera. Safe to call when not started.
  Future<void> stop();

  Future<void> dispose();
}
